// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// Confirms the v2 seed position (held by v4's test router) can be removed by ANY address - the reason v3 mints
/// through PositionManager. Also proves the migration path can recover it.
contract DrainCheckTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_v2PoolLiquidityIsRemovableByAnyone() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, 12070432); // historical: the v2 pool, one block before 08_Migrate recovered it
        IPoolManager pm = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        PoolModifyLiquidityTest lp = PoolModifyLiquidityTest(payable(0x7430E9dBba3c21Eaa01BD600EC22181Ea55d1C96));
        PoolKey memory key = PoolKey(
            Currency.wrap(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9),
            Currency.wrap(0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05),
            3000,
            60,
            IHooks(0xA400E9c24EFf13D9E3AdDa47301Ed875E3dBc0C4)
        );
        uint128 before = pm.getLiquidity(key.toId());
        (uint128 posLiq,,) = pm.getPositionInfo(key.toId(), address(lp), -887220, 887220, bytes32(0));
        console2.log("pool liquidity", before, "position", posLiq);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, -int256(uint256(posLiq)), 0), "");
        assertEq(pm.getLiquidity(key.toId()), before - posLiq, "a stranger removed the seed liquidity");
    }
}
