// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CCIPLocalSimulator} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/BurnMintERC677Helper.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {ENSv2Authority, IENSv2Registry} from "../../src/ENSv2Authority.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {IVerifiableFactory, IPermissionedResolver, IETHRegistrar, IMockUSDC} from "../../script/ens/IENSv2.sol";

interface IUserRegistryLike {
    function setSubregistry(uint256 anyId, address registry) external;
    function register(
        string calldata label,
        address owner,
        address registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) external returns (uint256);
}

interface IAddrSetter {
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addr) external;
}

/// @notice Runs against a Sepolia fork: the REAL ENSv2 contracts and the REAL Uniswap v4 PoolManager.
///         CCIP is simulated locally (the live lane is exercised by the deploy scripts).
///         Skipped unless SEPOLIA_RPC_URL is set.  forge test --match-contract LiveSepolia -vv
contract LiveSepoliaTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant ENS_RESOLVER_IMPL = 0x115eb53F0c60696633855F90b138178Fb40b2b2C;
    address constant ENS_FACTORY = 0xDa70306C98E97eCe36F997a21368e53298572991;
    address constant ENS_REGISTRAR = 0xf633e7FC17e2bbE0D0965D18ec1821dcB754a3d3;
    address constant ENS_REGISTRY = 0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4;
    address constant ENS_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa;
    uint256 constant ROLE_SET_TEXT = 1 << 4;
    address constant USER_REGISTRY_IMPL = 0x9BD8a88719068D09ecee662f36C0E3856708366a;
    uint256 constant COIN_BASE_SEPOLIA = 0x80000000 | 84532;

    bool internal forked;
    string internal label;
    address internal dao = makeAddr("dao-admin");
    uint256 internal approverPk = 0xA11CE;
    uint256 internal auditorPk = 0xB0B;
    address internal resolver;
    ENSv2Authority internal authority;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        label = string.concat("nidhi-fork-", vm.toString(block.number));
        _registerDaoName();
        _registerGrantee("alice", grantee);
        authority = new ENSv2Authority(IENSv2Registry(ENS_REGISTRY), label, COIN_BASE_SEPOLIA);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    // ---------------------------------------------------------------- ENSv2 (live contracts)

    function test_live_ensRolesResolveThroughRegistry() public onlyFork {
        assertEq(authority.currentResolver(), resolver, "name -> resolver via live ETHRegistry");
        assertTrue(authority.isAuthorized(authority.APPROVER(), vm.addr(approverPk)));
        assertTrue(authority.isAuthorized(authority.AUDITOR(), vm.addr(auditorPk)));
        assertFalse(authority.isAuthorized(authority.APPROVER(), vm.addr(auditorPk)), "roles are key-scoped");
        assertFalse(authority.isAuthorized(authority.APPROVER(), dao), "admin bit alone cannot approve");
    }

    function test_live_granteeSubnameResolvesOnChain() public onlyFork {
        assertEq(authority.resolveGrantee("alice"), grantee, "alice.<dao>.eth -> Base addr via live ENSv2");
        assertEq(authority.resolveGrantee("bob"), address(0), "unregistered subname resolves to nothing");
    }

    function test_live_ensRevocationIsImmediate() public onlyFork {
        vm.prank(dao);
        IPermissionedResolver(resolver)
            .revokeRoles(uint256(keccak256("nidhi.role.approver")), ROLE_SET_TEXT, vm.addr(approverPk));
        assertFalse(authority.isAuthorized(authority.APPROVER(), vm.addr(approverPk)));
    }

    function test_live_nameExpiryFailsClosed() public onlyFork {
        vm.warp(block.timestamp + 366 days + 90 days); // past expiry + grace
        assertEq(authority.currentResolver(), address(0));
        assertFalse(authority.isAuthorized(authority.APPROVER(), vm.addr(approverPk)));
    }

    // ---------------------------------------------------------------- Uniswap v4 (live PoolManager) + full flow

    // state for the full-flow test (kept in storage to stay under the stack limit)
    IPoolManager internal manager = IPoolManager(POOL_MANAGER);
    BurnMintERC677Helper internal bnm;
    MockERC20 internal weth;
    uint64 internal sel;
    NidhiSwapRouter internal nidhiRouter;
    NidhiDispatcher internal dispatcher;
    DestinationReceiver internal receiver;
    NidhiHook internal hook;
    PoolKey internal key;
    bool internal zeroForOne;
    address internal executor = makeAddr("executor");
    address internal grantee = makeAddr("grantee");

    function test_live_fullGrantOnRealPoolManager() public onlyFork {
        _deploySystem();
        _seedPool();
        Mandate memory m = _liveMandate();
        bytes memory hookData = _liveHookData(m);

        vm.prank(executor);
        nidhiRouter.swap(key, _liveParams(m.amountIn), hookData, block.timestamp);

        assertGt(bnm.balanceOf(grantee), 0.009 ether, "grantee paid");
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        assertEq(bnm.balanceOf(address(hook)) + bnm.balanceOf(address(dispatcher)), 0);
    }

    function _deploySystem() internal {
        CCIPLocalSimulator sim = new CCIPLocalSimulator();
        IRouterClient router;
        (sel, router,,,, bnm,) = sim.configuration();
        weth = new MockERC20("WETH", "WETH", 18);

        nidhiRouter = new NidhiSwapRouter(manager);
        dispatcher = new NidhiDispatcher(address(router), address(0), sel, dao);
        receiver = new DestinationReceiver(address(router), sel, address(bnm), address(0), dao);

        // Mine a real hook address exactly as the deploy script does.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager, authority, dispatcher, address(nidhiRouter), dao, uint256(1 ether));
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(NidhiHook).creationCode, args);
        hook = new NidhiHook{salt: salt}(manager, authority, dispatcher, address(nidhiRouter), dao, 1 ether);
        assertEq(address(hook), hookAddr, "mined address");

        vm.startPrank(dao);
        dispatcher.setHook(address(hook));
        dispatcher.setDestReceiver(address(receiver));
        receiver.setSourceDispatcher(address(dispatcher));
        vm.stopPrank();
    }

    function _seedPool() internal {
        (Currency c0, Currency c1) = address(weth) < address(bnm)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(bnm)))
            : (Currency.wrap(address(bnm)), Currency.wrap(address(weth)));
        zeroForOne = Currency.unwrap(c0) == address(weth);
        key = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.prank(dao);
        hook.setPool(key);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        for (uint256 i; i < 5; ++i) {
            bnm.drip(address(this));
        }
        weth.mint(address(this), 5 ether);
        bnm.approve(address(lp), type(uint256).max);
        weth.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");

        weth.mint(executor, 1 ether);
        vm.prank(executor);
        weth.approve(address(nidhiRouter), type(uint256).max);
    }

    function _liveMandate() internal view returns (Mandate memory) {
        return Mandate({
            grantId: keccak256("live-grant-1"),
            executor: executor,
            recipient: grantee,
            tokenIn: address(weth),
            tokenOut: address(bnm),
            amountIn: 0.01 ether,
            minOut: 0.009 ether,
            maxOut: 0.01 ether,
            destChainSelector: sel,
            destReceiver: address(receiver),
            evidenceHash: keccak256("evidence"),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: PoolId.unwrap(key.toId()),
            recipientLabelHash: keccak256("alice")
        });
    }

    function _liveHookData(Mandate memory m) internal view returns (bytes memory) {
        Attestation memory a = Attestation(m.grantId, m.evidenceHash, keccak256("in"), keccak256("rubric"), 0);
        return abi.encode(
            NidhiHook.GrantAuth({
                mandate: m,
                approver: vm.addr(approverPk),
                approverSig: _sign(approverPk, hook.mandateDigest(m)),
                attestation: a,
                auditor: vm.addr(auditorPk),
                auditorSig: _sign(auditorPk, hook.attestationDigest(a)),
                recipientLabel: "alice"
            })
        );
    }

    function _liveParams(uint128 amountIn) internal view returns (SwapParams memory) {
        return SwapParams(
            zeroForOne,
            -int256(uint256(amountIn)),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    // ---------------------------------------------------------------- helpers

    function _registerDaoName() internal {
        IETHRegistrar registrar = IETHRegistrar(ENS_REGISTRAR);
        require(registrar.isAvailable(label), "label taken");
        bytes memory dns = abi.encodePacked(uint8(bytes(label).length), label, uint8(3), "eth", uint8(0));

        IPermissionedResolver.Grant[] memory grants = new IPermissionedResolver.Grant[](1);
        grants[0] = IPermissionedResolver.Grant({account: dao, roleBitmap: ROLE_SET_TEXT << 128});

        vm.startPrank(dao);
        resolver = IVerifiableFactory(ENS_FACTORY)
            .deployProxy(
                ENS_RESOLVER_IMPL,
                uint256(keccak256(bytes(label))),
                abi.encodeCall(IPermissionedResolver.initialize, (grants, new bytes[](0)))
            );
        IPermissionedResolver(resolver)
            .grantSetterRoles(
                abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.role.approver", "")), vm.addr(approverPk)
            );
        IPermissionedResolver(resolver)
            .grantSetterRoles(
                abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.role.auditor", "")), vm.addr(auditorPk)
            );

        bytes32 secret = keccak256("secret");
        registrar.commit(registrar.makeCommitment(label, dao, secret, address(0), resolver, 365 days, bytes32(0)));
        vm.warp(block.timestamp + 61);
        (uint256 base, uint256 premium) = registrar.getRegisterPrice(label, 365 days, ENS_USDC);
        IMockUSDC(ENS_USDC).mint(dao, base + premium);
        IMockUSDC(ENS_USDC).approve(ENS_REGISTRAR, base + premium);
        registrar.register(label, dao, secret, address(0), resolver, 365 days, ENS_USDC, bytes32(0));
        vm.stopPrank();
    }

    /// Real ENSv2 subname: UserRegistry subregistry for the DAO name + grants resolver with a Base addr record.
    function _registerGrantee(string memory grLabel, address wallet) internal {
        IPermissionedResolver.Grant[] memory rg = new IPermissionedResolver.Grant[](1);
        rg[0] = IPermissionedResolver.Grant(dao, (1 << 0) | ((1 << 0) << 128) | (1 << 24) | ((1 << 24) << 128));
        IPermissionedResolver.Grant[] memory g = new IPermissionedResolver.Grant[](1);
        g[0] = IPermissionedResolver.Grant(dao, (1 << 0) | ((1 << 0) << 128));

        vm.startPrank(dao);
        address sub = IVerifiableFactory(ENS_FACTORY)
            .deployProxy(
                USER_REGISTRY_IMPL,
                uint256(keccak256(abi.encode(label, "sub"))),
                abi.encodeWithSignature("initialize((address,uint256)[])", rg)
            );
        IUserRegistryLike(ENS_REGISTRY).setSubregistry(uint256(keccak256(bytes(label))), sub);
        address gres = IVerifiableFactory(ENS_FACTORY)
            .deployProxy(
                ENS_RESOLVER_IMPL,
                uint256(keccak256(abi.encode(label, "gres"))),
                abi.encodeCall(IPermissionedResolver.initialize, (g, new bytes[](0)))
            );
        IUserRegistryLike(sub).register(grLabel, dao, address(0), gres, 0, uint64(block.timestamp + 180 days));
        bytes memory dns = abi.encodePacked(
            uint8(bytes(grLabel).length), grLabel, uint8(bytes(label).length), label, uint8(3), "eth", uint8(0)
        );
        IAddrSetter(gres).setAddress(dns, COIN_BASE_SEPOLIA, abi.encodePacked(wallet));
        vm.stopPrank();
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
