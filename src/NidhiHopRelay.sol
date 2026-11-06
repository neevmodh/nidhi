// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AckLib} from "./libraries/AckLib.sol";
import {ExtraArgsLib} from "./libraries/ExtraArgsLib.sol";

/// @title NidhiHopRelay
/// @notice Multi-hop CCIP for grants: pays a chain that has no direct lane from the source.
///
///   source dispatcher ──CCIP──▶ relay (middle chain) ──CCIP──▶ DestinationReceiver (final chain) ──▶ grantee
///   source dispatcher ◀──ACK── relay ◀──────────────ACK────── DestinationReceiver
///
/// To the source dispatcher the relay IS the destination receiver: it gets the grant message (tokens + payload), and
/// later returns an ACK in exactly the format the dispatcher expects (its own inbound messageId, the amount, the
/// outcome). To the final receiver the relay IS the source dispatcher. Neither contract changes.
///
/// Defensive like the receiver: a forward or an ACK that cannot be sent (fee reserve too low) never reverts the CCIP
/// delivery. The grant is parked and anyone can retry once the relay is funded. Messages are told apart by their
/// sender, not their chain selector, so the relay is also correct when every hop shares one selector (local simulator).
///
/// Gas: the forward happens inside ccipReceive, so the SOURCE's destGasLimit must cover a CCIP send (about 2M on CCIP 2.0
/// testnet onramps), and the final receiver's ackGasLimit must cover the relayed ACK. When retrying by hand, pass an
/// explicit gas limit: estimators stop at the lowest gas where the try/catch "succeeds", which is too little for the send.
contract NidhiHopRelay is CCIPReceiver, Ownable2Step {
    using SafeERC20 for IERC20;

    enum HopStatus {
        NONE,
        FORWARD_PENDING, // received from upstream, onward send failed: retryForward()
        FORWARDED, // in flight to the final chain
        ACK_PENDING, // final receiver acknowledged, upstream ACK failed: retryAck()
        ACKED // upstream ACK sent
    }

    struct Hop {
        HopStatus status;
        uint8 outcome;
        uint64 upstreamSelector;
        address upstream; // the source dispatcher
        address token;
        address recipient;
        uint128 amount;
        bytes32 inboundMessageId; // the source's messageId: the ACK must carry it back
        bytes32 onwardMessageId;
    }

    /// @notice CCIP selector of the final chain this relay forwards to, and the receiver there. Set once.
    uint64 public onwardSelector;
    address public onwardReceiver;
    /// @notice upstream chain selector => source dispatcher allowed to send through this relay. Add-only.
    mapping(uint64 => address) public upstreams;
    mapping(address => bool) public allowedToken;
    uint32 public gasLimit = 600_000;

    mapping(bytes32 grantId => Hop) internal _hops;

    event OnwardSet(uint64 indexed selector, address receiver);
    event UpstreamAdded(uint64 indexed selector, address dispatcher);
    event TokenAllowed(address indexed token);
    event HopReceived(
        bytes32 indexed grantId, bytes32 indexed inboundMessageId, uint64 upstreamSelector, uint256 amount
    );
    event HopForwarded(bytes32 indexed grantId, bytes32 indexed onwardMessageId, uint64 onwardSelector, uint256 fee);
    event HopForwardFailed(bytes32 indexed grantId, bytes reason);
    event HopAckRelayed(bytes32 indexed grantId, bytes32 indexed ackMessageId, uint8 outcome);
    event HopAckFailed(bytes32 indexed grantId, bytes reason);

    error AlreadySet();
    error ZeroAddress();
    error UnknownSender(uint64 selector, address sender);
    error UnexpectedTokens();
    error DuplicateGrant(bytes32 grantId);
    error UnknownGrant(bytes32 grantId);
    error BadAck(bytes32 grantId);
    error NotPending(bytes32 grantId);
    error OnlySelf();
    error InsufficientFee(uint256 have, uint256 need);

    constructor(address router_, address owner_) CCIPReceiver(router_) Ownable(owner_) {}

    receive() external payable {} // native fee reserve for the onward send and the upstream ACK

    // ------------------------------------------------------------------ wiring (set-once / add-only)

    function setOnward(uint64 selector, address receiver_) external onlyOwner {
        if (onwardReceiver != address(0)) revert AlreadySet();
        if (selector == 0 || receiver_ == address(0)) revert ZeroAddress();
        (onwardSelector, onwardReceiver) = (selector, receiver_);
        emit OnwardSet(selector, receiver_);
    }

    function addUpstream(uint64 selector, address dispatcher) external onlyOwner {
        if (upstreams[selector] != address(0)) revert AlreadySet();
        if (selector == 0 || dispatcher == address(0)) revert ZeroAddress();
        upstreams[selector] = dispatcher;
        emit UpstreamAdded(selector, dispatcher);
    }

    event GasLimitSet(uint32 gasLimit);

    /// @notice Gas for the final receiver's ccipReceive (it pays out and sends its ACK).
    function setGasLimit(uint32 gasLimit_) external onlyOwner {
        gasLimit = gasLimit_;
        emit GasLimitSet(gasLimit_);
    }

    function allowToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedToken[token] = true;
        emit TokenAllowed(token);
    }

    // ------------------------------------------------------------------ CCIP in

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        if (sender == onwardReceiver && message.sourceChainSelector == onwardSelector) {
            _onAck(message);
        } else if (sender != address(0) && sender == upstreams[message.sourceChainSelector]) {
            _onGrant(message, sender);
        } else {
            revert UnknownSender(message.sourceChainSelector, sender);
        }
    }

    function _onGrant(Client.Any2EVMMessage memory message, address upstream) private {
        if (message.destTokenAmounts.length != 1 || !allowedToken[message.destTokenAmounts[0].token]) {
            revert UnexpectedTokens();
        }
        (bytes32 grantId, address recipient, uint256 amount) = AckLib.decodeGrant(message.data);
        if (amount != message.destTokenAmounts[0].amount) revert UnexpectedTokens();
        Hop storage h = _hops[grantId];
        if (h.status != HopStatus.NONE) revert DuplicateGrant(grantId);
        h.upstreamSelector = message.sourceChainSelector;
        h.upstream = upstream;
        h.token = message.destTokenAmounts[0].token;
        h.recipient = recipient;
        h.amount = SafeCast.toUint128(amount);
        h.inboundMessageId = message.messageId;
        emit HopReceived(grantId, message.messageId, message.sourceChainSelector, amount);
        _forward(grantId);
    }

    function _onAck(Client.Any2EVMMessage memory message) private {
        if (message.destTokenAmounts.length != 0) revert UnexpectedTokens();
        (bytes32 grantId, bytes32 onwardMessageId, uint256 amount, uint8 outcome) = AckLib.decodeAck(message.data);
        Hop storage h = _hops[grantId];
        if (h.status == HopStatus.NONE) revert UnknownGrant(grantId);
        if (amount != h.amount) revert BadAck(grantId);
        // The ACK can land before our own send returned (synchronous delivery): adopt its id, else it must match.
        if (h.onwardMessageId == bytes32(0) && h.status == HopStatus.FORWARD_PENDING) {
            h.onwardMessageId = onwardMessageId;
        } else if (onwardMessageId != h.onwardMessageId) {
            revert BadAck(grantId);
        }
        h.outcome = outcome; // HELD then later PAID/RECOVERED: each ACK is relayed; the dispatcher keeps it monotonic
        h.status = HopStatus.ACK_PENDING;
        _relayAck(grantId);
    }

    // ------------------------------------------------------------------ CCIP out (never reverts the delivery)

    function _forward(bytes32 grantId) private {
        Hop storage h = _hops[grantId];
        h.status = HopStatus.FORWARD_PENDING;
        try this.sendOnward(grantId) returns (bytes32 id, uint256 fee) {
            if (h.onwardMessageId == bytes32(0)) h.onwardMessageId = id;
            else if (h.onwardMessageId != id) revert BadAck(grantId); // an early ACK named a different message
            if (h.status == HopStatus.FORWARD_PENDING) h.status = HopStatus.FORWARDED; // never downgrade an ACK
            emit HopForwarded(grantId, id, onwardSelector, fee);
        } catch (bytes memory reason) {
            emit HopForwardFailed(grantId, reason);
        }
    }

    function _relayAck(bytes32 grantId) private {
        try this.sendAckUpstream(grantId) returns (bytes32 id) {
            _hops[grantId].status = HopStatus.ACKED;
            emit HopAckRelayed(grantId, id, _hops[grantId].outcome);
        } catch (bytes memory reason) {
            emit HopAckFailed(grantId, reason);
        }
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function sendOnward(bytes32 grantId) external returns (bytes32, uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        Hop storage h = _hops[grantId];
        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount({token: h.token, amount: h.amount});
        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(onwardReceiver),
            data: AckLib.encodeGrant(grantId, h.recipient, h.amount),
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: ExtraArgsLib.encode(gasLimit)
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(onwardSelector, m);
        if (address(this).balance < fee) revert InsufficientFee(address(this).balance, fee);
        IERC20(h.token).forceApprove(address(router), h.amount);
        bytes32 id = router.ccipSend{value: fee}(onwardSelector, m);
        IERC20(h.token).forceApprove(address(router), 0);
        return (id, fee);
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    function sendAckUpstream(bytes32 grantId) external returns (bytes32) {
        if (msg.sender != address(this)) revert OnlySelf();
        Hop storage h = _hops[grantId];
        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(h.upstream),
            // the source dispatcher matches ACKs to ITS messageId, so the relay hands back the inbound one
            data: AckLib.encodeAck(grantId, h.inboundMessageId, h.amount, h.outcome),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: ExtraArgsLib.encode(300_000)
        });
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(h.upstreamSelector, m);
        if (address(this).balance < fee) revert InsufficientFee(address(this).balance, fee);
        return router.ccipSend{value: fee}(h.upstreamSelector, m);
    }

    // ------------------------------------------------------------------ self-healing (anyone)

    function retryForward(bytes32 grantId) external {
        if (_hops[grantId].status != HopStatus.FORWARD_PENDING) revert NotPending(grantId);
        _forward(grantId);
    }

    function retryAck(bytes32 grantId) external {
        if (_hops[grantId].status != HopStatus.ACK_PENDING) revert NotPending(grantId);
        _relayAck(grantId);
    }

    function getHop(bytes32 grantId) external view returns (Hop memory) {
        return _hops[grantId];
    }

    /// @notice The owner can withdraw spare fee reserve; grant tokens are never withdrawable.
    function withdrawFees(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }
}
