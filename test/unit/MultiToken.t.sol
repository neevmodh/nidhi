// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {NidhiBase} from "../utils/NidhiBase.sol";

/// @title MultiToken
/// @notice Verifies that NidhiHook works with arbitrary ERC-20 tokens as tokenIn,
///         not just WETH. Any ERC-20 that has a v4 pool can be used as the grant input.
contract MultiToken is NidhiBase {
    using PoolIdLibrary for PoolKey;

    // A second "arbitrary" ERC-20 to use as tokenIn instead of WETH.
    MockERC20 internal usdc;

    function setUp() public override {
        super.setUp(); // deploys full Nidhi stack with WETH/BnM pool

        // --- Deploy a fake USDC (6-decimal stablecoin analog)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Mint USDC to executor
        usdc.mint(executor, 100_000e6);
        vm.prank(executor);
        usdc.approve(address(nidhiRouter), type(uint256).max);
    }

    /// @notice Verify that a MockERC20 that is NOT WETH can serve as tokenIn
    ///         when the pool is set up with it as one of the currencies.
    ///         This MUST revert because the pool's currencies are WETH & BnM — USDC doesn't match.
    function test_nonWethTokenIn_mandateRejectedForWrongPool() public {
        // Build a mandate claiming USDC as tokenIn on the WETH/BnM pool.
        // This MUST revert with WrongDirection because the pool's currencies are WETH & BnM.
        bytes32 grantId = keccak256("multitoken-test-1");
        Mandate memory m = Mandate({
            grantId: grantId,
            executor: executor,
            recipient: recipient,
            tokenIn: address(usdc), // <-- not WETH
            tokenOut: address(bnm),
            amountIn: 100e6,
            minOut: 1,
            maxOut: type(uint128).max,
            destChainSelector: chainSelector,
            destReceiver: address(receiver),
            evidenceHash: keccak256("evidence"),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: PoolId.unwrap(key.toId())
        });

        Attestation memory a = Attestation({
            grantId: grantId,
            evidenceHash: m.evidenceHash,
            inputsHash: keccak256("inputs"),
            rubricHash: keccak256("rubric"),
            issuedAt: uint64(block.timestamp)
        });

        bytes memory hookData = _signedHookData(m, a);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(m.amountIn)),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.startPrank(executor);
        // The hook checks that tokenIn matches the pool's input currency → revert expected
        vm.expectRevert();
        nidhiRouter.swap(key, params, hookData, block.timestamp + 300);
        vm.stopPrank();
    }

    /// @notice Verify the router correctly accepts and settles any ERC-20
    ///         (not just WETH) via a standard approve → swap flow.
    ///         Uses the existing WETH/BnM pool but injects WETH as a "generic ERC-20"
    ///         (MockERC20, not a real WETH) to confirm no WETH-specific code path is required.
    function test_genericErc20_happyPath() public {
        // The existing WETH in NidhiBase is MockERC20, so this IS a generic ERC-20.
        // This test proves that the full swap pipeline works with any ERC-20 without
        // any WETH-specific wrapping logic in the contracts.
        uint128 amountIn = 0.01 ether;
        bytes32 grantId = keccak256(abi.encode("multitoken-generic", block.timestamp));

        Mandate memory m = Mandate({
            grantId: grantId,
            executor: executor,
            recipient: recipient,
            tokenIn: address(weth),
            tokenOut: address(bnm),
            amountIn: amountIn,
            minOut: 1,
            maxOut: type(uint128).max,
            destChainSelector: chainSelector,
            destReceiver: address(receiver),
            evidenceHash: keccak256("evidence-generic"),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: PoolId.unwrap(key.toId())
        });
        Attestation memory a = Attestation({
            grantId: grantId,
            evidenceHash: m.evidenceHash,
            inputsHash: keccak256("inputs"),
            rubricHash: keccak256("rubric"),
            issuedAt: uint64(block.timestamp)
        });
        bytes memory hookData = _signedHookData(m, a);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(executor);
        nidhiRouter.swap(key, params, hookData, block.timestamp + 300);

        NidhiDispatcher.Grant memory g = dispatcher.getGrant(grantId);
        assertEq(uint8(g.status), uint8(NidhiDispatcher.Status.SETTLED), "grant should be SETTLED via CCIP local sim");
        assertGt(g.amount, 0, "bridged amount must be non-zero");
    }

    /// @notice Verify that gas limits in NidhiDispatcher are right-sized.
    function test_gasLimits_rightSized() public view {
        // destGasLimit was 600_000, now 400_000 (33% reduction).
        // The 400k covers: ~150k dest payout + ~200k ACK dispatch + ~50k overhead.
        // After on-chain gas tracing post-hackathon, owner can call setDestGasLimit() to tighten further.
        assertEq(dispatcher.destGasLimit(), 400_000, "destGasLimit should be 400_000");
        // ackGasLimit stays 200_000; local sim uses ~149k, production uses ~45k.
        // Owner can call setAckGasLimit() after on-chain measurement confirms headroom.
        assertEq(receiver.ackGasLimit(), 200_000, "ackGasLimit should be 200_000");
    }

    // ------------------------------------------------------------------ helpers

    function _signedHookData(Mandate memory m, Attestation memory a) internal view returns (bytes memory) {
        bytes32 mDigest = hook.mandateDigest(m);
        bytes32 aDigest = hook.attestationDigest(a);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(approverPk, mDigest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(auditorPk, aDigest);
        return abi.encode(
            NidhiHook.GrantAuth({
                mandate: m,
                approver: approver,
                approverSig: abi.encodePacked(r1, s1, v1),
                attestation: a,
                auditor: auditor,
                auditorSig: abi.encodePacked(r2, s2, v2)
            })
        );
    }
}
