// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Mirrors ENSv2 EnhancedAccessControl.hasRoles: (roles[ROOT] | roles[resource]) & bitmap == bitmap
contract MockEAC {
    mapping(uint256 => mapping(address => uint256)) public roles;

    function grant(uint256 resource, uint256 bitmap, address a) external {
        roles[resource][a] |= bitmap;
    }

    function revoke(uint256 resource, uint256 bitmap, address a) external {
        roles[resource][a] &= ~bitmap;
    }

    function hasRoles(uint256 resource, uint256 bitmap, address a) external view returns (bool) {
        return (roles[0][a] | roles[resource][a]) & bitmap == bitmap;
    }
}
