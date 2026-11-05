// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";

/// @notice The AI auditor signs Attestations with viem (offchain/src/audit.ts); the hook verifies them in Solidity.
///         This vector was produced by viem 2.57 `hashTypedData` / `signTypedData` for chainId 31337 and the test
///         hook address, with the test auditor key 0xB0B. If the two EIP-712 encodings ever drift, this fails.
contract CrossLangEIP712Test is NidhiBase {
    bytes32 constant VIEM_DIGEST = 0xd51b5be28c109538372d914f74ae209dd2f1034ff82b70fb9efbb18978bb2b3f;
    bytes constant VIEM_SIG =
        hex"53fcd65c4c9225c147385fba1c81844d1acf29ff36e23fbff2576ae765c52acf080a63a6aa4fef86f6dfde94638e3ebd077839c8580ccf9c0e3b437d2ee05c591c";

    function _vectorAttestation() internal pure returns (Attestation memory) {
        return Attestation({
            grantId: bytes32(0x1111111111111111111111111111111111111111111111111111111111111111),
            evidenceHash: bytes32(0x2222222222222222222222222222222222222222222222222222222222222222),
            inputsHash: bytes32(0x3333333333333333333333333333333333333333333333333333333333333333),
            rubricHash: bytes32(0x4444444444444444444444444444444444444444444444444444444444444444),
            issuedAt: 1793887740
        });
    }

    function test_hookAndViemAgreeOnAttestationDigest() public view {
        assertEq(block.chainid, 31337);
        assertEq(address(hook), 0x44440000000000000000000000000000000000c4);
        assertEq(hook.attestationDigest(_vectorAttestation()), VIEM_DIGEST);
    }

    function test_viemSignedAttestationPaysGrant() public {
        Attestation memory a = _vectorAttestation();
        Mandate memory m = _mandate(a.grantId, 0.001 ether);
        m.evidenceHash = a.evidenceHash;
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: approver,
            approverSig: _sign(approverPk, hook.mandateDigest(m)),
            attestation: a,
            auditor: auditor,
            auditorSig: VIEM_SIG,
            recipientLabel: GRANTEE_LABEL
        });
        _swap(m, abi.encode(g));
        assertEq(uint8(dispatcher.statusOf(a.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }
}
