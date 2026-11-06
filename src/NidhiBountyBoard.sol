// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Mandate} from "./libraries/Mandate.sol";
import {IGrantAuthority} from "./interfaces/IGrantAuthority.sol";

interface IMandateDigest {
    function mandateDigest(Mandate calldata m) external view returns (bytes32);
}

/// @title NidhiBountyBoard
/// @notice On-chain milestones that the agent can pay without a human signing at payout time.
///
/// A DAO member holding the APPROVER role (on nidhi-dao.eth via ENSv2, or any IGrantAuthority) posts a milestone here:
/// what is paid (amount, token pair, pool, price band), where (destination chain and receiver), for which spec
/// (specHash), by whom (the executor) and until when. A milestone is either ASSIGNED to one ENS name (granteeLabelHash)
/// or OPEN to whoever delivers first (granteeLabelHash = 0).
///
/// The board itself holds the APPROVER role and acts as the mandate's approver through ERC-1271. It answers
/// isValidSignature(digest, abi.encode(id, mandate)) with "valid" only if the mandate matches a live milestone field
/// for field and hashes to the digest the hook computed. The hook then still checks everything else: the AI auditor's
/// attestation (which names the winner by signing the evidence), the ENS roles, that the recipient is exactly what
/// the grantee's ENS name resolves to, the daily cap, the price band, and that the grantId was never used.
/// So the DAO decides what, how much and until when; the agent decides only who, by the published rule.
contract NidhiBountyBoard is IERC1271 {
    struct Bounty {
        address poster;
        bool cancelled;
        bytes32 grantId; // fixed per milestone: the hook pays it at most once
        bytes32 specHash; // the milestone spec the poster committed to (= the mandate's evidenceHash)
        bytes32 granteeLabelHash; // 0 = open to anyone; else keccak256(label) of the one ENS name that may be paid
        address executor;
        address tokenIn;
        address tokenOut;
        uint128 amountIn;
        uint128 minOut;
        uint128 maxOut;
        uint64 destChainSelector;
        address destReceiver;
        bytes32 poolId;
        uint64 deadline;
    }

    /// @notice Human-readable spec, emitted (not stored) so the app and the agent can show and re-hash it.
    struct Spec {
        string title;
        string repo;
        string body; // the task text
        string rules; // JSON: acceptance rules (approvals, required paths, ...)
        string grantee; // ENS label for an assigned milestone, "" for an open one
    }

    bytes4 internal constant MAGIC = 0x1626ba7e; // IERC1271.isValidSignature.selector
    bytes4 internal constant INVALID = 0xffffffff;

    IMandateDigest public immutable hook;
    IGrantAuthority public immutable authority;
    uint256 public count;
    mapping(uint256 id => Bounty) internal _bounties;

    event BountyPosted(
        uint256 indexed id, address indexed poster, bytes32 indexed grantId, bytes32 specHash, Spec spec, Bounty bounty
    );
    event BountyCancelled(uint256 indexed id, address indexed by);

    error NotApprover(address account);
    error BadBounty();
    error UnknownBounty(uint256 id);
    error NotPosterOrApprover(address account);

    constructor(IMandateDigest hook_, IGrantAuthority authority_) {
        if (address(hook_) == address(0) || address(authority_) == address(0)) revert BadBounty();
        hook = hook_;
        authority = authority_;
    }

    /// @notice Post a milestone. Only an account holding the APPROVER role (checked live, e.g. in ENS) may post.
    function post(Bounty calldata b, Spec calldata spec) external returns (uint256 id) {
        if (!authority.isAuthorized(authority.APPROVER(), msg.sender)) revert NotApprover(msg.sender);
        if (
            b.amountIn == 0 || b.minOut == 0 || b.minOut > b.maxOut || b.deadline <= block.timestamp
                || b.executor == address(0) || b.destReceiver == address(0) || b.destChainSelector == 0
                || b.specHash == bytes32(0)
        ) revert BadBounty();
        if ((b.granteeLabelHash == bytes32(0)) != (bytes(spec.grantee).length == 0)) revert BadBounty();
        if (b.granteeLabelHash != bytes32(0) && b.granteeLabelHash != keccak256(bytes(spec.grantee))) {
            revert BadBounty();
        }

        id = ++count;
        Bounty memory s = b;
        s.poster = msg.sender;
        s.cancelled = false;
        s.grantId = keccak256(abi.encode(block.chainid, address(this), id));
        _bounties[id] = s;
        emit BountyPosted(id, msg.sender, s.grantId, s.specHash, spec, s);
    }

    /// @notice Withdraw a milestone before it is paid. The poster, or any current approver, may cancel.
    function cancel(uint256 id) external {
        Bounty storage b = _bounties[id];
        if (b.poster == address(0)) revert UnknownBounty(id);
        if (msg.sender != b.poster && !authority.isAuthorized(authority.APPROVER(), msg.sender)) {
            revert NotPosterOrApprover(msg.sender);
        }
        b.cancelled = true;
        emit BountyCancelled(id, msg.sender);
    }

    function getBounty(uint256 id) external view returns (Bounty memory) {
        return _bounties[id];
    }

    /// @notice True if `m` is a payout the board would approve for milestone `id`.
    function matches(uint256 id, Mandate memory m) public view returns (bool) {
        Bounty storage b = _bounties[id];
        if (b.poster == address(0) || b.cancelled || block.timestamp > b.deadline) return false;
        if (b.granteeLabelHash != bytes32(0) && m.recipientLabelHash != b.granteeLabelHash) return false;
        return m.grantId == b.grantId && m.evidenceHash == b.specHash && m.executor == b.executor
            && m.tokenIn == b.tokenIn && m.tokenOut == b.tokenOut && m.amountIn == b.amountIn && m.minOut >= b.minOut
            && m.maxOut <= b.maxOut && m.minOut <= m.maxOut && m.destChainSelector == b.destChainSelector
            && m.destReceiver == b.destReceiver && m.poolId == b.poolId && m.deadline <= b.deadline
            && m.recipient != address(0) && m.recipientLabelHash != bytes32(0);
    }

    /// @inheritdoc IERC1271
    /// @dev signature = abi.encode(uint256 id, Mandate mandate). Valid only for a matching live milestone whose
    ///      mandate hashes to exactly the digest the hook is checking.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (signature.length < 32) return INVALID;
        (uint256 id, Mandate memory m) = abi.decode(signature, (uint256, Mandate));
        if (!matches(id, m)) return INVALID;
        return hook.mandateDigest(m) == digest ? MAGIC : INVALID;
    }
}
