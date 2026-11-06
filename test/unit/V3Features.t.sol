// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CCIPLocalRouter} from "@chainlink/local/src/ccip/CCIPLocalRouter.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {ENSv2Authority, IENSv2Registry} from "../../src/ENSv2Authority.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";
import {MockENSv2Registry} from "../mocks/MockENSv2Registry.sol";

contract V3FeaturesTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;

    function _settled(bytes32 id) internal view returns (bool) {
        return dispatcher.statusOf(id) == NidhiDispatcher.Status.SETTLED;
    }

    // =================================================================== A1 daily cap

    function test_dailyCapAccumulatesAndBlocks() public {
        // spend 0.6 + 0.3 of a 1.0 cap, then 0.2 must fail
        Mandate memory m1 = _mandate(_newGrantId(), 0.6 ether);
        _quietLiquidity();
        bytes memory h1 = _hookData(m1);
        _swap(m1, h1);
        Mandate memory m2 = _mandate(_newGrantId(), 0.3 ether);
        bytes memory h2 = _hookData(m2);
        _swap(m2, h2);
        assertEq(hook.remainingToday(), 0.1 ether);

        Mandate memory m3 = _mandate(_newGrantId(), 0.2 ether);
        bytes memory h3 = _hookData(m3);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.CapExceeded.selector, 0.2 ether, 0.1 ether)
        );
        _swap(m3, h3);

        vm.warp(block.timestamp + 1 days); // new UTC day resets the window
        m3.deadline = uint64(block.timestamp + 1 hours);
        h3 = _hookData(m3);
        _swap(m3, h3);
        assertTrue(_settled(m3.grantId));
    }

    // =================================================================== A2 cancellation

    function test_approverCancelsBeforeExecution() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        vm.prank(approver);
        hook.cancelGrant(m.grantId);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.GrantAlreadyUsed.selector, m.grantId)
        );
        _swap(m, hd);
    }

    function test_revert_cancelGuards() public {
        bytes32 id = _newGrantId();
        vm.expectRevert(abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, authority.APPROVER(), address(this)));
        hook.cancelGrant(id);

        Mandate memory m = _mandate(id, AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(NidhiHook.GrantAlreadyUsed.selector, id));
        hook.cancelGrant(id);
    }

    // =================================================================== A3 ENS guardian kill-switch

    function test_guardianPauseBlocksAllGrants() public {
        vm.prank(guardian);
        hook.setPaused(true);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.Paused.selector));
        _swap(m, hd);

        vm.prank(guardian);
        hook.setPaused(false);
        _swap(m, hd);
        assertTrue(_settled(m.grantId));
    }

    function test_revert_onlyEnsGuardianCanPause() public {
        bytes32 role = authority.GUARDIAN();
        vm.prank(approver); // approvers are not guardians
        vm.expectRevert(abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, role, approver));
        hook.setPaused(true);

        eac.revoke(GUARDIAN_RES, ROLE_SET_TEXT, guardian); // revoking the ENS role removes the power
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, role, guardian));
        hook.setPaused(true);
    }

    // =================================================================== B ENS-native payouts

    function test_revert_recipientMustMatchEnsSubname() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.recipient = makeAddr("not-alice");
        bytes memory hd = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.RecipientMismatch.selector, recipient, m.recipient)
        );
        _swap(m, hd);
    }

    function test_revert_labelMustMatchSignedHash() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        NidhiHook.GrantAuth memory g = abi.decode(_hookData(m), (NidhiHook.GrantAuth));
        g.recipientLabel = "bob"; // unsigned field swapped after signing
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.InvalidMandate.selector));
        _swap(m, abi.encode(g));
    }

    function test_revert_expiredSubnameBlocksPayout() public {
        grantees.expire(GRANTEE_LABEL);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.RecipientMismatch.selector, address(0), recipient)
        );
        _swap(m, hd);
    }

    function test_repointingSubnameRedirectsFutureGrants() public {
        address newWallet = makeAddr("alice-new-wallet");
        Mandate memory oldM = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory oldHd = _hookData(oldM);

        grantees.setGrantee(GRANTEE_LABEL, newWallet); // grantee rotates their wallet in ENS

        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.RecipientMismatch.selector, newWallet, recipient)
        );
        _swap(oldM, oldHd);

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.recipient = newWallet;
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        assertGt(bnm.balanceOf(newWallet), 0, "paid to the wallet ENS points at");
    }

    function test_authorityResolveEdges() public {
        assertEq(authority.resolveGrantee(GRANTEE_LABEL, chainSelector), recipient);
        assertEq(authority.resolveGrantee("nobody", chainSelector), address(0));
        assertEq(authority.resolveGrantee("", chainSelector), address(0));
        assertEq(
            authority.resolveGrantee("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", chainSelector),
            address(0)
        );
        // DAO without a subregistry resolves nothing
        MockENSv2Registry bare = new MockENSv2Registry();
        bare.set("other-dao", address(eac), uint64(block.timestamp + 1 days));
        ENSv2Authority a2 = _authority(bare, "other-dao");
        assertEq(a2.resolveGrantee(GRANTEE_LABEL, chainSelector), address(0));
        assertEq(authority.resolveGrantee(GRANTEE_LABEL, 12345), address(0), "unknown destination chain fails closed");
        assertEq(ensAuthority.resourceOf(authority.GUARDIAN()), GUARDIAN_RES);
    }

    // =================================================================== A4 batch payouts

    function test_batchPaysSeveralGrantsInOneTx() public {
        (SwapParams[] memory ps, bytes[] memory hs, bytes32[] memory ids) = _batch(3, false);
        vm.prank(executor);
        nidhiRouter.swapBatch(key, ps, hs, block.timestamp);
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(_settled(ids[i]));
        }
        assertEq(bnm.balanceOf(address(hook)) + bnm.balanceOf(address(dispatcher)), 0);
    }

    function test_batchIsAllOrNothing() public {
        (SwapParams[] memory ps, bytes[] memory hs, bytes32[] memory ids) = _batch(3, true); // last grant tampered
        vm.prank(executor);
        vm.expectRevert();
        nidhiRouter.swapBatch(key, ps, hs, block.timestamp);
        for (uint256 i; i < ids.length; ++i) {
            assertFalse(hook.grantUsed(ids[i]), "no grant consumed");
        }
    }

    function test_revert_batchLengthMismatch() public {
        SwapParams[] memory ps = new SwapParams[](2);
        bytes[] memory hs = new bytes[](1);
        vm.expectRevert(NidhiSwapRouter.LengthMismatch.selector);
        nidhiRouter.swapBatch(key, ps, hs, block.timestamp);
    }

    // =================================================================== C Automation self-healing

    function test_automationPaysHeldGrantAfterUnpause() public {
        vm.prank(daoOwner);
        receiver.setPayoutsPaused(true);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);

        assertEq(receiver.queueLength(), 1, "held grant queued");
        (bool need,) = receiver.checkUpkeep("");
        assertFalse(need, "not actionable while payouts are paused");

        vm.prank(daoOwner);
        receiver.setPayoutsPaused(false);
        (bool need2, bytes memory data) = receiver.checkUpkeep("");
        assertTrue(need2);
        receiver.performUpkeep(data); // anyone / the Automation forwarder

        assertEq(bnm.balanceOf(recipient), receiver.getPayout(m.grantId).amount);
        assertTrue(_settled(m.grantId));
        assertEq(receiver.queueLength(), 0, "queue drained");
    }

    function test_automationRetriesFailedAck() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.1 ether);
        uint256 bal = _linkBalOf(address(receiver));
        vm.prank(daoOwner);
        receiver.withdrawFees(daoOwner, bal);

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        assertTrue(receiver.getPayout(m.grantId).ackPending);
        (bool need, bytes memory data) = receiver.checkUpkeep("");
        assertTrue(need);

        receiver.performUpkeep(data); // still unfunded: stays queued, never reverts
        assertEq(receiver.queueLength(), 1);

        sim.requestLinkFromFaucet(address(receiver), 1 ether);
        (, data) = receiver.checkUpkeep("");
        receiver.performUpkeep(data);
        assertTrue(_settled(m.grantId));
        assertEq(receiver.queueLength(), 0);
        (bool after_,) = receiver.checkUpkeep("");
        assertFalse(after_);
    }

    function test_performUpkeepSkipsStaleIds() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("never-seen");
        ids[1] = keccak256("also-never-seen");
        receiver.performUpkeep(abi.encode(ids)); // must not revert
        assertEq(receiver.queueLength(), 0);
    }

    // =================================================================== helpers

    /// Deeper liquidity for the large cap test so price impact keeps outputs within [minOut, maxOut].
    function _quietLiquidity() internal {
        for (uint256 i; i < 20; ++i) {
            bnm.drip(address(this));
        }
        weth.mint(address(this), 50 ether);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 20e18, 0), ZERO_BYTES);
        weth.mint(executor, 5 ether);
    }

    function _batch(uint256 n, bool tamperLast)
        internal
        returns (SwapParams[] memory ps, bytes[] memory hs, bytes32[] memory ids)
    {
        ps = new SwapParams[](n);
        hs = new bytes[](n);
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
            ids[i] = m.grantId;
            ps[i] = _params(AMOUNT_IN);
            bytes memory hd = _hookData(m);
            if (tamperLast && i == n - 1) {
                NidhiHook.GrantAuth memory g = abi.decode(hd, (NidhiHook.GrantAuth));
                g.mandate.recipient = makeAddr("thief");
                hd = abi.encode(g);
            }
            hs[i] = hd;
        }
    }

    function _linkBalOf(address who) internal view returns (uint256) {
        (bool ok, bytes memory r) = link.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok);
        return abi.decode(r, (uint256));
    }
}

