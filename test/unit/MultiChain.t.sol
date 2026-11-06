// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {RoleAuthority} from "../../src/RoleAuthority.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

// ============================================================================ RoleAuthority (mainnet permissions)

/// The ENTIRE hook flow, run against RoleAuthority instead of ENSv2: this is the mainnet configuration.
contract RoleAuthorityFlowTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;
    RoleAuthority internal roles;

    function _deployAuthority() internal override returns (IGrantAuthority) {
        roles = new RoleAuthority(daoOwner);
        vm.startPrank(daoOwner);
        roles.grantRole(roles.APPROVER(), approver);
        roles.grantRole(roles.AUDITOR(), auditor);
        roles.grantRole(roles.GUARDIAN(), guardian);
        roles.setGrantee(GRANTEE_LABEL, chainSelector, recipient);
        vm.stopPrank();
        return IGrantAuthority(address(roles));
    }

    function test_fullGrantWorksOnRoleAuthority() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        assertGt(bnm.balanceOf(recipient), 0);
    }

    function test_revokedApproverBlocksNextPayout() public {
        bytes32 role = roles.APPROVER();
        vm.prank(daoOwner);
        roles.revokeRole(role, approver);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, role, approver));
        _swap(m, hd);
    }

    function test_guardianPausesViaRoleRegistry() public {
        vm.prank(guardian);
        hook.setPaused(true);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.Paused.selector));
        _swap(m, hd);
    }

    function test_clearingGranteeBlocksPayout() public {
        vm.prank(daoOwner);
        roles.setGrantee(GRANTEE_LABEL, chainSelector, address(0));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.RecipientMismatch.selector, address(0), recipient)
        );
        _swap(m, hd);
    }

    function test_granteeIsPerDestinationChain() public {
        assertEq(roles.resolveGrantee(GRANTEE_LABEL, chainSelector), recipient);
        assertEq(roles.resolveGrantee(GRANTEE_LABEL, chainSelector + 1), address(0), "other chain: not configured");
        vm.prank(daoOwner);
        roles.setGrantee(GRANTEE_LABEL, chainSelector + 1, address(0xBEEF));
        assertEq(roles.resolveGrantee(GRANTEE_LABEL, chainSelector + 1), address(0xBEEF));
        assertEq(roles.resolveGrantee(GRANTEE_LABEL, chainSelector), recipient, "independent per chain");
    }

    function test_onlyNidhiRolesCountAndOnlyAdminManages() public {
        assertTrue(roles.isAuthorized(roles.APPROVER(), approver));
        assertFalse(roles.isAuthorized(roles.APPROVER(), auditor), "roles are not interchangeable");
        assertFalse(roles.isAuthorized(roles.DEFAULT_ADMIN_ROLE(), daoOwner), "admin role is not a Nidhi role");
        assertFalse(roles.isAuthorized(roles.GRANTEE_ADMIN(), daoOwner), "grantee-admin is not a Nidhi role");
        assertFalse(roles.isAuthorized(keccak256("anything"), approver));

        bytes32 approverRole = roles.APPROVER();
        bytes32 adminRole = roles.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole));
        roles.grantRole(approverRole, address(this));

        bytes32 granteeAdmin = roles.GRANTEE_ADMIN();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), granteeAdmin));
        roles.setGrantee("x", chainSelector, address(1));
    }

    function test_granteeLabelValidationAndEvent() public {
        vm.startPrank(daoOwner);
        vm.expectRevert(RoleAuthority.LabelTooLong.selector);
        roles.setGrantee("", chainSelector, address(1));
        vm.expectRevert(RoleAuthority.LabelTooLong.selector);
        roles.setGrantee("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", chainSelector, address(1));
        vm.expectEmit(true, true, true, true, address(roles));
        emit RoleAuthority.GranteeSet("bob", chainSelector, address(0xB0B), daoOwner);
        roles.setGrantee("bob", chainSelector, address(0xB0B));
        vm.stopPrank();
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(RoleAuthority.ZeroAdmin.selector);
        new RoleAuthority(address(0));
    }
}

// ============================================================================ reference-price guard

contract MockStateView {
    uint160 public sqrtPriceX96;

    function setSqrtPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPriceX96, 0, 0, 0);
    }
}

