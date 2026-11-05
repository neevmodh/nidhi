// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Mirrors ENSv2 PermissionedRegistry: getResolver/getSubregistry return address(0) when unregistered or expired.
contract MockENSv2Registry {
    mapping(bytes32 => address) internal _resolver;
    mapping(bytes32 => address) internal _subregistry;
    mapping(bytes32 => uint64) internal _expiry;

    function set(string calldata label, address resolver, uint64 expiry) external {
        _resolver[keccak256(bytes(label))] = resolver;
        _expiry[keccak256(bytes(label))] = expiry;
    }

    function setSubregistry(string calldata label, address sub) external {
        _subregistry[keccak256(bytes(label))] = sub;
    }

    function getResolver(string calldata label) external view returns (address) {
        bytes32 id = keccak256(bytes(label));
        return _expiry[id] > block.timestamp ? _resolver[id] : address(0);
    }

    function getSubregistry(string calldata label) external view returns (address) {
        bytes32 id = keccak256(bytes(label));
        return _expiry[id] > block.timestamp ? _subregistry[id] : address(0);
    }
}

/// Plays both the DAO's UserRegistry (getResolver) and the grants PermissionedResolver (ENSIP-10 resolve).
contract MockGranteeRegistry {
    string public daoLabel;
    mapping(bytes32 => bool) internal _live;
    mapping(bytes32 => bytes) internal _addrByName;

    constructor(string memory daoLabel_) {
        daoLabel = daoLabel_;
    }

    function dnsName(string memory label) public view returns (bytes memory) {
        return abi.encodePacked(
            uint8(bytes(label).length), label, uint8(bytes(daoLabel).length), daoLabel, uint8(3), "eth", uint8(0)
        );
    }

    function setGrantee(string calldata label, address a) external {
        _live[keccak256(bytes(label))] = true;
        _addrByName[keccak256(dnsName(label))] = a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function expire(string calldata label) external {
        _live[keccak256(bytes(label))] = false;
    }

    function getResolver(string calldata label) external view returns (address) {
        return _live[keccak256(bytes(label))] ? address(this) : address(0);
    }

    function resolve(bytes calldata name, bytes calldata) external view returns (bytes memory) {
        return abi.encode(_addrByName[keccak256(name)]);
    }
}
