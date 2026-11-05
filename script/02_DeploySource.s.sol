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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {NidhiScript} from "./NidhiScript.sol";
import {IPermissionedResolver} from "./ens/IENSv2.sol";
import {ENSv2Authority, IENSv2Registry} from "../src/ENSv2Authority.sol";
import {NidhiHook} from "../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";
import {INidhiDispatcher} from "../src/interfaces/INidhiDispatcher.sol";
import {IGrantAuthority} from "../src/interfaces/IGrantAuthority.sol";

interface IWETH9 {
    function deposit() external payable;
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 2 (Sepolia), v3: deploy the source side.
///   - ENSv2Authority (roles + grantee subnames resolved live from nidhi-dao.eth), router, dispatcher.
///   - NidhiHook mined to flags 0xC4 with a rolling daily cap (DAILY_CAP_WEI).
///   - WETH / CCIP-BnM pool (~1 WETH = 1000 BnM). Liquidity is minted through the v4 PositionManager as an NFT
///     owned by the DAO - NOT through the test router, whose positions anyone can remove.
///   - ENS: grants the guardian role, and publishes every contract address as a text record on nidhi-dao.eth
///     ("nidhi.contract.*") so clients discover the deployment from the name, with nothing hard-coded.
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
        uint256 positionId;
    }

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);
        string memory label = vm.parseJsonString(vm.readFile(ENS_JSON), ".label");
        address daoResolver = vm.parseJsonAddress(vm.readFile(ENS_JSON), ".resolver");
        address guardian = vm.addr(vm.envUint("GUARDIAN_PRIVATE_KEY"));
        require(SEP_WETH < SEP_BNM, "expected WETH to be currency0");

        vm.startBroadcast(pk);
        Deployed memory d = _deployCore(deployer, label);
        _createPool(d, deployer);
        IERC20Min(SEP_LINK).transfer(address(d.dispatcher), vm.envOr("DISPATCHER_LINK", uint256(5 ether)));
        _ensRecords(d, label, daoResolver, deployer, guardian);
        vm.stopBroadcast();

        _write(d, deployer, label);
    }

    function _dailyCap() internal view returns (uint256) {
        return vm.envOr("DAILY_CAP_WEI", uint256(0.001 ether));
    }

    function _deployCore(address deployer, string memory label) internal returns (Deployed memory d) {
        d.authority = new ENSv2Authority(IENSv2Registry(ENS_ETH_REGISTRY), label, BASE_SEPOLIA_COIN_TYPE);
        d.router = new NidhiSwapRouter(IPoolManager(SEP_POOL_MANAGER));
        d.dispatcher = new NidhiDispatcher(SEP_CCIP_ROUTER, SEP_LINK, BASE_SELECTOR, deployer);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(SEP_POOL_MANAGER),
            IGrantAuthority(address(d.authority)),
            INidhiDispatcher(address(d.dispatcher)),
            address(d.router),
            deployer,
            _dailyCap()
        );
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(NidhiHook).creationCode, args);
        d.hook = new NidhiHook{salt: salt}(
            IPoolManager(SEP_POOL_MANAGER),
            IGrantAuthority(address(d.authority)),
            INidhiDispatcher(address(d.dispatcher)),
            address(d.router),
            deployer,
            _dailyCap()
        );
        require(address(d.hook) == predicted, "hook address mismatch");
        d.dispatcher.setHook(address(d.hook));
    }

    function _createPool(Deployed memory d, address deployer) internal {
        d.key = PoolKey(Currency.wrap(SEP_WETH), Currency.wrap(SEP_BNM), FEE, TICK_SPACING, IHooks(address(d.hook)));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(INIT_TICK);
        IPoolManager(SEP_POOL_MANAGER).initialize(d.key, sqrtPrice);
        d.hook.setPool(d.key);

        // Seed from recovered v2 liquidity (+ top up WETH if needed). Keep some BnM headroom for rounding.
        uint256 wethWanted = vm.envOr("SEED_WETH", uint256(0.002 ether));
        uint256 wethHave = IERC20Min(SEP_WETH).balanceOf(deployer);
        if (wethHave < wethWanted) IWETH9(SEP_WETH).deposit{value: wethWanted - wethHave}();
        uint256 bnmHave = IERC20Min(SEP_BNM).balanceOf(deployer);
        require(bnmHave > 0.5 ether, "need CCIP-BnM: run 08_Migrate first or drip");

        for (uint256 i; i < 2; ++i) {
            address t = i == 0 ? SEP_WETH : SEP_BNM;
            IERC20Min(t).approve(PERMIT2, type(uint256).max);
            IAllowanceTransfer(PERMIT2)
                .approve(t, SEP_POSITION_MANAGER, type(uint160).max, uint48(block.timestamp + 1 hours));
        }

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), wethWanted, bnmHave
            ) * 98 / 100;

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            d.key, lower, upper, uint256(liquidity), uint128(wethWanted), uint128(bnmHave), deployer, bytes("")
        );
        params[1] = abi.encode(d.key.currency0, d.key.currency1);
        d.positionId = IPositionManager(SEP_POSITION_MANAGER).nextTokenId();
        IPositionManager(SEP_POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    /// Guardian role + discoverable contract records on the DAO's own resolver.
    function _ensRecords(
        Deployed memory d,
        string memory label,
        address daoResolver,
        address deployer,
        address guardian
    ) internal {
        bytes memory dns = _dnsName(label);
        IPermissionedResolver r = IPermissionedResolver(daoResolver);
        r.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.role.guardian", "")), guardian);

        string[5] memory keys = [
            "nidhi.contract.hook",
            "nidhi.contract.dispatcher",
            "nidhi.contract.router",
            "nidhi.contract.authority",
            "nidhi.contract.poolId"
        ];
        string[5] memory vals = [
            vm.toString(address(d.hook)),
            vm.toString(address(d.dispatcher)),
            vm.toString(address(d.router)),
            vm.toString(address(d.authority)),
            vm.toString(PoolId.unwrap(d.key.toId()))
        ];
        for (uint256 i; i < keys.length; ++i) {
            r.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (dns, keys[i], "")), deployer);
            r.setText(dns, keys[i], vals[i]);
        }
    }

    function _write(Deployed memory d, address deployer, string memory label) internal {
        string memory o = "sepolia";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "version", "v3");
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeString(o, "ensName", string.concat(label, ".eth"));
        vm.serializeAddress(o, "authority", address(d.authority));
        vm.serializeAddress(o, "router", address(d.router));
        vm.serializeAddress(o, "dispatcher", address(d.dispatcher));
        vm.serializeAddress(o, "hook", address(d.hook));
        vm.serializeAddress(o, "poolManager", SEP_POOL_MANAGER);
        vm.serializeAddress(o, "positionManager", SEP_POSITION_MANAGER);
        vm.serializeUint(o, "positionId", d.positionId);
        vm.serializeUint(o, "dailyCapWei", _dailyCap());
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
        console2.log("LP position NFT:", d.positionId);
        console2.log("Pool id        :");
        console2.logBytes32(PoolId.unwrap(d.key.toId()));
    }
}
