// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Mandate} from "./libraries/Mandate.sol";
import {ExtraArgsLib} from "./libraries/ExtraArgsLib.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {AckLib} from "./libraries/AckLib.sol";
import {INidhiDispatcher} from "./interfaces/INidhiDispatcher.sol";

/// @title NidhiDispatcher
/// @notice Source-chain grant ledger and CCIP endpoint.
///         - dispatch(): called only by NidhiHook mid-swap; sends the captured output to the DestinationReceiver as a
///           CCIP programmable token transfer (tokens + grant payload in one message).
///         - _ccipReceive(): accepts the destination's acknowledgement and closes the loop on-chain.
///
///  Ledger:  NONE -> DISPATCHED -> SETTLED            (paid on arrival)
///                             \-> HELD -> SETTLED    (payout held at destination, later paid or recovered)
///
/// @dev The ACK may arrive in the same transaction as the send (local simulator) or out of order relative to the
///      messageId bookkeeping, so messageId is reconciled from whichever side lands first.
contract NidhiDispatcher is INidhiDispatcher, CCIPReceiver, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum Status {
        NONE,
        DISPATCHED,
        HELD,
        SETTLED
    }

    struct Grant {
        Status status;
        uint8 outcome; // last AckLib outcome reported by the destination
        uint64 dispatchedAt;
        uint64 destSelector; // CCIP selector of the destination chain this grant was sent to
        uint128 amount;
        address token;
        address recipient;
        bytes32 messageId;
    }

    /// @notice Fee token for CCIP fees: LINK, or address(0) for native.
    address public immutable feeToken;

    address public hook; // set once
    /// @notice destination chain selector => DestinationReceiver there. Add-only: an entry can never be changed.
    mapping(uint64 destSelector => address receiver) public destReceivers;
    uint32 public destGasLimit = 600_000;
    /// @notice CCIP 2.0 Faster-Than-Finality per destination: the finality this dispatcher requests (FinalityCodec).
    ///         bytes4(0) = wait for full source finality (default). A block depth must be at least the lane token
    ///         pool's minimum and allowed by the destination receiver, or the message fails on execution.
    mapping(uint64 destSelector => bytes4 finality) public requestedFinality;
    /// @notice Grants still DISPATCHED after this long can be flagged (CCIP's executor retries for ~8h).
    uint64 public constant STUCK_AFTER = 6 hours;

    mapping(bytes32 grantId => Grant) internal _grants;

    event HookSet(address hook);
    event DestinationAdded(uint64 indexed destSelector, address receiver);
    event DestGasLimitSet(uint32 gasLimit);
    event RequestedFinalitySet(uint64 indexed destSelector, bytes4 finality);
    event GrantDispatched(
        bytes32 indexed grantId,
        bytes32 indexed messageId,
        address token,
        uint256 amount,
        address recipient,
        uint256 fee
    );
    event GrantAcknowledged(bytes32 indexed grantId, bytes32 indexed messageId, uint8 outcome, Status status);
    event GrantStuck(bytes32 indexed grantId, bytes32 indexed messageId, uint64 dispatchedAt);

    error OnlyHook();
    error AlreadySet();
    error ZeroAddress();
    error NotConfigured(uint64 destSelector);
    error WrongDestination();
    error GrantExists(bytes32 grantId);
    error InsufficientTokens(uint256 have, uint256 need);
    error InsufficientFee(uint256 have, uint256 need);
    error UnknownSource(uint64 chainSelector, address sender);
    error InvalidAck(bytes32 grantId);
    error MessageIdMismatch(bytes32 stored, bytes32 received);
    error NotStuck(bytes32 grantId);

    constructor(address router_, address feeToken_, address owner_) CCIPReceiver(router_) Ownable(owner_) {
        feeToken = feeToken_;
    }

    receive() external payable {} // native fee reserve

    // ------------------------------------------------------------------ one-time wiring

    function setHook(address hook_) external onlyOwner {
        if (hook != address(0)) revert AlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Register the DestinationReceiver for a destination chain. Add-only (no overwrite).
    function addDestination(uint64 destSelector, address receiver_) external onlyOwner {
        if (destReceivers[destSelector] != address(0)) revert AlreadySet();
        if (receiver_ == address(0) || destSelector == 0) revert ZeroAddress();
        destReceivers[destSelector] = receiver_;
        emit DestinationAdded(destSelector, receiver_);
    }

    /// @notice Request faster-than-finality delivery to `destSelector` (bytes4(0) restores full finality).
    function setRequestedFinality(uint64 destSelector, bytes4 finality) external onlyOwner {
        FinalityCodec._validateRequestedFinality(finality);
        requestedFinality[destSelector] = finality;
        emit RequestedFinalitySet(destSelector, finality);
    }

    function setDestGasLimit(uint32 gasLimit_) external onlyOwner {
        destGasLimit = gasLimit_;
        emit DestGasLimitSet(gasLimit_);
    }

    // ------------------------------------------------------------------ dispatch (hook only)

    /// @inheritdoc INidhiDispatcher
    function dispatch(Mandate calldata m, uint256 amount) external nonReentrant returns (bytes32 messageId) {
        if (msg.sender != hook) revert OnlyHook();
        address receiver = destReceivers[m.destChainSelector];
        if (receiver == address(0)) revert NotConfigured(m.destChainSelector);
        if (m.destReceiver != receiver) revert WrongDestination();

        Grant storage g = _grants[m.grantId];
        if (g.status != Status.NONE) revert GrantExists(m.grantId);

        uint256 bal = IERC20(m.tokenOut).balanceOf(address(this));
        if (bal < amount) revert InsufficientTokens(bal, amount);

        Client.EVM2AnyMessage memory message = _buildMessage(m, amount, receiver);
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(m.destChainSelector, message);

        // Effects before interactions.
        g.status = Status.DISPATCHED;
        g.dispatchedAt = uint64(block.timestamp);
        g.destSelector = m.destChainSelector;
        g.amount = SafeCast.toUint128(amount);
        g.token = m.tokenOut;
        g.recipient = m.recipient;

        IERC20(m.tokenOut).forceApprove(address(router), amount);
        if (feeToken == address(0)) {
            if (address(this).balance < fee) revert InsufficientFee(address(this).balance, fee);
            messageId = router.ccipSend{value: fee}(m.destChainSelector, message);
        } else {
            uint256 feeBal = IERC20(feeToken).balanceOf(address(this));
            if (feeBal < fee) revert InsufficientFee(feeBal, fee);
            IERC20(feeToken).forceApprove(address(router), fee);
            messageId = router.ccipSend(m.destChainSelector, message);
            IERC20(feeToken).forceApprove(address(router), 0);
        }
        IERC20(m.tokenOut).forceApprove(address(router), 0);

        // The ACK may already have landed (synchronous delivery); reconcile instead of overwriting.
        if (g.messageId == bytes32(0)) g.messageId = messageId;
        else if (g.messageId != messageId) revert MessageIdMismatch(g.messageId, messageId);

        emit GrantDispatched(m.grantId, messageId, m.tokenOut, amount, m.recipient, fee);
    }

    function _buildMessage(Mandate calldata m, uint256 amount, address receiver)
        private
        view
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount({token: m.tokenOut, amount: amount});
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: AckLib.encodeGrant(m.grantId, m.recipient, amount),
            tokenAmounts: tokens,
            feeToken: feeToken,
            extraArgs: ExtraArgsLib.encode(destGasLimit, requestedFinality[m.destChainSelector])
        });
    }

    // ------------------------------------------------------------------ ACK (router only, via CCIPReceiver)

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        address expected = destReceivers[message.sourceChainSelector];
        if (expected == address(0) || sender != expected) revert UnknownSource(message.sourceChainSelector, sender);
        if (message.destTokenAmounts.length != 0) revert InvalidAck(bytes32(0));

        (bytes32 grantId, bytes32 sourceMessageId, uint256 amount, uint8 outcome) = AckLib.decodeAck(message.data);
        Grant storage g = _grants[grantId];
        // An ACK is only valid from the chain this grant was actually sent to.
        if (amount != g.amount || g.destSelector != message.sourceChainSelector) revert InvalidAck(grantId);

        if (g.messageId == bytes32(0)) g.messageId = sourceMessageId;
        else if (g.messageId != sourceMessageId) revert MessageIdMismatch(g.messageId, sourceMessageId);

        // Monotonic transitions only.
        if (outcome == AckLib.HELD && g.status == Status.DISPATCHED) {
            g.status = Status.HELD;
        } else if (
            (outcome == AckLib.PAID || outcome == AckLib.RECOVERED)
                && (g.status == Status.DISPATCHED || g.status == Status.HELD)
        ) {
            g.status = Status.SETTLED;
        } else {
            revert InvalidAck(grantId);
        }
        g.outcome = outcome;
        emit GrantAcknowledged(grantId, sourceMessageId, outcome, g.status);
    }

    // ------------------------------------------------------------------ monitoring

    /// @notice Anyone may flag a grant whose ACK has not arrived in time. Event only: CCIP transfers cannot be
    ///         unwound; recovery is handled on the destination (DestinationReceiver.recover / manual execution).
    function flagStuck(bytes32 grantId) external {
        Grant storage g = _grants[grantId];
        if (g.status != Status.DISPATCHED || block.timestamp < g.dispatchedAt + STUCK_AFTER) revert NotStuck(grantId);
        emit GrantStuck(grantId, g.messageId, g.dispatchedAt);
    }

    function getGrant(bytes32 grantId) external view returns (Grant memory) {
        return _grants[grantId];
    }

    function statusOf(bytes32 grantId) external view returns (Status) {
        return _grants[grantId].status;
    }

    // ------------------------------------------------------------------ fee reserve management

    /// @notice Withdraw fee reserves (LINK or native). Grant tokens never rest here between transactions.
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (feeToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native transfer failed");
        } else {
            IERC20(feeToken).safeTransfer(to, amount);
        }
    }
}
