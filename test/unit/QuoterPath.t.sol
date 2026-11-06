// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {Mandate} from "../../src/libraries/Mandate.sol";

/// @notice The canonical Uniswap V4Quoter can price Nidhi's gated pool exactly, and can never move anything.
contract QuoterPathTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;

    function _quote(IV4Quoter q, uint128 amountIn) internal returns (uint256 out) {
        (out,) = q.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: ""
            })
        );
    }

    function test_officialQuoterQuoteEqualsRealPayout() public {
        uint256 quoted = _quote(quoter, AMOUNT_IN);
        assertGt(quoted, 0);

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.minOut = uint128(quoted); // band pinned to the quote exactly
        m.maxOut = uint128(quoted);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        assertEq(bnm.balanceOf(recipient), quoted, "grantee receives exactly the quoted amount");
    }

    function test_quoteLeavesNoTrace() public {
        uint256 remainingBefore = hook.remainingToday();
        uint256 hookBnm = bnm.balanceOf(address(hook));
        uint256 dispBnm = bnm.balanceOf(address(dispatcher));
        (uint160 sqrtBefore,,,) = _slot0();

        _quote(quoter, AMOUNT_IN);

        (uint160 sqrtAfter,,,) = _slot0();
        assertEq(sqrtAfter, sqrtBefore, "pool price unchanged");
        assertEq(hook.remainingToday(), remainingBefore, "cap untouched");
        assertEq(bnm.balanceOf(address(hook)), hookBnm);
        assertEq(bnm.balanceOf(address(dispatcher)), dispBnm);
    }

    function test_quotingWorksWhilePaused() public {
        vm.prank(guardian);
        hook.setPaused(true);
        assertGt(_quote(quoter, AMOUNT_IN), 0, "pricing stays available during an incident; payouts do not");
    }

    function test_revert_lookalikeQuoterGetsNoBypass() public {
        V4Quoter fake = new V4Quoter(manager); // same code, different address
        vm.expectRevert(); // UntrustedRouter, wrapped by the quoter's parse
        _quote(fake, AMOUNT_IN);
    }

    function test_quoterDisabledWhenUnset() public {
        address hookAddr = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                ^ (0x5555 << 144)
        );
        deployCodeTo(
            "NidhiHook.sol:NidhiHook",
            abi.encode(
                manager, authority, dispatcher, address(nidhiRouter), daoOwner, DAILY_CAP, address(0), _noGuard()
            ),
            hookAddr
        );
        assertEq(NidhiHook(hookAddr).quoter(), address(0));
    }

    function _slot0() internal view returns (uint160, int24, uint24, uint24) {
        bytes32 slot = keccak256(abi.encode(key.toId(), bytes32(uint256(6)))); // StateLibrary.POOLS_SLOT = 6
        bytes32 data = manager.extsload(slot);
        return (uint160(uint256(data)), 0, 0, 0);
    }
}
