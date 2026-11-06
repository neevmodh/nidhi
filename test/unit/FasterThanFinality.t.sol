// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {ExtraArgsLib} from "../../src/libraries/ExtraArgsLib.sol";
import {Mandate} from "../../src/libraries/Mandate.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";

/// @dev exposes the library so a test can inspect the bytes it builds
contract ExtraArgsHarness {
    function v2(uint256 gas) external pure returns (bytes memory) {
        return ExtraArgsLib.encode(gas);
    }

    function withFinality(uint32 gas, bytes4 f) external pure returns (bytes memory) {
        return ExtraArgsLib.encode(gas, f);
    }
}

/// CCIP 2.0 Faster-Than-Finality: the dispatcher requests a block depth per destination, and the receiver accepts
/// it only from its known source dispatcher. Full finality stays the default on both sides.
contract FasterThanFinalityTest is NidhiBase {
    ExtraArgsHarness internal h = new ExtraArgsHarness();
    bytes4 constant DEPTH_32 = bytes4(uint32(32));
    bytes4 constant DEPTH_25 = bytes4(uint32(25));
    bytes4 constant DEPTH_20 = bytes4(uint32(20));

    function test_extraArgs_defaultIsV2WaitForFinality() public view {
        bytes memory a = h.withFinality(600_000, bytes4(0));
        assertEq(keccak256(a), keccak256(h.v2(600_000)), "no finality requested: identical V2 bytes");
        assertEq(bytes4(a), bytes4(0x181dcf10), "GenericExtraArgsV2 tag");
    }

    function test_extraArgs_requestedFinalityUsesV3() public view {
        bytes memory a = h.withFinality(600_000, DEPTH_32);
        assertEq(bytes4(a), bytes4(0xa69dd4aa), "GenericExtraArgsV3 tag");
        assertEq(a.length, 19, "tag + gasLimit + finality + 7 zero length bytes");
        bytes4 gl;
        bytes4 fin;
        assembly {
            gl := mload(add(a, 36)) // bytes 4..7
            fin := mload(add(a, 40)) // bytes 8..11
        }
        assertEq(uint32(gl), 600_000, "gas limit");
        assertEq(fin, DEPTH_32, "requested block depth");
    }

    function test_dispatcher_finalityIsPerDestinationAndOwnerOnly() public {
        assertEq(dispatcher.requestedFinality(chainSelector), bytes4(0), "default: full finality");
        vm.prank(daoOwner);
        dispatcher.setRequestedFinality(chainSelector, DEPTH_32);
        assertEq(dispatcher.requestedFinality(chainSelector), DEPTH_32);
        assertEq(dispatcher.requestedFinality(chainSelector + 1), bytes4(0), "other lanes unchanged");

        vm.expectRevert();
        dispatcher.setRequestedFinality(chainSelector, DEPTH_25); // not the owner
    }

    function test_dispatcher_rejectsMalformedFinality() public {
        vm.startPrank(daoOwner);
        // a flag combined with a depth is two modes at once
        vm.expectRevert();
        dispatcher.setRequestedFinality(chainSelector, bytes4(uint32((1 << 16) | 32)));
        vm.stopPrank();
    }

    function test_receiver_allowsFastFinalityOnlyFromItsSource() public {
        bytes memory known = abi.encode(address(dispatcher));
        bytes memory stranger = abi.encode(makeAddr("stranger"));
        (,,, bytes4 f) = receiver.getCCVsAndFinalityConfig(chainSelector, known);
        assertEq(f, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "default: finality only");

        vm.prank(daoOwner);
        receiver.setAllowedFinality(DEPTH_20);
        (,,, f) = receiver.getCCVsAndFinalityConfig(chainSelector, known);
        assertEq(f, DEPTH_20, "known dispatcher: 20+ blocks allowed");
        (,,, f) = receiver.getCCVsAndFinalityConfig(chainSelector, stranger);
        assertEq(f, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "anyone else: still full finality");
        (,,, f) = receiver.getCCVsAndFinalityConfig(chainSelector + 1, known);
        assertEq(f, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "unknown chain: full finality");

        vm.expectRevert();
        receiver.setAllowedFinality(bytes4(0)); // not the owner
    }

    function test_receiver_policyAcceptsDeeperRequestsOnly() public {
        vm.prank(daoOwner);
        receiver.setAllowedFinality(DEPTH_20);
        (,,, bytes4 allowed) = receiver.getCCVsAndFinalityConfig(chainSelector, abi.encode(address(dispatcher)));
        FinalityCodec._ensureRequestedFinalityAllowed(DEPTH_25, allowed); // 25 >= 20: fine
        FinalityCodec._ensureRequestedFinalityAllowed(DEPTH_32, allowed); // 32 >= 20: fine
        FinalityCodec._ensureRequestedFinalityAllowed(bytes4(0), allowed); // full finality: always fine
        vm.expectRevert(
            abi.encodeWithSelector(FinalityCodec.InvalidRequestedFinality.selector, bytes4(uint32(10)), DEPTH_20)
        );
        this.ensureAllowed(bytes4(uint32(10)), allowed); // 10 < 20: refused
    }

    function ensureAllowed(bytes4 requested, bytes4 allowed) external pure {
        FinalityCodec._ensureRequestedFinalityAllowed(requested, allowed);
    }

    function test_fullGrantSettlesWithFasterThanFinality() public {
        vm.startPrank(daoOwner);
        dispatcher.setRequestedFinality(chainSelector, DEPTH_25);
        receiver.setAllowedFinality(DEPTH_20);
        vm.stopPrank();
        Mandate memory m = _mandate(_newGrantId(), 0.001 ether);
        _swap(m, _hookData(m));
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED), "settled");
        assertGt(bnm.balanceOf(recipient), 0, "grantee paid");
    }
}
