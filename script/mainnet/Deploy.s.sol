// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {NidhiHook, IStateViewLike} from "../../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {RoleAuthority} from "../../src/RoleAuthority.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";
import {INidhiDispatcher} from "../../src/interfaces/INidhiDispatcher.sol";

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC721Min {
    function ownerOf(uint256) external view returns (address);
}

interface ICcipFee {
    struct Msg {
        bytes receiver;
        bytes data;
        TokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    function getFee(uint64 dest, Msg calldata m) external view returns (uint256);
}

/// @notice PHASE 1 of the mainnet rollout (run once per chain):
///   forge script script/mainnet/Deploy.s.sol --rpc-url <chain rpc> --broadcast --slow
///
/// Everything is driven by chains/registry.json (generated from Uniswap's and Chainlink's official data):
///   RoleAuthority (admin handed to MAINNET_ADMIN, deployer renounces) -> router -> dispatcher (native CCIP fees) ->
///   receiver -> mined hook with the reference-price guard -> pool initialised at the canonical USDC pool's price ->
///   single-sided USDC liquidity through the PositionManager (an NFT, not a drainable test router).
/// It refuses to run on a chain that is not source-capable, or whose CCIP RMN is cursed, or with an unfunded wallet.
/// Cross-chain routes (PHASE 2: Wire) and ownership transfer (PHASE 3: Handover) happen after every chain is deployed.
contract Deploy is Script {
    using PoolIdLibrary for PoolKey;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint16 constant GUARD_BPS = 300; // 3%: covers the 0.30% pool fee plus impact on a seeded pool
    uint256 constant FEE_MESSAGES = 3; // CCIP messages of native fee reserve per side

    struct Ctx {
        uint256 id;
        address poolManager;
        address positionManager;
        address quoter;
        address stateView;
        address payout;
        address base;
        address ccipRouter;
        bytes32 refPoolId;
        bool refBaseIsCurrency0;
        bool hasRef; // false on testnets: no deep reference pool, guard disabled
        uint8 payoutDecimals;
        int24 initTick; // testnet pool opening tick when the base token is currency0
        uint64 firstLaneSelector;
        string json;
    }

    struct Out {
        address authority;
        address router;
        address dispatcher;
        address receiver;
        address hook;
        bytes32 poolId;
        uint256 positionId;
        uint256 dailyCapBase;
    }

    function run() external {
        string memory json = vm.readFile(vm.envOr("REGISTRY", string("chains/registry.json")));
        Ctx memory c = _ctx(json);
        require(vm.parseJsonBool(json, _p(c, ".capabilities.source")), "chain is not source-capable (see registry excludedBecause)");
        require(!IRmnLike(ICcipArm(c.ccipRouter).getArmProxy()).isCursed(), "CCIP RMN is cursed on this chain right now: refusing to deploy a sender");
        require(CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer missing on this chain");

        uint256 pk = vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envAddress("MAINNET_ADMIN");
        require(admin != address(0) && admin != deployer, "set MAINNET_ADMIN to the DAO admin (wallet or Safe), not the deployer");
        uint256 seedUsdc = vm.envOr(c.hasRef ? "SEED_USD" : "SEED_TOKENS", c.hasRef ? uint256(20) : uint256(3)) * 10 ** c.payoutDecimals;
        require(IERC20Min(c.payout).balanceOf(deployer) >= seedUsdc, "deployer lacks the payout-token seed on this chain");

        (uint256 reserve, uint256 capBase) = _economics(c);
        require(deployer.balance > reserve * 2, "deployer native balance too low for fee reserves + gas (run offchain preflight)");

        Out memory o;
        vm.startBroadcast(pk);
        // ENS_AUTHORITY: use an existing authority (ENSv2Authority on Sepolia) instead of a new RoleAuthority
        address ens = vm.envOr("ENS_AUTHORITY", address(0));
        o.authority = ens != address(0) ? ens : address(_authority(deployer, admin));
        o.router = address(new NidhiSwapRouter(IPoolManager(c.poolManager)));
        NidhiDispatcher dispatcher = new NidhiDispatcher(c.ccipRouter, address(0), deployer);
        o.dispatcher = address(dispatcher);
        // EXISTING_RECEIVER: a second source stack on a chain reuses that chain's receiver (routes are add-only)
        o.receiver = vm.envOr("EXISTING_RECEIVER", address(0));
        bool newReceiver = o.receiver == address(0);
        if (newReceiver) {
            DestinationReceiver receiver = new DestinationReceiver(c.ccipRouter, address(0), deployer);
            o.receiver = address(receiver);
            receiver.allowToken(c.payout);
        }
        o.dailyCapBase = capBase;
        o.hook = address(_deployHook(c, o, deployer));
        dispatcher.setHook(o.hook);
        (o.poolId, o.positionId) = _pool(c, NidhiHook(o.hook), deployer, seedUsdc);
        payable(o.dispatcher).transfer(reserve);
        if (newReceiver) payable(o.receiver).transfer(reserve);
        vm.stopBroadcast();

        _write(c, o, deployer, admin);
    }

    // ------------------------------------------------------------------ registry access

    function _p(Ctx memory c, string memory path) internal pure returns (string memory) {
        return string.concat(".chains.", vm.toString(c.id), path);
    }

    function _ctx(string memory json) internal view returns (Ctx memory c) {
        c.id = block.chainid;
        c.json = json;
        c.poolManager = vm.parseJsonAddress(json, _p(c, ".uniswap.poolManager"));
        c.positionManager = vm.parseJsonAddress(json, _p(c, ".uniswap.positionManager"));
        c.quoter = vm.parseJsonAddress(json, _p(c, ".uniswap.quoter"));
        if (vm.keyExistsJson(json, _p(c, ".uniswap.stateView"))) c.stateView = vm.parseJsonAddress(json, _p(c, ".uniswap.stateView"));
        c.payout = vm.parseJsonAddress(json, _p(c, ".payoutToken.address"));
        c.base = vm.parseJsonAddress(json, _p(c, ".wrappedNative.address"));
        c.ccipRouter = vm.parseJsonAddress(json, _p(c, ".ccip.router"));
        c.payoutDecimals = uint8(vm.parseJsonUint(json, _p(c, ".payoutToken.decimals")));
        c.hasRef = vm.keyExistsJson(json, _p(c, ".referencePool.poolId"));
        if (c.hasRef) {
            c.refPoolId = vm.parseJsonBytes32(json, _p(c, ".referencePool.poolId"));
            string memory side = vm.parseJsonString(json, _p(c, ".referencePool.base"));
            c.refBaseIsCurrency0 = keccak256(bytes(side)) == keccak256("native") ? true : c.base < c.payout;
        } else {
            c.initTick = int24(vm.parseJsonInt(json, _p(c, ".testPool.initTickBaseIsCurrency0")));
        }
        uint256[] memory lanes = vm.parseJsonUintArray(json, _p(c, ".payoutLanes"));
        // FEE_LANE_CHAIN: size the fee reserve on the lane this stack actually uses (a hop stack sends to one chain)
        uint256 feeLane = vm.envOr("FEE_LANE_CHAIN", uint256(0));
        if (feeLane != 0) {
            lanes = new uint256[](1);
            lanes[0] = feeLane;
        }
        for (uint256 i; i < lanes.length && c.firstLaneSelector == 0; ++i) {
            string memory k = string.concat(".chains.", vm.toString(lanes[i]));
            if (!vm.parseJsonBool(json, string.concat(k, ".ccip.cursedAtGeneration"))) {
                c.firstLaneSelector = uint64(vm.parseUint(vm.parseJsonString(json, string.concat(k, ".ccip.selector"))));
            }
        }
        require(c.firstLaneSelector != 0, "every payout destination is RMN-cursed right now");
    }

    // ------------------------------------------------------------------ sizing from live data

    /// Native fee reserve (FEE_MESSAGES x the real CCIP fee for a USDC grant) and the daily cap in base-token wei,
    /// derived from the canonical pool's price: DAILY_CAP_USD (default $100) / price.
    function _economics(Ctx memory c) internal view returns (uint256 reserve, uint256 capBase) {
        ICcipFee.TokenAmount[] memory t = new ICcipFee.TokenAmount[](1);
        t[0] = ICcipFee.TokenAmount(c.payout, 10 ** c.payoutDecimals);
        ICcipFee.Msg memory m = ICcipFee.Msg({
            receiver: abi.encode(address(0xBEEF)),
            data: "",
            tokenAmounts: t,
            feeToken: address(0),
            extraArgs: abi.encodePacked(bytes4(0x181dcf10), abi.encode(uint256(600_000), true))
        });
        reserve = ICcipFee(c.ccipRouter).getFee(c.firstLaneSelector, m) * FEE_MESSAGES;

        if (!c.hasRef) return (reserve, vm.envOr("DAILY_CAP_WEI", uint256(0.001 ether))); // testnet: fixed cap in base wei
        (uint160 refSqrt,,,) = IStateViewLike(c.stateView).getSlot0(c.refPoolId);
        uint256 p96 = FullMath.mulDiv(refSqrt, refSqrt, 1 << 96);
        uint256 usdcPerBase = c.refBaseIsCurrency0 ? FullMath.mulDiv(p96, 1e18, 1 << 96) : FullMath.mulDiv(1e18, 1 << 96, p96); // 1e18-scaled
        uint256 capUsdRaw = vm.envOr("DAILY_CAP_USD", uint256(100)) * 1e6;
        capBase = FullMath.mulDiv(capUsdRaw, 1e18, usdcPerBase);
        require(capBase > 0, "cap rounded to zero");
    }

    // ------------------------------------------------------------------ pieces

    function _authority(address deployer, address admin) internal returns (RoleAuthority r) {
        r = new RoleAuthority(deployer); // deployer is admin only while wiring roles
        r.grantRole(r.APPROVER(), vm.addr(vm.envUint("MAINNET_APPROVER_PRIVATE_KEY")));
        r.grantRole(r.AUDITOR(), vm.addr(vm.envUint("MAINNET_AUDITOR_PRIVATE_KEY")));
        r.grantRole(r.GUARDIAN(), vm.addr(vm.envUint("MAINNET_GUARDIAN_PRIVATE_KEY")));
        r.grantRole(r.DEFAULT_ADMIN_ROLE(), admin);
        r.grantRole(r.GRANTEE_ADMIN(), admin);
        // optional: name one grantee before the deployer gives up GRANTEE_ADMIN (demo stacks)
        string memory seedLabel = vm.envOr("SEED_GRANTEE_LABEL", string(""));
        if (bytes(seedLabel).length != 0) {
            r.setGrantee(seedLabel, uint64(vm.envUint("SEED_GRANTEE_SELECTOR")), vm.envAddress("SEED_GRANTEE_ADDRESS"));
        }
        r.renounceRole(r.GRANTEE_ADMIN(), deployer);
        r.renounceRole(r.DEFAULT_ADMIN_ROLE(), deployer); // the deployer keeps NO power over permissions
    }

    function _hookArgs(Ctx memory c, Out memory o, address deployer) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(c.poolManager),
            IGrantAuthority(o.authority),
            INidhiDispatcher(o.dispatcher),
            o.router,
            deployer, // owner: only ever used for the one-time setPool
            o.dailyCapBase,
            c.quoter,
            NidhiHook.ReferenceGuard({
                stateView: c.hasRef ? c.stateView : address(0),
                poolId: c.refPoolId,
                baseToken: c.hasRef ? c.base : address(0),
                payoutToken: c.hasRef ? c.payout : address(0),
                baseIsCurrency0: c.refBaseIsCurrency0,
                maxDeviationBps: c.hasRef ? GUARD_BPS : 0
            })
        );
    }

