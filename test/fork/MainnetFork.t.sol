// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {NidhiHook, IStateViewLike} from "../../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {RoleAuthority} from "../../src/RoleAuthority.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";
import {INidhiDispatcher} from "../../src/interfaces/INidhiDispatcher.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";

interface IERC20Lite {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICcipRouterArm {
    function getArmProxy() external view returns (address);
}

interface IRmn {
    function isCursed() external view returns (bool);
}

interface IWrapped {
    function deposit() external payable;
}

/// @notice MAINNET REHEARSAL. For every chain marked source-capable in chains/registry.json, forks the real chain and runs
///         the whole Nidhi stack against the REAL Uniswap v4 PoolManager / PositionManager / V4Quoter / StateView and the
///         REAL Chainlink CCIP router and USDC token pool:
///           deploy (RoleAuthority, router, dispatcher, mined hook with the reference-price guard) -> seed a pool through the
///           PositionManager at the canonical pool's price -> sign a grant -> swap -> hook captures USDC -> dispatcher sends
///           it over CCIP (real fee, real token pool). Nothing is broadcast; it only forks.
///         Opt-in:  MAINNET_FORK=1 forge test --match-contract MainnetFork -vv      (FORK_CHAINS=8453,1 to pick chains)
contract MainnetForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant APPROVER_PK = 0xA11CE;
    uint256 constant AUDITOR_PK = 0xB0B;
    address constant PLACEHOLDER_RECEIVER = address(0xBEEF);
    uint128 constant GRANT_BASE_IN = 0.001 ether; // of the wrapped native token

    struct Ctx {
        uint256 id;
        string key; // registry path prefix
        address poolManager;
        address positionManager;
        address quoter;
        address stateView;
        address usdc;
        address base; // wrapped native
        bytes32 refPoolId;
        bool refBaseIsCurrency0;
        uint64 destSelector;
        address ccipRouter;
    }

    NidhiHook internal hook;
    NidhiSwapRouter internal router;
    NidhiDispatcher internal dispatcher;
    RoleAuthority internal roles;
    PoolKey internal poolKey;
    address internal executor = makeAddr("executor");
    address internal grantee = makeAddr("grantee");

    function _j(Ctx memory c, string memory path) internal view returns (string memory) {
        return string.concat(".chains.", vm.toString(c.id), path);
    }

