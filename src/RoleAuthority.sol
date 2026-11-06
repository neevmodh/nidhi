// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGrantAuthority} from "./interfaces/IGrantAuthority.sol";

/// @title RoleAuthority
/// @notice Mainnet permission layer for Nidhi, used where ENSv2 is not deployed (ENSv2 exists only on Sepolia).
///         This is NOT ENS: it is an OpenZeppelin AccessControl role registry owned by the DAO's admin (a Safe or a
///         hardware wallet). It implements the same IGrantAuthority the hook already consumes, so the hook is
///         unchanged between the ENSv2 deployment and this one.
///
///   Roles (instantly grantable and revocable by the admin; a revoked role stops the next payout):
///     APPROVER  signs Mandates and may cancel unexecuted grants
///     AUDITOR   signs Attestations
///     GUARDIAN  may pause/unpause the hook (kill-switch)
///   Grantee book: `label` -> payout address per destination chain, managed by GRANTEE_ADMIN. Every change emits an
///   event. Unknown label, unknown chain or a zeroed entry resolves to address(0), and the hook then refuses to pay.
contract RoleAuthority is AccessControl, IGrantAuthority {
    bytes32 public constant APPROVER = keccak256("nidhi.role.approver");
    bytes32 public constant AUDITOR = keccak256("nidhi.role.auditor");
    bytes32 public constant GUARDIAN = keccak256("nidhi.role.guardian");
    bytes32 public constant GRANTEE_ADMIN = keccak256("nidhi.role.granteeAdmin");

    mapping(bytes32 labelHash => mapping(uint64 destSelector => address)) private _grantees;

    event GranteeSet(string label, uint64 indexed destSelector, address indexed account, address indexed by);

    error ZeroAdmin();
    error LabelTooLong();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GRANTEE_ADMIN, admin);
    }

    /// @inheritdoc IGrantAuthority
    function isAuthorized(bytes32 role, address account) external view returns (bool) {
        if (role != APPROVER && role != AUDITOR && role != GUARDIAN) return false; // only Nidhi's three roles count
        return hasRole(role, account);
    }

    /// @inheritdoc IGrantAuthority
    function resolveGrantee(string calldata label, uint64 destSelector) external view returns (address) {
        return _grantees[keccak256(bytes(label))][destSelector];
    }

    /// @notice Set (or clear, with address(0)) where `label` is paid on chain `destSelector`.
    function setGrantee(string calldata label, uint64 destSelector, address account) external onlyRole(GRANTEE_ADMIN) {
        if (bytes(label).length == 0 || bytes(label).length > 63) revert LabelTooLong();
        _grantees[keccak256(bytes(label))][destSelector] = account;
        emit GranteeSet(label, destSelector, account, msg.sender);
    }
}