    function _deployHook(Ctx memory c, Out memory o, address deployer) internal returns (NidhiHook) {
        bytes memory args = _hookArgs(c, o, deployer);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        // The PoolManager differs per chain, so the 0xC4 address bits are mined per chain.
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(NidhiHook).creationCode, args);
        // Deploy through the canonical CREATE2 deployer: call it with salt ++ initcode (raw, to keep the stack small).
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(NidhiHook).creationCode, args));
        require(ok && predicted.code.length > 0, "hook CREATE2 deployment failed");
        return NidhiHook(predicted);
    }

    function _sqrtPrice(Ctx memory c) internal view returns (uint160 sqrtP) {
        bool baseIs0 = c.base < c.payout;
        if (!c.hasRef) return TickMath.getSqrtPriceAtTick(baseIs0 ? c.initTick : -c.initTick);
        (uint160 refSqrt,,,) = IStateViewLike(c.stateView).getSlot0(c.refPoolId);
        sqrtP = (baseIs0 == c.refBaseIsCurrency0) ? refSqrt : uint160(FullMath.mulDiv(1 << 96, 1 << 96, refSqrt));
    }

    /// Pool at the canonical price, seeded with USDC ONLY: a position wholly on the USDC side of the current price, so
    /// base -> USDC grant swaps pull USDC out of it. No base-token inventory is needed to open the pool.
    function _pool(Ctx memory c, NidhiHook hook, address deployer, uint256 seedUsdc)
        internal
        returns (bytes32 poolId, uint256 positionId)
    {
        bool baseIs0 = c.base < c.payout;
        (address t0, address t1) = baseIs0 ? (c.base, c.payout) : (c.payout, c.base);
        PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), FEE, SPACING, IHooks(address(hook)));
        uint160 sqrtP = _sqrtPrice(c);
        IPoolManager(c.poolManager).initialize(key, sqrtP);
        hook.setPool(key);
        poolId = PoolId.unwrap(key.toId());
        positionId = _mintUsdcOnly(c, key, sqrtP, deployer, seedUsdc);
    }

    function _range(bool baseIs0, uint160 sqrtP) internal pure returns (int24 lower, int24 upper) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        if (baseIs0) {
            upper = _floor(tick) - SPACING; // USDC is token1: held below the current price
            lower = upper - 2400; // ~21% of depth below the price
        } else {
            lower = _floor(tick) + 2 * SPACING; // USDC is token0: held above the current price
            upper = lower + 2400;
        }
    }

    function _liquidity(bool baseIs0, uint160 sqrtP, uint256 seedUsdc)
        internal
        pure
        returns (int24 lower, int24 upper, uint128 liq)
    {
        (lower, upper) = _range(baseIs0, sqrtP);
        uint160 sa = TickMath.getSqrtPriceAtTick(lower);
        uint160 sb = TickMath.getSqrtPriceAtTick(upper);
        liq = baseIs0
            ? LiquidityAmounts.getLiquidityForAmount1(sa, sb, seedUsdc)
            : LiquidityAmounts.getLiquidityForAmount0(sa, sb, seedUsdc);
    }

    function _mintUsdcOnly(Ctx memory c, PoolKey memory key, uint160 sqrtP, address deployer, uint256 seedUsdc)
        internal
        returns (uint256 positionId)
    {
        IERC20Min(c.payout).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(c.payout, c.positionManager, type(uint160).max, uint48(block.timestamp + 1 hours));
        positionId = IPositionManager(c.positionManager).nextTokenId();
        IPositionManager(c.positionManager).modifyLiquidities(_mintCall(c, key, sqrtP, deployer, seedUsdc), block.timestamp + 300);
        // On a busy PositionManager someone can mint between our read and our mint, so confirm which id is ours.
        for (uint256 i; i < 8; ++i) {
            if (IERC721Min(c.positionManager).ownerOf(positionId + i) == deployer) return positionId + i;
        }
        revert("LP position not found for the deployer");
    }

    function _mintCall(Ctx memory c, PoolKey memory key, uint160 sqrtP, address deployer, uint256 seedUsdc)
        internal
        pure
        returns (bytes memory)
    {
        (int24 lower, int24 upper, uint128 liq) = _liquidity(c.base < c.payout, sqrtP, seedUsdc);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, uint256(liq), type(uint128).max, type(uint128).max, deployer, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        return abi.encode(actions, params);
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 c = tick / SPACING;
        if (tick < 0 && tick % SPACING != 0) c--;
        return c * SPACING;
    }

    function _write(Ctx memory c, Out memory o, address deployer, address admin) internal {
        string memory k = "deploy";
        vm.serializeUint(k, "chainId", c.id);
        vm.serializeUint(k, "deployBlock", block.number);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "admin", admin);
        vm.serializeAddress(k, "authority", o.authority);
        vm.serializeAddress(k, "router", o.router);
        vm.serializeAddress(k, "dispatcher", o.dispatcher);
        vm.serializeAddress(k, "receiver", o.receiver);
        vm.serializeAddress(k, "hook", o.hook);
        vm.serializeUint(k, "positionId", o.positionId);
        vm.serializeUint(k, "dailyCapBaseWei", o.dailyCapBase);
        string memory json = vm.serializeBytes32(k, "poolId", o.poolId);
        vm.writeJson(json, vm.envOr("DEPLOY_OUT", string.concat("deployments/", vm.toString(c.id), ".json")));
        console2.log("chain", c.id);
        console2.log("  hook      ", o.hook);
        console2.log("  dispatcher", o.dispatcher);
        console2.log("  receiver  ", o.receiver);
        console2.log("  authority ", o.authority);
        console2.log("  LP NFT    ", o.positionId);
    }
}

interface ICcipArm {
    function getArmProxy() external view returns (address);
}

interface IRmnLike {
    function isCursed() external view returns (bool);
}
