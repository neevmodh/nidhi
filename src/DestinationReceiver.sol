// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
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
///   Held funds can be retried to the original recipient (anyone) or recovered by the DAO owner.
contract DestinationReceiver is CCIPReceiver, Ownable2Step {
    using SafeERC20 for IERC20;

    struct Payout {
        uint8 outcome; // AckLib.PAID / HELD / RECOVERED (0 = unseen)
        bool ackPending;
        address recipient;
        uint128 amount;
        bytes32 messageId; // source CCIP messageId
    }

    uint64 public immutable sourceChainSelector;
    /// @notice Destination-chain representation of the bridged token (e.g. CCIP-BnM on Base Sepolia).
    address public immutable token;
    /// @notice Fee token for ACK fees: LINK, or address(0) for native.
    address public immutable feeToken;

    address public sourceDispatcher; // set once
    uint32 public ackGasLimit = 200_000;
    bool public payoutsPaused;

    mapping(bytes32 grantId => Payout) internal _payouts;

    event SourceDispatcherSet(address dispatcher);
    event PayoutsPaused(bool paused);
    event GrantReceived(bytes32 indexed grantId, bytes32 indexed messageId, address recipient, uint256 amount);
    event PayoutSucceeded(bytes32 indexed grantId, address indexed recipient, uint256 amount);
    event PayoutHeld(bytes32 indexed grantId, address indexed recipient, uint256 amount, bytes reason);
    event PayoutRecovered(bytes32 indexed grantId, address indexed to, uint256 amount);
    event AckSent(bytes32 indexed grantId, bytes32 indexed ackMessageId, uint8 outcome);
    event AckFailed(bytes32 indexed grantId, uint8 outcome, bytes reason);

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

    constructor(address router_, uint64 sourceChainSelector_, address token_, address feeToken_, address owner_)
        CCIPReceiver(router_)
        Ownable(owner_)
    {
        if (token_ == address(0)) revert ZeroAddress();
        sourceChainSelector = sourceChainSelector_;
        token = token_;
        feeToken = feeToken_;
    }

    receive() external payable {} // native ACK-fee reserve

    // ------------------------------------------------------------------ admin

    function setSourceDispatcher(address dispatcher_) external onlyOwner {
        if (sourceDispatcher != address(0)) revert AlreadySet();
        if (dispatcher_ == address(0)) revert ZeroAddress();
        sourceDispatcher = dispatcher_;
        emit SourceDispatcherSet(dispatcher_);
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
        if (message.sourceChainSelector != sourceChainSelector || sender != sourceDispatcher || sender == address(0))
        {
            revert UnknownSource(message.sourceChainSelector, sender);
        }
        if (message.destTokenAmounts.length != 1 || message.destTokenAmounts[0].token != token) {
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
        emit GrantReceived(grantId, message.messageId, recipient, amount);

        if (payoutsPaused) {
            p.outcome = AckLib.HELD;
            emit PayoutHeld(grantId, recipient, amount, abi.encodeWithSelector(Paused.selector));
        } else {
            p.outcome = AckLib.PAID; // optimistic, written before the external call (checks-effects-interactions)
            try this.executePayout(recipient, amount) {
                emit PayoutSucceeded(grantId, recipient, amount);
            } catch (bytes memory reason) {
                p.outcome = AckLib.HELD;
                emit PayoutHeld(grantId, recipient, amount, reason);
            }
        }

        _ack(grantId);
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function executePayout(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(token).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ held funds

    /// @notice Retry paying a HELD grant to its original recipient. Anyone may call (funds can only go to the recipient).
    function retryPayout(bytes32 grantId) external {
        if (payoutsPaused) revert Paused();
        Payout storage p = _payouts[grantId];
        if (p.outcome != AckLib.HELD) revert NotHeld(grantId);
        p.outcome = AckLib.PAID;
        IERC20(token).safeTransfer(p.recipient, p.amount);
        emit PayoutSucceeded(grantId, p.recipient, p.amount);
        _ack(grantId);
    }

    /// @notice DAO recovery of a HELD grant to an alternate address (e.g. recipient key lost or sanctioned).
    function recover(bytes32 grantId, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        Payout storage p = _payouts[grantId];
        if (p.outcome != AckLib.HELD) revert NotHeld(grantId);
        p.outcome = AckLib.RECOVERED;
        IERC20(token).safeTransfer(to, p.amount);
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
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function sendAck(bytes32 grantId) external returns (bytes32) {
        if (msg.sender != address(this)) revert OnlySelf();
        Payout storage p = _payouts[grantId];

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(sourceDispatcher),
            data: AckLib.encodeAck(grantId, p.messageId, p.amount, p.outcome),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: feeToken,
            extraArgs: ExtraArgsLib.encode(ackGasLimit)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(sourceChainSelector, message);
        if (feeToken == address(0)) {
            if (address(this).balance < fee) revert InsufficientFee(address(this).balance, fee);
            return router.ccipSend{value: fee}(sourceChainSelector, message);
        }
        uint256 feeBal = IERC20(feeToken).balanceOf(address(this));
        if (feeBal < fee) revert InsufficientFee(feeBal, fee);
        IERC20(feeToken).forceApprove(address(router), fee);
        return router.ccipSend(sourceChainSelector, message);
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
            if (feeToken == token) revert UnexpectedTokens();
            IERC20(feeToken).safeTransfer(to, amount);
        }
    }
}