    function _addr(string memory json, Ctx memory c, string memory path) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".chains.", vm.toString(c.id), path));
    }

    function test_rehearseEverySourceChain() public {
        if (!vm.envOr("MAINNET_FORK", false)) {
            vm.skip(true);
            return;
        }
        string memory json = vm.readFile("chains/registry.json");
        uint256[] memory ids = _chains(json);
        uint256 ok;
        uint256 skipped;
        string memory failures;
        for (uint256 i; i < ids.length; ++i) {
            try this.rehearse(ids[i]) {
                ++ok;
                console2.log("PASS chain", ids[i]);
            } catch (bytes memory e) {
                if (keccak256(bytes(_reason(e))) == keccak256("RMN_CURSED")) {
                    console2.log("SKIP chain (CCIP RMN cursed right now)", ids[i]);
                    ++skipped;
                    continue;
                }
                failures = string.concat(failures, vm.toString(ids[i]), ": ", _reason(e), "\n");
                console2.log("FAIL chain", ids[i]);
            }
        }
        console2.log("chains passed:", ok, "skipped (cursed):", skipped);
        assertEq(bytes(failures).length, 0, failures);
    }

    function _chains(string memory json) internal view returns (uint256[] memory ids) {
        string memory only = vm.envOr("FORK_CHAINS", string(""));
        if (bytes(only).length != 0) return vm.parseJsonUintArray(string.concat("[", only, "]"), "$");
        return vm.parseJsonUintArray(json, ".sourceChains");
    }

    function _reason(bytes memory e) internal pure returns (string memory) {
        if (e.length >= 4 && bytes4(e) == 0x08c379a0) {
            bytes memory body = new bytes(e.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = e[i + 4];
            }
            return abi.decode(body, (string));
        }
        return vm.toString(e);
    }

    /// External so a failing chain does not abort the others.
    function rehearse(uint256 chainId) external {
        string memory json = vm.readFile("chains/registry.json");
        Ctx memory c = _ctx(json, chainId);
        vm.createSelectFork(
            vm.envOr(string.concat("FORK_RPC_", vm.toString(chainId)), vm.parseJsonString(json, _j(c, ".rpc")))
        );
        require(block.chainid == chainId, "wrong chain");
        // Chainlink's Risk Management Network can curse a chain (all CCIP sends revert with BadARMSignal). That is a live
        // network condition, not a Nidhi bug: report it as SKIPPED instead of failing.
        if (IRmn(ICcipRouterArm(c.ccipRouter).getArmProxy()).isCursed()) revert("RMN_CURSED");

        _deployStack(c, 300); // 3% guard band: covers pool fee + impact
        _seedPool(c);
        bytes32 grantId = _payOneGrant(c);

        NidhiDispatcher.Grant memory g = dispatcher.getGrant(grantId);
        require(g.status == NidhiDispatcher.Status.DISPATCHED, "grant not dispatched");
        require(g.messageId != bytes32(0), "no CCIP message id");
        require(IERC20Lite(c.usdc).balanceOf(address(hook)) == 0, "hook holds USDC");
        require(IERC20Lite(c.usdc).balanceOf(address(dispatcher)) == 0, "dispatcher holds USDC");
        require(IERC20Lite(c.usdc).balanceOf(address(router)) == 0, "router holds USDC");

        _guardRejectsTightBand(c); // same pool, 1 bp band: the real reference price must reject it
    }

    // ------------------------------------------------------------------------------------------ setup

    function _ctx(string memory json, uint256 id) internal view returns (Ctx memory c) {
        c.id = id;
        c.poolManager = _addr(json, c, ".uniswap.poolManager");
        c.positionManager = _addr(json, c, ".uniswap.positionManager");
        c.quoter = _addr(json, c, ".uniswap.quoter");
        c.stateView = _addr(json, c, ".uniswap.stateView");
        c.usdc = _addr(json, c, ".tokens.usdc.address");
        c.base = _addr(json, c, ".wrappedNative.address");
        c.refPoolId = vm.parseJsonBytes32(json, _j(c, ".referencePool.poolId"));
        string memory refBase = vm.parseJsonString(json, _j(c, ".referencePool.base"));
        // native counts as address(0) (always currency0); wrapped sorts by address against USDC
        c.refBaseIsCurrency0 = keccak256(bytes(refBase)) == keccak256("native") ? true : c.base < c.usdc;
        c.destSelector = _firstLiveLane(json, c);
        c.ccipRouter = _addr(json, c, ".ccip.router");
    }

    /// First payout lane whose destination is NOT RMN-cursed at registry generation time (a cursed destination
    /// makes every send to it revert with CursedByRMN). The live curse is re-checked by the rehearsal itself.
    function _firstLiveLane(string memory json, Ctx memory c) internal view returns (uint64) {
        uint256[] memory lanes = vm.parseJsonUintArray(json, _j(c, ".payoutLanes"));
        for (uint256 i; i < lanes.length; ++i) {
            string memory k = string.concat(".chains.", vm.toString(lanes[i]));
            if (!vm.parseJsonBool(json, string.concat(k, ".ccip.cursedAtGeneration"))) {
                return uint64(vm.parseUint(vm.parseJsonString(json, string.concat(k, ".ccip.selector"))));
            }
        }
        revert("RMN_CURSED"); // every destination is cursed right now
    }

    function _deployStack(Ctx memory c, uint16 bandBps) internal {
        roles = new RoleAuthority(address(this));
        roles.grantRole(roles.APPROVER(), vm.addr(APPROVER_PK));
        roles.grantRole(roles.AUDITOR(), vm.addr(AUDITOR_PK));
        roles.grantRole(roles.GUARDIAN(), address(this));
        roles.setGrantee("alice", c.destSelector, grantee);

        router = new NidhiSwapRouter(IPoolManager(c.poolManager));
        dispatcher = new NidhiDispatcher(c.ccipRouter, address(0), address(this)); // native CCIP fees
        dispatcher.addDestination(c.destSelector, PLACEHOLDER_RECEIVER);
        vm.deal(address(dispatcher), 1_000_000 ether); // fork-only fee reserve; generous because a CCIP fee is hundreds of MON on Monad

        hook = _mineHook(c, bandBps);
        dispatcher.setHook(address(hook));
    }

    function _guardFor(Ctx memory c, uint16 bandBps) internal pure returns (NidhiHook.ReferenceGuard memory) {
        return NidhiHook.ReferenceGuard({
            stateView: c.stateView,
            poolId: c.refPoolId,
            baseToken: c.base,
            payoutToken: c.usdc,
            baseIsCurrency0: c.refBaseIsCurrency0,
            maxDeviationBps: bandBps
        });
    }

    function _hookArgs(Ctx memory c, uint16 bandBps) internal view returns (bytes memory) {
        return abi.encode(
            IPoolManager(c.poolManager),
            IGrantAuthority(address(roles)),
            INidhiDispatcher(address(dispatcher)),
            address(router),
            address(this),
            uint256(10 ether),
            c.quoter,
            _guardFor(c, bandBps)
        );
    }

    /// Mine the 0xC4 flag bits for THIS chain's PoolManager and deploy with CREATE2 (raw, to keep the stack small).
    function _mineHook(Ctx memory c, uint16 bandBps) internal returns (NidhiHook) {
        bytes memory args = _hookArgs(c, bandBps);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, type(NidhiHook).creationCode, args);
        bytes memory initCode = abi.encodePacked(type(NidhiHook).creationCode, args);
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(h == predicted && h != address(0), "hook CREATE2 failed");
        return NidhiHook(h);
    }

    /// Orient the canonical pool's price for our (wrapped, USDC) pool, initialize it, bind it, mint liquidity.
    function _seedPool(Ctx memory c) internal {
        (uint160 refSqrt,,,) = IStateViewLike(c.stateView).getSlot0(c.refPoolId);
        bool baseIs0 = c.base < c.usdc;
        // reference price orientation vs ours
        uint160 sqrtP =
            (baseIs0 == c.refBaseIsCurrency0) ? refSqrt : uint160(FullMath.mulDiv(1 << 96, 1 << 96, refSqrt));
        (address t0, address t1) = baseIs0 ? (c.base, c.usdc) : (c.usdc, c.base);
        poolKey = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(address(hook)));
        IPoolManager(c.poolManager).initialize(poolKey, sqrtP);
        hook.setPool(poolKey);

        // fund the DAO wallet (this contract) with wrapped native + USDC on the fork
        vm.deal(address(this), 2_000 ether);
        IWrapped(c.base).deposit{value: 500 ether}();
        deal(c.usdc, address(this), 5_000_000e6);
        for (uint256 i; i < 2; ++i) {
            address t = i == 0 ? c.base : c.usdc;
            IERC20Lite(t).approve(PERMIT2, type(uint256).max);
            IAllowanceTransfer(PERMIT2)
                .approve(t, c.positionManager, type(uint160).max, uint48(block.timestamp + 1 hours));
        }
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            baseIs0 ? 200 ether : 1_000_000e6,
            baseIs0 ? 1_000_000e6 : 200 ether
        );
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey, lower, upper, uint256(liq), type(uint128).max, type(uint128).max, address(this), bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        IPositionManager(c.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    // ------------------------------------------------------------------------------------------ grant

    function _quote(Ctx memory c, uint128 amountIn) internal returns (uint256 out) {
        (out,) = IV4Quoter(c.quoter)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: poolKey, zeroForOne: c.base < c.usdc, exactAmount: amountIn, hookData: ""
                })
            );
    }

    function _mandate(Ctx memory c, bytes32 grantId, uint256 out) internal view returns (Mandate memory) {
        return Mandate({
            grantId: grantId,
            executor: executor,
            recipient: grantee,
            tokenIn: c.base,
            tokenOut: c.usdc,
            amountIn: GRANT_BASE_IN,
            minOut: uint128(out * 99 / 100),
            maxOut: uint128(out * 101 / 100),
            destChainSelector: c.destSelector,
            destReceiver: PLACEHOLDER_RECEIVER,
            evidenceHash: keccak256("evidence"),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: PoolId.unwrap(poolKey.toId()),
            recipientLabelHash: keccak256("alice")
        });
    }

    function _hookData(Mandate memory m) internal view returns (bytes memory) {
        Attestation memory a =
            Attestation(m.grantId, m.evidenceHash, keccak256("in"), keccak256("rubric"), uint64(block.timestamp));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(APPROVER_PK, hook.mandateDigest(m));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(AUDITOR_PK, hook.attestationDigest(a));
        return abi.encode(
            NidhiHook.GrantAuth({
                mandate: m,
                approver: vm.addr(APPROVER_PK),
                approverSig: abi.encodePacked(r1, s1, v1),
                attestation: a,
                auditor: vm.addr(AUDITOR_PK),
                auditorSig: abi.encodePacked(r2, s2, v2),
                recipientLabel: "alice"
            })
        );
    }

    function _payOneGrant(Ctx memory c) internal returns (bytes32 grantId) {
        grantId = keccak256(abi.encode("rehearsal", c.id));
        uint256 out = _quote(c, GRANT_BASE_IN);
        require(out > 0, "official V4Quoter returned zero");
        Mandate memory m = _mandate(c, grantId, out);
        bytes memory hd = _hookData(m);

        vm.deal(executor, 10 ether);
        vm.startPrank(executor);
        IWrapped(c.base).deposit{value: 1 ether}();
        IERC20Lite(c.base).approve(address(router), type(uint256).max);
        router.swap(
            poolKey,
            SwapParams(
                c.base < c.usdc,
                -int256(uint256(GRANT_BASE_IN)),
                c.base < c.usdc ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hd,
            block.timestamp + 300
        );
        vm.stopPrank();
    }

    function _oriented(Ctx memory c) internal view returns (uint160 sqrtP) {
        (uint160 refSqrt,,,) = IStateViewLike(c.stateView).getSlot0(c.refPoolId);
        bool baseIs0 = c.base < c.usdc;
        sqrtP = (baseIs0 == c.refBaseIsCurrency0) ? refSqrt : uint160(FullMath.mulDiv(1 << 96, 1 << 96, refSqrt));
    }

    function _mint(Ctx memory c, PoolKey memory k, uint160 sqrtP) internal {
        bool baseIs0 = c.base < c.usdc;
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            baseIs0 ? 50 ether : 100_000e6,
            baseIs0 ? 100_000e6 : 50 ether
        );
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(k, lower, upper, uint256(liq), type(uint128).max, type(uint128).max, address(this), bytes(""));
        params[1] = abi.encode(k.currency0, k.currency1);
        IPositionManager(c.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    /// A second hook with a 1 bp band must reject the real reference price (the pool fee alone is 30 bps).
    function _guardRejectsTightBand(Ctx memory c) internal {
        NidhiHook tight = _mineHook(c, 1);
        PoolKey memory k2 = PoolKey(poolKey.currency0, poolKey.currency1, 3000, 60, IHooks(address(tight)));
        uint160 sqrtP = _oriented(c);
        IPoolManager(c.poolManager).initialize(k2, sqrtP);
        tight.setPool(k2);
        _mint(c, k2, sqrtP);

        NidhiHook saved = hook;
        PoolKey memory savedKey = poolKey;
        hook = tight;
        poolKey = k2;
        bytes4 reason = _attemptGrant(c);
        hook = saved;
        poolKey = savedKey;
        require(reason == NidhiHook.PriceDeviation.selector, "tight guard did not reject with PriceDeviation");
    }

    /// Try a grant through the current `hook`/`poolKey`; returns the hook's own error selector (0 if it succeeded).
    function _attemptGrant(Ctx memory c) internal returns (bytes4) {
        Mandate memory m = _mandate(c, keccak256(abi.encode("tight", c.id)), _quote(c, GRANT_BASE_IN));
        bytes memory hd = _hookData(m);
        bool baseIs0 = c.base < c.usdc;
        vm.prank(executor);
        try router.swap(
            poolKey,
            SwapParams(
                baseIs0,
                -int256(uint256(GRANT_BASE_IN)),
                baseIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hd,
            block.timestamp + 300
        ) {
            return bytes4(0);
        } catch (bytes memory err) {
            return _hookReason(err);
        }
    }

    function _hookReason(bytes memory err) internal pure returns (bytes4) {
        if (err.length < 4) return bytes4(0);
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }
}
