// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Role oracle consulted by NidhiHook. Production impl: ENSv2Authority (EAC on a PermissionedResolver).
interface IGrantAuthority {
    /// keccak256("nidhi.role.approver")
    function APPROVER() external view returns (bytes32);
    /// keccak256("nidhi.role.auditor")
    function AUDITOR() external view returns (bytes32);

    function isAuthorized(bytes32 role, address account) external view returns (bool);
}
