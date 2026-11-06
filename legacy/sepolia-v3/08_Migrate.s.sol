// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {NidhiScript} from "./NidhiScript.sol";

interface IFeeWithdraw {
    function withdrawFees(address to, uint256 amount) external;
}

interface IBal {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 8: retire the v2 deployment and recover every asset it holds.
///   Sepolia      : pull the v2 seed liquidity (held by v4's test router - removable by anyone, see
///                  test/fork/DrainCheck.t.sol) back to the deployer, and withdraw the v2 dispatcher's LINK.
///   Base Sepolia : withdraw the v2 receiver's native ACK-fee reserve.
/// forge script script/08_Migrate.s.sol --rpc-url sepolia --broadcast
/// forge script script/08_Migrate.s.sol --rpc-url base_sepolia --broadcast
contract Migrate is NidhiScript {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant V2_HOOK = 0xA400E9c24EFf13D9E3AdDa47301Ed875E3dBc0C4;
    address constant V2_LP_ROUTER = 0x7430E9dBba3c21Eaa01BD600EC22181Ea55d1C96;
    address constant V2_DISPATCHER = 0x825742ff3b49e16E6872A3B0eE89e1883AcDaca3;
    address constant V2_RECEIVER = 0xc4df9D78f3A1031e331235678758020b493A58f9;

    function run() external {
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);

        if (block.chainid == 11155111) {
            PoolKey memory key = PoolKey(Currency.wrap(SEP_WETH), Currency.wrap(SEP_BNM), 3000, 60, IHooks(V2_HOOK));
            (uint128 liq,,) =
                IPoolManager(SEP_POOL_MANAGER).getPositionInfo(key.toId(), V2_LP_ROUTER, -887220, 887220, bytes32(0));
            uint256 link = IBal(SEP_LINK).balanceOf(V2_DISPATCHER);
            vm.startBroadcast(pk);
            if (liq > 0) {
                PoolModifyLiquidityTest(payable(V2_LP_ROUTER))
                    .modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, -int256(uint256(liq)), 0), "");
            }
            if (link > 0) IFeeWithdraw(V2_DISPATCHER).withdrawFees(deployer, link);
            vm.stopBroadcast();
            console2.log("v2 liquidity removed :", liq);
            console2.log("v2 LINK recovered    :", link);
            console2.log(
                "deployer WETH / BnM  :", IBal(SEP_WETH).balanceOf(deployer), IBal(SEP_BNM).balanceOf(deployer)
            );
        } else if (block.chainid == 84532) {
            uint256 bal = V2_RECEIVER.balance;
            vm.startBroadcast(pk);
            if (bal > 0) IFeeWithdraw(V2_RECEIVER).withdrawFees(deployer, bal);
            vm.stopBroadcast();
            console2.log("v2 receiver ETH recovered:", bal);
        } else {
            revert("run on sepolia or base_sepolia");
        }
    }
}
