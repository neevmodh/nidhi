// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Mirrors ENSv2 PermissionedRegistry.getResolver(label): address(0) when unregistered or expired.
contract MockENSv2Registry {
    mapping(bytes32 => address) internal _resolver;
    mapping(bytes32 => uint64) internal _expiry;

    function set(string calldata label, address resolver, uint64 expiry) external {
        _resolver[keccak256(bytes(label))] = resolver;
        _expiry[keccak256(bytes(label))] = expiry;
    }

    function getResolver(string calldata label) external view returns (address) {
        bytes32 id = keccak256(bytes(label));
        return _expiry[id] > block.timestamp ? _resolver[id] : address(0);
    }
}