contract PriceGuardTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;
    uint160 constant ONE = 79228162514264337593543950336; // sqrt(1) * 2^96
    MockStateView internal stateView;

    function _guard() internal override returns (NidhiHook.ReferenceGuard memory g) {
        stateView = new MockStateView();
        stateView.setSqrtPrice(ONE); // reference price: 1 payout per 1 base (pool is also 1:1)
        g = NidhiHook.ReferenceGuard({
            stateView: address(stateView),
            poolId: keccak256("reference-pool"),
            baseToken: address(weth),
            payoutToken: address(bnm),
            baseIsCurrency0: address(weth) < address(bnm),
            maxDeviationBps: 100 // 1%: covers the 0.30% fee + tiny impact
        });
    }

    /// Run the swap and return the hook's own error selector (unwrapping v4's WrappedError).
    function _hookRevertSelector(bytes memory hd) internal returns (bytes4 sel) {
        vm.prank(executor);
        try nidhiRouter.swap(key, _params(AMOUNT_IN), hd, block.timestamp) {
            return bytes4(0);
        } catch (bytes memory err) {
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
            (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
            return bytes4(reason);
        }
    }

    function test_inBandPasses() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }

    function test_skewedPoolVersusReferenceReverts() public {
        // reference moves 5% away from the thin pool: the achieved rate is now far outside the 1% band
        uint160 skewed = uint160((uint256(ONE) * 1025) / 1000); // price ~ +5.06%
        // orient so that the reference rate (payout per base) is ~5% HIGHER than what our pool pays
        stateView.setSqrtPrice(address(weth) < address(bnm) ? skewed : uint160((uint256(ONE) * 1000) / 1025));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        assertEq(_hookRevertSelector(hd), NidhiHook.PriceDeviation.selector, "rejected by the price guard, not something else");
        assertFalse(hook.grantUsed(m.grantId), "whole tx reverted: grant not consumed");
    }

    function test_deviationBelowReferenceAlsoReverts() public {
        uint160 low = uint160((uint256(ONE) * 975) / 1000);
        stateView.setSqrtPrice(address(weth) < address(bnm) ? low : uint160((uint256(ONE) * 1000) / 975));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        assertEq(_hookRevertSelector(hd), NidhiHook.PriceDeviation.selector);
    }

    function test_guardConfigIsImmutableAndReadable() public view {
        assertEq(address(hook.guardStateView()), address(stateView));
        assertEq(hook.guardBaseToken(), address(weth));
        assertEq(hook.guardPayoutToken(), address(bnm));
        assertEq(hook.guardMaxDeviationBps(), 100);
    }
}

contract PriceGuardDisabledAndInvalidTest is NidhiBase {
    function test_disabledGuardIgnoresPrice() public {
        assertEq(address(hook.guardStateView()), address(0));
        Mandate memory m = _mandate(_newGrantId(), 0.001 ether);
        bytes memory hd = _hookData(m);
        _swap(m, hd); // no guard configured: passes regardless of any reference price
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }

    function _deployHookAt(address at, NidhiHook.ReferenceGuard memory g) internal {
        deployCodeTo(
            "NidhiHook.sol:NidhiHook",
            abi.encode(manager, authority, dispatcher, address(nidhiRouter), daoOwner, DAILY_CAP, address(0), g),
            at
        );
    }

    function test_revert_invalidGuardConfig() public {
        NidhiHook.ReferenceGuard memory ok = NidhiHook.ReferenceGuard({
            stateView: address(0xAB),
            poolId: bytes32(0),
            baseToken: address(weth),
            payoutToken: address(bnm),
            baseIsCurrency0: true,
            maxDeviationBps: 100
        });
        // positive control: the same deployment with a VALID guard succeeds, so a failure below is the guard's
        _deployHookAt(address(uint160(0x44440000000000000000000000000000000000c4)), ok);

        NidhiHook.ReferenceGuard memory noBase = ok;
        noBase.baseToken = address(0);
        vm.expectRevert();
        this.deployBad(noBase);
        NidhiHook.ReferenceGuard memory noBand = ok;
        noBand.maxDeviationBps = 0;
        vm.expectRevert();
        this.deployBad(noBand);
    }

    /// external so vm.expectRevert can observe the deployment failure
    function deployBad(NidhiHook.ReferenceGuard memory g) external {
        _deployHookAt(address(uint160(0x55550000000000000000000000000000000000c4)), g);
    }
}

// ============================================================================ multi-destination / multi-source routing

