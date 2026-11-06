// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {CCIPLocalSimulator} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {LinkToken} from "@chainlink/local/src/shared/LinkToken.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/BurnMintERC677Helper.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {NidhiHook} from "../../src/NidhiHook.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {ENSv2Authority} from "../../src/ENSv2Authority.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {MockEAC} from "../mocks/MockEAC.sol";
import {MockENSv2Registry, MockGranteeRegistry} from "../mocks/MockENSv2Registry.sol";
import {IENSv2Registry} from "../../src/ENSv2Authority.sol";

/// @notice Full local deployment: real v4 PoolManager + CCIP local simulator + ENSv2Authority over a mock EAC.
abstract contract NidhiBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant ROLE_SET_TEXT = 1 << 4;
    uint256 constant APPROVER_RES = uint256(keccak256("nidhi.role.approver"));
    uint256 constant AUDITOR_RES = uint256(keccak256("nidhi.role.auditor"));
    uint256 constant GUARDIAN_RES = uint256(keccak256("nidhi.role.guardian"));
    string constant DAO_LABEL = "nidhi-dao";
    string constant GRANTEE_LABEL = "alice";
    uint256 constant COIN_TYPE = 0x80000000 | 84532; // ENSIP-11, Base Sepolia
    uint256 constant DAILY_CAP = 1 ether;

    // actors
    uint256 internal approverPk = 0xA11CE;
    uint256 internal auditorPk = 0xB0B;
    address internal approver;
    address internal auditor;
    address internal executor = makeAddr("executor");
    address internal recipient = makeAddr("grantee");
    address internal daoOwner = makeAddr("daoOwner");

    // system
    CCIPLocalSimulator internal sim;
    IRouterClient internal ccipRouter;
    uint64 internal chainSelector;
    BurnMintERC677Helper internal bnm;
    MockERC20 internal weth;
    address internal link;

    MockEAC internal eac;
    MockENSv2Registry internal ensRegistry;
    MockGranteeRegistry internal grantees;
    address internal guardian = makeAddr("guardian");
    IGrantAuthority internal authority; // ENSv2Authority by default; tests may swap in RoleAuthority
    ENSv2Authority internal ensAuthority; // always the ENS-backed one (resolver/coin-type introspection)
    NidhiSwapRouter internal nidhiRouter;
    NidhiDispatcher internal dispatcher;
    DestinationReceiver internal receiver;
    NidhiHook internal hook;
    V4Quoter internal quoter;

    bool internal zeroForOne; // direction that sells WETH for BnM
    uint256 internal grantNonce;

    function setUp() public virtual {
        approver = vm.addr(approverPk);
        auditor = vm.addr(auditorPk);

        // --- v4 core
        deployFreshManagerAndRouters();

        // --- CCIP local simulator (synchronous: send -> receive -> ACK in one tx)
        sim = new CCIPLocalSimulator();
        (uint64 sel, IRouterClient src,,, LinkToken linkToken, BurnMintERC677Helper bnm_,) = sim.configuration();
        chainSelector = sel;
        ccipRouter = src;
        bnm = bnm_;
        link = address(linkToken);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // --- ENS firewall
        eac = new MockEAC(); // the DAO's PermissionedResolver
        ensRegistry = new MockENSv2Registry();
        ensRegistry.set(DAO_LABEL, address(eac), uint64(block.timestamp + 365 days));
        ensAuthority = _authority(ensRegistry, DAO_LABEL);
        authority = _deployAuthority();
        eac.grant(APPROVER_RES, ROLE_SET_TEXT, approver);
        eac.grant(AUDITOR_RES, ROLE_SET_TEXT, auditor);
        eac.grant(GUARDIAN_RES, ROLE_SET_TEXT, guardian);
        // grantee subname alice.nidhi-dao.eth -> recipient on the payout chain
        grantees = new MockGranteeRegistry(DAO_LABEL);
        ensRegistry.setSubregistry(DAO_LABEL, address(grantees));
        grantees.setGrantee(GRANTEE_LABEL, recipient);

        // --- Nidhi
        nidhiRouter = new NidhiSwapRouter(manager);
        quoter = new V4Quoter(manager);
        dispatcher = new NidhiDispatcher(address(ccipRouter), link, daoOwner);
        receiver = new DestinationReceiver(address(ccipRouter), link, daoOwner);

        address hookAddr = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                ^ (0x4444 << 144)
        );
        deployCodeTo(
            "NidhiHook.sol:NidhiHook",
            abi.encode(manager, authority, dispatcher, address(nidhiRouter), daoOwner, DAILY_CAP, address(quoter), _guard()),
            hookAddr
        );
        hook = NidhiHook(hookAddr);

        vm.startPrank(daoOwner);
        dispatcher.setHook(address(hook));
        dispatcher.addDestination(chainSelector, address(receiver));
        receiver.addSource(chainSelector, address(dispatcher));
        receiver.allowToken(address(bnm));
        vm.stopPrank();

        // --- pool: WETH / CCIP-BnM, liquidity from an LP (this contract)
        for (uint256 i; i < 20; ++i) {
            bnm.drip(address(this));
        }
        weth.mint(address(this), 100 ether);
        bnm.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);

        (Currency c0, Currency c1) = address(weth) < address(bnm)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(bnm)))
            : (Currency.wrap(address(bnm)), Currency.wrap(address(weth)));
        zeroForOne = Currency.unwrap(c0) == address(weth);
        (key,) = initPool(c0, c1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.prank(daoOwner);
        hook.setPool(key);

        // --- treasury executor holds WETH and approves the Nidhi router
        weth.mint(executor, 10 ether);
        vm.prank(executor);
        weth.approve(address(nidhiRouter), type(uint256).max);

        // CCIP fee reserves (simulator fee defaults to 0; tests raise it to exercise the fee paths)
        sim.requestLinkFromFaucet(address(dispatcher), 10 ether);
        sim.requestLinkFromFaucet(address(receiver), 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// ENSv2Authority wired for the simulator's single chain selector (Base Sepolia coin type).
    function _authority(MockENSv2Registry reg, string memory dao) internal returns (ENSv2Authority) {
        uint64[] memory sels = new uint64[](1);
        uint256[] memory coins = new uint256[](1);
        sels[0] = chainSelector;
        coins[0] = COIN_TYPE;
        return new ENSv2Authority(IENSv2Registry(address(reg)), dao, sels, coins);
    }

    /// Override to run the whole suite against a different IGrantAuthority.
    function _deployAuthority() internal virtual returns (IGrantAuthority) {
        return IGrantAuthority(address(ensAuthority));
    }

    /// Override to enable the reference-price guard.
    function _guard() internal virtual returns (NidhiHook.ReferenceGuard memory) {
        return _noGuard();
    }

    function _noGuard() internal pure returns (NidhiHook.ReferenceGuard memory g) {
        return g; // stateView == address(0): reference-price guard disabled
    }

    function _newGrantId() internal returns (bytes32) {
        return keccak256(abi.encode("grant", ++grantNonce));
    }

    function _mandate(bytes32 grantId, uint128 amountIn) internal view returns (Mandate memory m) {
        m = Mandate({
            grantId: grantId,
            executor: executor,
            recipient: recipient,
            tokenIn: address(weth),
            tokenOut: address(bnm),
            amountIn: amountIn,
            minOut: 1,
            maxOut: amountIn,
            destChainSelector: chainSelector,
            destReceiver: address(receiver),
            evidenceHash: keccak256(abi.encode("evidence", grantId)),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: PoolId.unwrap(key.toId()),
            recipientLabelHash: keccak256(bytes(GRANTEE_LABEL))
        });
    }

    function _attestation(Mandate memory m) internal view returns (Attestation memory) {
        return Attestation({
            grantId: m.grantId,
            evidenceHash: m.evidenceHash,
            inputsHash: keccak256("inputs"),
            rubricHash: keccak256("rubric"),
            issuedAt: uint64(block.timestamp)
        });
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hookData(Mandate memory m, Attestation memory a, uint256 apPk, uint256 auPk)
        internal
        view
        returns (bytes memory)
    {
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: vm.addr(apPk),
            approverSig: _sign(apPk, hook.mandateDigest(m)),
            attestation: a,
            auditor: vm.addr(auPk),
            auditorSig: _sign(auPk, hook.attestationDigest(a)),
            recipientLabel: GRANTEE_LABEL
        });
        return abi.encode(g);
    }

    function _hookData(Mandate memory m) internal view returns (bytes memory) {
        return _hookData(m, _attestation(m), approverPk, auditorPk);
    }

    function _params(uint128 amountIn) internal view returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _swap(Mandate memory m, bytes memory hookData) internal returns (BalanceDelta) {
        vm.prank(executor);
        return nidhiRouter.swap(key, _params(m.amountIn), hookData, block.timestamp);
    }

    /// v4 wraps hook reverts: WrappedError(hook, callbackSelector, reason, HookCallFailed()).
    function _expectHookRevert(bytes4 callback, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
