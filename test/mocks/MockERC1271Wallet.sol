// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// Minimal Safe-like contract wallet: a signature is valid if produced by its single owner key.
contract MockERC1271Wallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return (err == ECDSA.RecoverError.NoError && rec == owner) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
