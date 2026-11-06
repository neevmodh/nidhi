// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ExtraArgsLib} from "./libraries/ExtraArgsLib.sol";
import {AckLib} from "./libraries/AckLib.sol";

/// @title DestinationReceiver
/// @notice Destination-chain end of a Nidhi grant.
///   1. Authenticates the CCIP message (router, source chain, source dispatcher, expected token, exact amount).
///   2. Pays the recipient. If the payout fails - or payouts are paused for incident response - the funds are HELD
///      here instead of reverting, so a CCIP message is never stuck because of a payout problem.
///   3. Acknowledges back to the source chain. The ACK is decoupled: an ACK failure can never roll back a payout;
///      it is recorded and anyone can retry it.
///   4. Self-heals: every grant that still needs work (ACK owed, or HELD while payouts are not paused) sits in a
///      queue that Chainlink Automation drains via checkUpkeep/performUpkeep. No human is needed for recovery
///      except the DAO-only `recover` to an alternate address.
contract DestinationReceiver is CCIPReceiver, Ownable2Step, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    struct Payout {
        uint8 outcome; // AckLib.PAID / HELD / RECOVERED (0 = unseen)
        bool ackPending;
        address recipient;
        uint128 amount;
        bytes32 messageId; // source CCIP messageId
        uint64 srcSelector; // chain the grant came from; the ACK goes back there
        address token; // the (destination-chain) token that arrived
    }

    /// @notice Max grants handled per performUpkeep (bounds gas; the queue drains over several upkeeps).
    uint256 public constant MAX_BATCH = 10;

    /// @notice Fee token for ACK fees: LINK, or address(0) for native.
    address public immutable feeToken;

    /// @notice source chain selector => NidhiDispatcher there. Add-only.
    mapping(uint64 srcSelector => address dispatcher) public sourceDispatchers;
    /// @notice Tokens this receiver will pay out (destination-chain representation). Add-only.
    mapping(address token => bool) public allowedToken;
    uint32 public ackGasLimit = 200_000;
    bool public payoutsPaused;

    mapping(bytes32 grantId => Payout) internal _payouts;

    /// @dev Grants that may need follow-up work. 1-based index map; swap-and-pop removal.
    bytes32[] internal _queue;
    mapping(bytes32 grantId => uint256) internal _queueIndex;

    event SourceAdded(uint64 indexed srcSelector, address dispatcher);
    event TokenAllowed(address indexed token);
    event PayoutsPaused(bool paused);
    event GrantReceived(bytes32 indexed grantId, bytes32 indexed messageId, address recipient, uint256 amount);
    event PayoutSucceeded(bytes32 indexed grantId, address indexed recipient, uint256 amount);
    event PayoutHeld(bytes32 indexed grantId, address indexed recipient, uint256 amount, bytes reason);
    event PayoutRecovered(bytes32 indexed grantId, address indexed to, uint256 amount);
    event AckSent(bytes32 indexed grantId, bytes32 indexed ackMessageId, uint8 outcome);
    event AckFailed(bytes32 indexed grantId, uint8 outcome, bytes reason);
    event UpkeepPerformed(uint256 processed, uint256 remaining);

    error AlreadySet();
    error ZeroAddress();
    error UnknownSource(uint64 chainSelector, address sender);
    error UnexpectedTokens();
    error AmountMismatch(uint256 declared, uint256 received);
    error DuplicateGrant(bytes32 grantId);
    error OnlySelf();
    error NotHeld(bytes32 grantId);
    error NoAckPending(bytes32 grantId);
    error InsufficientFee(uint256 have, uint256 need);
    error Paused();

    constructor(address router_, address feeToken_, address owner_) CCIPReceiver(router_) Ownable(owner_) {
        feeToken = feeToken_;
    }

    receive() external payable {} // native ACK-fee reserve

    // ------------------------------------------------------------------ admin

    /// @notice Trust a NidhiDispatcher on a source chain. Add-only (no overwrite).
    function addSource(uint64 srcSelector, address dispatcher_) external onlyOwner {
        if (sourceDispatchers[srcSelector] != address(0)) revert AlreadySet();
        if (dispatcher_ == address(0) || srcSelector == 0) revert ZeroAddress();
        sourceDispatchers[srcSelector] = dispatcher_;
        emit SourceAdded(srcSelector, dispatcher_);
    }

    /// @notice Allow a token to be paid out. Add-only.
    function allowToken(address token_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        if (allowedToken[token_]) revert AlreadySet();
        allowedToken[token_] = true;
        emit TokenAllowed(token_);
    }

    /// @notice Circuit breaker: while paused, arriving grants are HELD (not paid, not reverted).
    function setPayoutsPaused(bool paused) external onlyOwner {
        payoutsPaused = paused;
        emit PayoutsPaused(paused);
    }

    function setAckGasLimit(uint32 gasLimit_) external onlyOwner {
        ackGasLimit = gasLimit_;
    }

    // ------------------------------------------------------------------ receive

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        address expected = sourceDispatchers[message.sourceChainSelector];
        if (expected == address(0) || sender != expected) revert UnknownSource(message.sourceChainSelector, sender);
        if (message.destTokenAmounts.length != 1 || !allowedToken[message.destTokenAmounts[0].token]) {
            revert UnexpectedTokens();
        }

        (bytes32 grantId, address recipient, uint256 amount) = AckLib.decodeGrant(message.data);
        uint256 received = message.destTokenAmounts[0].amount;
        if (amount != received) revert AmountMismatch(amount, received);

        Payout storage p = _payouts[grantId];
        if (p.outcome != 0) revert DuplicateGrant(grantId);
        p.recipient = recipient;
        p.amount = SafeCast.toUint128(amount);
        p.messageId = message.messageId;
        p.srcSelector = message.sourceChainSelector;
        p.token = message.destTokenAmounts[0].token;
        emit GrantReceived(grantId, message.messageId, recipient, amount);

        if (payoutsPaused) {
            p.outcome = AckLib.HELD;
            emit PayoutHeld(grantId, recipient, amount, abi.encodeWithSelector(Paused.selector));
        } else {
            p.outcome = AckLib.PAID; // optimistic, written before the external call (checks-effects-interactions)
            try this.executePayout(p.token, recipient, amount) {
                emit PayoutSucceeded(grantId, recipient, amount);
            } catch (bytes memory reason) {
                p.outcome = AckLib.HELD;
                emit PayoutHeld(grantId, recipient, amount, reason);
            }
        }

        _ack(grantId);
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function executePayout(address token_, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(token_).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ held funds

    /// @notice Retry paying a HELD grant to its original recipient. Anyone may call (funds can only go to the recipient).
    function retryPayout(bytes32 grantId) external {
        if (payoutsPaused) revert Paused();
        if (_payouts[grantId].outcome != AckLib.HELD) revert NotHeld(grantId);
        _payHeld(grantId);
    }

    function _payHeld(bytes32 grantId) private {
        Payout storage p = _payouts[grantId];
        p.outcome = AckLib.PAID;
        IERC20(p.token).safeTransfer(p.recipient, p.amount);
        emit PayoutSucceeded(grantId, p.recipient, p.amount);
        _ack(grantId);
    }

    /// @notice DAO recovery of a HELD grant to an alternate address (e.g. recipient key lost or sanctioned).
    function recover(bytes32 grantId, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        Payout storage p = _payouts[grantId];
        if (p.outcome != AckLib.HELD) revert NotHeld(grantId);
        p.outcome = AckLib.RECOVERED;
        IERC20(p.token).safeTransfer(to, p.amount);
        emit PayoutRecovered(grantId, to, p.amount);
        _ack(grantId);
    }

    // ------------------------------------------------------------------ ACK

    /// @notice Retry a failed ACK. Anyone may call; fees come from this contract's reserve.
    function retryAck(bytes32 grantId) external {
        if (!_payouts[grantId].ackPending) revert NoAckPending(grantId);
        _ack(grantId);
    }

    function _ack(bytes32 grantId) private {
        Payout storage p = _payouts[grantId];
        p.ackPending = true; // cleared only once the ACK is actually sent (checks-effects-interactions)
        try this.sendAck(grantId) returns (bytes32 ackId) {
            p.ackPending = false;
            emit AckSent(grantId, ackId, p.outcome);
        } catch (bytes memory reason) {
            emit AckFailed(grantId, p.outcome, reason);
        }
        _syncQueue(grantId);
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function sendAck(bytes32 grantId) external returns (bytes32) {
        if (msg.sender != address(this)) revert OnlySelf();
        Payout storage p = _payouts[grantId];

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(sourceDispatchers[p.srcSelector]),
            data: AckLib.encodeAck(grantId, p.messageId, p.amount, p.outcome),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: feeToken,
            extraArgs: ExtraArgsLib.encode(ackGasLimit)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(p.srcSelector, message);
        if (feeToken == address(0)) {
            if (address(this).balance < fee) revert InsufficientFee(address(this).balance, fee);
            return router.ccipSend{value: fee}(p.srcSelector, message);
        }
        uint256 feeBal = IERC20(feeToken).balanceOf(address(this));
        if (feeBal < fee) revert InsufficientFee(feeBal, fee);
        IERC20(feeToken).forceApprove(address(router), fee);
        return router.ccipSend(p.srcSelector, message);
    }

    // ------------------------------------------------------------------ self-healing (Chainlink Automation)

    /// @dev A grant needs work while an ACK is owed or its payout is HELD.
    function _needsWork(Payout storage p) private view returns (bool) {
        return p.ackPending || p.outcome == AckLib.HELD;
    }

    /// @dev A grant is actionable now if an ACK is owed, or it is HELD and payouts are not paused.
    function _actionable(Payout storage p) private view returns (bool) {
        return p.ackPending || (p.outcome == AckLib.HELD && !payoutsPaused);
    }

    function _syncQueue(bytes32 grantId) private {
        bool want = _needsWork(_payouts[grantId]);
        uint256 idx = _queueIndex[grantId];
        if (want && idx == 0) {
            _queue.push(grantId);
            _queueIndex[grantId] = _queue.length;
        } else if (!want && idx != 0) {
            bytes32 last = _queue[_queue.length - 1];
            _queue[idx - 1] = last;
            _queueIndex[last] = idx;
            _queue.pop();
            delete _queueIndex[grantId];
        }
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        bytes32[] memory ids = new bytes32[](MAX_BATCH);
        uint256 n;
        for (uint256 i; i < _queue.length && n < MAX_BATCH; ++i) {
            if (_actionable(_payouts[_queue[i]])) ids[n++] = _queue[i];
        }
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        return (n > 0, abi.encode(ids));
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev Permissionless and idempotent: each id is re-checked; stale ids are skipped, never reverted on.
    function performUpkeep(bytes calldata performData) external {
        bytes32[] memory ids = abi.decode(performData, (bytes32[]));
        uint256 processed = 0;
        for (uint256 i; i < ids.length && i < MAX_BATCH; ++i) {
            Payout storage p = _payouts[ids[i]];
            if (p.outcome == AckLib.HELD && !payoutsPaused) {
                _payHeld(ids[i]); // pays the original recipient, then ACKs
                ++processed;
            } else if (p.ackPending) {
                _ack(ids[i]);
                ++processed;
            }
        }
        emit UpkeepPerformed(processed, _queue.length);
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queuedAt(uint256 i) external view returns (bytes32) {
        return _queue[i];
    }

    // ------------------------------------------------------------------ views + reserve

    function getPayout(bytes32 grantId) external view returns (Payout memory) {
        return _payouts[grantId];
    }

    /// @notice Withdraw ACK-fee reserves only. Never the bridged grant token.
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (feeToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native transfer failed");
        } else {
            if (allowedToken[feeToken]) revert UnexpectedTokens(); // never drain a grant token as "fees"
            IERC20(feeToken).safeTransfer(to, amount);
        }
    }
}
