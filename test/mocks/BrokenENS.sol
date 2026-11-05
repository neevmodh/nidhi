// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Adversarial ENS components used to prove ENSv2Authority.resolveGrantee fails closed.
contract RevertingSubregistry {
    function getResolver(string calldata) external pure returns (address) {
        revert("boom");
    }
}

contract FixedSubregistry {
    address public immutable res;

    constructor(address r) {
        res = r;
    }

    function getResolver(string calldata) external view returns (address) {
        return res;
    }
}

contract RevertingResolver {
    function resolve(bytes calldata, bytes calldata) external pure returns (bytes memory) {
        revert("nope");
    }
}

contract ShortReturnResolver {
    function resolve(bytes calldata, bytes calldata) external pure returns (bytes memory) {
        return hex"01"; // < 64 bytes: not an ABI-encoded `bytes`
    }
}

contract WrongLengthResolver {
    function resolve(bytes calldata, bytes calldata) external pure returns (bytes memory) {
        return abi.encode(hex"deadbeef"); // well-formed bytes, but not a 20-byte address
    }
}