contract MultiChainRoutingTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;
    uint64 constant OTHER_CHAIN = 777;

    function test_routesAreAddOnlyAndPerChain() public {
        assertEq(dispatcher.destReceivers(chainSelector), address(receiver));
        assertEq(dispatcher.destReceivers(OTHER_CHAIN), address(0));
        address second = address(new DestinationReceiver(address(ccipRouter), link, daoOwner));
        vm.startPrank(daoOwner);
        dispatcher.addDestination(OTHER_CHAIN, second);
        vm.expectRevert(NidhiDispatcher.AlreadySet.selector);
        dispatcher.addDestination(OTHER_CHAIN, address(1));
        vm.stopPrank();
        assertEq(dispatcher.destReceivers(OTHER_CHAIN), second);
        assertEq(dispatcher.destReceivers(chainSelector), address(receiver), "first route untouched");
    }

    function test_unknownDestinationChainRejected() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.destChainSelector = OTHER_CHAIN; // no route registered
        bytes memory hd = _hookData(m);
        // the hook authorizes first; the recipient lookup for an unmapped chain fails closed
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.RecipientMismatch.selector, address(0), recipient)
        );
        _swap(m, hd);
    }

    function test_receiverAcceptsOnlyAllowlistedTokens() public {
        // a second source chain is trusted, but a token that was never allowlisted is refused
        vm.prank(daoOwner);
        receiver.addSource(OTHER_CHAIN, address(0xD15));
        Client.EVMTokenAmount[] memory t = new Client.EVMTokenAmount[](1);
        t[0] = Client.EVMTokenAmount(address(weth), 1);
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: OTHER_CHAIN,
            sender: abi.encode(address(0xD15)),
            data: AckLib.encodeGrant(bytes32(uint256(9)), recipient, 1),
            destTokenAmounts: t
        });
        vm.prank(address(ccipRouter));
        vm.expectRevert(DestinationReceiver.UnexpectedTokens.selector);
        receiver.ccipReceive(msg_);
    }

    function test_senderMustMatchTheRouteOfItsOwnChain() public {
        // OTHER_CHAIN is trusted with dispatcher 0xD15; a message from the *main* dispatcher claiming OTHER_CHAIN fails
        vm.prank(daoOwner);
        receiver.addSource(OTHER_CHAIN, address(0xD15));
        Client.EVMTokenAmount[] memory t = new Client.EVMTokenAmount[](1);
        t[0] = Client.EVMTokenAmount(address(bnm), 1);
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: OTHER_CHAIN,
            sender: abi.encode(address(dispatcher)),
            data: AckLib.encodeGrant(bytes32(uint256(9)), recipient, 1),
            destTokenAmounts: t
        });
        vm.prank(address(ccipRouter));
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.UnknownSource.selector, OTHER_CHAIN, address(dispatcher)));
        receiver.ccipReceive(msg_);
    }

    /// An ACK only counts if it comes from the chain the grant was actually sent to.
    function test_ackFromWrongChainCannotSettle() public {
        // grant 1 goes to a destination registered under OTHER_CHAIN (a second receiver trusting this dispatcher)
        DestinationReceiver second = new DestinationReceiver(address(ccipRouter), link, daoOwner);
        vm.startPrank(daoOwner);
        dispatcher.addDestination(OTHER_CHAIN, address(second));
        second.addSource(chainSelector, address(dispatcher)); // the simulator reports this chain's selector as source
        second.allowToken(address(bnm));
        vm.stopPrank();
        sim.requestLinkFromFaucet(address(second), 10 ether);
        grantees.setGrantee(GRANTEE_LABEL, recipient); // already set; simulator maps all chains to one selector

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.destChainSelector = OTHER_CHAIN;
        m.destReceiver = address(second);
        // route the recipient lookup for OTHER_CHAIN to the same address
        // (ENS authority maps selector->coin type; register OTHER_CHAIN there by deploying a variant authority is
        //  out of scope: instead drive dispatch() directly as the hook)
        bnm.drip(address(dispatcher));
        vm.prank(address(hook));
        dispatcher.dispatch(m, 1 ether);

        // payout happened at the second receiver, but its ACK arrives labelled with the simulator's selector
        // (chainSelector), not OTHER_CHAIN -> the dispatcher must reject it and keep the grant open
        assertEq(bnm.balanceOf(recipient), 1 ether, "payout landed");
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.DISPATCHED), "not settled by a foreign-chain ACK");
        assertTrue(second.getPayout(m.grantId).ackPending, "second receiver keeps the ACK queued for retry");
        assertEq(dispatcher.getGrant(m.grantId).destSelector, OTHER_CHAIN);
    }
}
