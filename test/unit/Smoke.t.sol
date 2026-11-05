// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Mandate, MandateLib} from "../../src/libraries/Mandate.sol";

contract SmokeTest is Test {
    function test_flagsAndHash() public pure {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(flags, 0xC4);
        Mandate memory m;
        assertTrue(MandateLib.hash(m) != bytes32(0));
    }
}
