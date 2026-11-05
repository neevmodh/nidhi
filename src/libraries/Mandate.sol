// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice EIP-712 structs for a Nidhi grant. Domain: name "Nidhi", version "1", chainId, verifyingContract = hook.
struct Mandate {
    bytes32 grantId; // doubles as nonce: one use only
    address executor; // only this address may submit the swap (via router.msgSender())
    address recipient; // payee on the destination chain
    address tokenIn;
    address tokenOut;
    uint128 amountIn; // exact-input
    uint128 minOut;
    uint128 maxOut;
    uint64 destChainSelector;
    address destReceiver;
    bytes32 evidenceHash;
    uint64 deadline;
    bytes32 poolId;
}

struct Attestation {
    bytes32 grantId;
    bytes32 evidenceHash;
    bytes32 inputsHash;
    bytes32 rubricHash;
    uint64 issuedAt;
}

library MandateLib {
    bytes32 internal constant MANDATE_TYPEHASH = keccak256(
        "Mandate(bytes32 grantId,address executor,address recipient,address tokenIn,address tokenOut,uint128 amountIn,uint128 minOut,uint128 maxOut,uint64 destChainSelector,address destReceiver,bytes32 evidenceHash,uint64 deadline,bytes32 poolId)"
    );

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(bytes32 grantId,bytes32 evidenceHash,bytes32 inputsHash,bytes32 rubricHash,uint64 issuedAt)"
    );

    function hash(Mandate memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(MANDATE_TYPEHASH, m));
    }

    function hash(Attestation memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(ATTESTATION_TYPEHASH, a));
    }
}
