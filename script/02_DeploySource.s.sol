// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {NidhiScript} from "./NidhiScript.sol";
import {ENSv2Authority, IENSv2Registry} from "../src/ENSv2Authority.sol";
import {NidhiHook} from "../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";
import {INidhiDispatcher} from "../src/interfaces/INidhiDispatcher.sol";
import {IGrantAuthority} from "../src/interfaces/IGrantAuthority.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IBurnMintDrip {
    function drip(address to) external;
}

/// @notice Step 2 (Sepolia): deploy the source side and a WETH / CCIP-BnM pool guarded by NidhiHook.
///   Pool price ~1 WETH = 1000 CCIP-BnM (tick 69060), full-range seed liquidity, 0.30% fee.
/// forge script script/02_DeploySource.s.sol --rpc-url sepolia --broadcast
contract DeploySource is NidhiScript {
    using PoolIdLibrary for PoolKey;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant INIT_TICK = 69060; // price token1/token0 ~= 998 (WETH is currency0)

    struct Deployed {
        ENSv2Authority authority;
        NidhiSwapRouter router;
        NidhiDispatcher dispatcher;
        NidhiHook hook;
        PoolKey key;
    }

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);
        string memory label = vm.parseJsonString(vm.readFile(ENS_JSON), ".label");
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.002 ether));
        uint256 seedDrips = vm.envOr("SEED_BNM_DRIPS", uint256(3)); // 1 CCIP-BnM per drip
        uint256 linkForFees = vm.envOr("DISPATCHER_LINK", uint256(5 ether));

        vm.startBroadcast(pk);
        Deployed memory d = _deployCore(deployer, label);
        _createPool(d, seedWeth, seedDrips, deployer);
        IERC20Min(SEP_LINK).transfer(address(d.dispatcher), linkForFees);
        vm.stopBroadcast();

        _write(d, deployer, label);
    }

    function _deployCore(address deployer, string memory label) internal returns (Deployed memory d) {
        d.authority = new ENSv2Authority(IENSv2Registry(ENS_ETH_REGISTRY), label);
        d.router = new NidhiSwapRouter(IPoolManager(SEP_POOL_MANAGER), SEP_WETH, PERMIT2);
        d.dispatcher = new NidhiDispatcher(SEP_CCIP_ROUTER, SEP_LINK, BASE_SELECTOR, deployer);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(SEP_POOL_MANAGER), IGrantAuthority(address(d.authority)), INidhiDispatcher(address(d.dispatcher)), address(d.router), deployer
        );
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(NidhiHook).creationCode, args);
        d.hook = new NidhiHook{salt: salt}(
            IPoolManager(SEP_POOL_MANAGER), IGrantAuthority(address(d.authority)), INidhiDispatcher(address(d.dispatcher)), address(d.router), deployer
        );
        require(address(d.hook) == predicted, "hook address mismatch");
        d.dispatcher.setHook(address(d.hook));
    }

    function _createPool(Deployed memory d, uint256 seedWeth, uint256 seedDrips, address deployer) internal {
        // Sort currency addresses — Uniswap v4 requires currency0 < currency1 as uint160.
        (Currency c0, Currency c1) = SEP_WETH < SEP_BNM
            ? (Currency.wrap(SEP_WETH), Currency.wrap(SEP_BNM))
            : (Currency.wrap(SEP_BNM), Currency.wrap(SEP_WETH));
        d.key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(d.hook))
        });
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(INIT_TICK);
        IPoolManager(SEP_POOL_MANAGER).initialize(d.key, sqrtPrice);
        d.hook.setPool(d.key);

        IWETH9(SEP_WETH).deposit{value: seedWeth}();
        for (uint256 i; i < seedDrips; ++i) IBurnMintDrip(SEP_BNM).drip(deployer);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(SEP_POOL_MANAGER));
        IWETH9(SEP_WETH).approve(address(lp), type(uint256).max);
        IERC20Min(SEP_BNM).approve(address(lp), type(uint256).max);

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            seedWeth,
            seedDrips * 1 ether
        );
        // keep a small margin for rounding
        liquidity = liquidity * 99 / 100;
        lp.modifyLiquidity(d.key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
    }

    function _write(Deployed memory d, address deployer, string memory label) internal {
        string memory o = "sepolia";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeString(o, "ensName", string.concat(label, ".eth"));
        vm.serializeAddress(o, "authority", address(d.authority));
        vm.serializeAddress(o, "router", address(d.router));
        vm.serializeAddress(o, "dispatcher", address(d.dispatcher));
        vm.serializeAddress(o, "hook", address(d.hook));
        vm.serializeAddress(o, "poolManager", SEP_POOL_MANAGER);
        vm.serializeAddress(o, "tokenIn", SEP_WETH);
        vm.serializeAddress(o, "tokenOut", SEP_BNM);
        vm.serializeUint(o, "fee", FEE);
        vm.serializeInt(o, "tickSpacing", TICK_SPACING);
        string memory json = vm.serializeBytes32(o, "poolId", PoolId.unwrap(d.key.toId()));
        vm.writeJson(json, SEP_JSON);

        console2.log("ENSv2Authority :", address(d.authority));
        console2.log("NidhiSwapRouter:", address(d.router));
        console2.log("NidhiDispatcher:", address(d.dispatcher));
        console2.log("NidhiHook      :", address(d.hook));
        console2.log("Pool id        :");
        console2.logBytes32(PoolId.unwrap(d.key.toId()));
    }
}