import {
    RevertingSubregistry,
    FixedSubregistry,
    RevertingResolver,
    ShortReturnResolver,
    WrongLengthResolver
} from "../mocks/BrokenENS.sol";

/// resolveGrantee must return address(0) - never revert, never a wrong address - for every broken link.
contract ResolveGranteeFailClosedTest is NidhiBase {
    function _authorityWithSub(address sub) internal returns (ENSv2Authority) {
        MockENSv2Registry r = new MockENSv2Registry();
        r.set("dao", address(eac), uint64(block.timestamp + 1 days));
        r.setSubregistry("dao", sub);
        return _authority(r, "dao");
    }

    function test_revertingSubregistry() public {
        assertEq(_authorityWithSub(address(new RevertingSubregistry())).resolveGrantee("alice", chainSelector), address(0));
    }

    function test_subregistryWithoutResolver() public {
        assertEq(_authorityWithSub(address(new FixedSubregistry(address(0)))).resolveGrantee("alice", chainSelector), address(0));
    }

    function test_revertingResolver() public {
        address sub = address(new FixedSubregistry(address(new RevertingResolver())));
        assertEq(_authorityWithSub(sub).resolveGrantee("alice", chainSelector), address(0));
    }

    function test_shortReturnResolver() public {
        address sub = address(new FixedSubregistry(address(new ShortReturnResolver())));
        assertEq(_authorityWithSub(sub).resolveGrantee("alice", chainSelector), address(0));
    }

    function test_wrongLengthAddressRecord() public {
        address sub = address(new FixedSubregistry(address(new WrongLengthResolver())));
        assertEq(_authorityWithSub(sub).resolveGrantee("alice", chainSelector), address(0));
    }

    function test_granteeNameEncoding() public view {
        assertEq(
            ensAuthority.granteeName("alice"),
            abi.encodePacked(uint8(5), "alice", uint8(9), "nidhi-dao", uint8(3), "eth", uint8(0))
        );
    }
}
