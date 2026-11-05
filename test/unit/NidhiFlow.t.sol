// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CCIPLocalRouter} from "@chainlink/local/src/ccip/CCIPLocalRouter.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";

contract NidhiFlowTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;

    // =================================================================== happy path

    function test_happyPath_swapBridgePayAck() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        uint256 wethBefore = weth.balanceOf(executor);

        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        uint256 paid = bnm.balanceOf(recipient);
        assertGt(paid, 0, "recipient paid");
        assertEq(weth.balanceOf(executor), wethBefore - AMOUNT_IN, "exact input spent");
        assertEq(bnm.balanceOf(executor), 0, "executor received no output");

        // closed loop: ACK landed and the source ledger is SETTLED
        NidhiDispatcher.Grant memory g = dispatcher.getGrant(m.grantId);
        assertEq(uint8(g.status), uint8(NidhiDispatcher.Status.SETTLED), "settled");
        assertEq(g.outcome, AckLib.PAID);
        assertEq(g.amount, paid);
        assertTrue(g.messageId != bytes32(0), "messageId recorded");
        assertTrue(hook.grantUsed(m.grantId));

        DestinationReceiver.Payout memory p = receiver.getPayout(m.grantId);
        assertEq(p.outcome, AckLib.PAID);
        assertEq(p.messageId, g.messageId, "same CCIP message id on both sides");
        assertFalse(p.ackPending);

        _assertNoResidualBalances();
    }

    function test_happyPath_withCcipFeesInLink() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.1 ether);
        uint256 dispLink = _linkBal(address(dispatcher));
        uint256 recvLink = _linkBal(address(receiver));

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        assertEq(_linkBal(address(dispatcher)), dispLink - 0.1 ether, "source fee paid in LINK");
        assertEq(_linkBal(address(receiver)), recvLink - 0.1 ether, "ACK fee paid in LINK");
    }

    // =================================================================== signer types

    /// EIP-7702-delegated EOAs have code (0xef0100 || delegate) but are still controlled by their key.
    function test_eip7702DelegatedApproverAccepted() public {
        vm.etch(approver, abi.encodePacked(hex"ef0100", address(0xDE1E6A7E)));
        vm.etch(auditor, abi.encodePacked(hex"ef0100", address(0xDE1E6A7E)));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }

    /// A Safe-style ERC-1271 contract wallet can hold the APPROVER role and sign mandates.
    function test_erc1271SmartWalletApproverAccepted() public {
        MockERC1271Wallet safe = new MockERC1271Wallet(approver);
        eac.grant(APPROVER_RES, ROLE_SET_TEXT, address(safe));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        Attestation memory a = _attestation(m);
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: address(safe),
            approverSig: _sign(approverPk, hook.mandateDigest(m)), // owner key signs on behalf of the wallet
            attestation: a,
            auditor: auditor,
            auditorSig: _sign(auditorPk, hook.attestationDigest(a)),
            recipientLabel: GRANTEE_LABEL
        });
        _swap(m, abi.encode(g));
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }

    function test_revert_erc1271WalletRejectsForeignSigner() public {
        MockERC1271Wallet safe = new MockERC1271Wallet(approver);
        eac.grant(APPROVER_RES, ROLE_SET_TEXT, address(safe));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        Attestation memory a = _attestation(m);
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: address(safe),
            approverSig: _sign(0xBAD, hook.mandateDigest(m)),
            attestation: a,
            auditor: auditor,
            auditorSig: _sign(auditorPk, hook.attestationDigest(a)),
            recipientLabel: GRANTEE_LABEL
        });
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.BadSignature.selector, address(safe))
        );
        _swap(m, abi.encode(g));
    }

    // =================================================================== firewall (beforeSwap)

    function test_revert_approverWithoutEnsRole() public {
        eac.revoke(APPROVER_RES, ROLE_SET_TEXT, approver);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, authority.APPROVER(), approver)
        );
        _swap(m, hd_);
    }

    function test_revert_auditorWithoutEnsRole() public {
        eac.revoke(AUDITOR_RES, ROLE_SET_TEXT, auditor);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, authority.AUDITOR(), auditor)
        );
        _swap(m, hd_);
    }

    function test_ensNameExpiryFreezesPayouts() public {
        vm.warp(block.timestamp + 366 days); // DAO name lapses -> registry returns no resolver
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, authority.APPROVER(), approver)
        );
        _swap(m, hd_);
    }

    function test_ensRevocationBlocksNextPayout() public {
        Mandate memory m1 = _mandate(_newGrantId(), AMOUNT_IN);
        _swap(m1, _hookData(m1)); // works

        eac.revoke(APPROVER_RES, ROLE_SET_TEXT, approver);

        Mandate memory m2 = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m2);
        vm.prank(executor);
        vm.expectRevert();
        nidhiRouter.swap(key, _params(AMOUNT_IN), hd, block.timestamp);
    }

    function test_revert_signatureFromNonApprover() public {
        uint256 mallory = 0xBAD;
        eac.grant(AUDITOR_RES, ROLE_SET_TEXT, vm.addr(mallory));
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        // mallory signs as approver but has no approver role
        bytes memory hd_ = _hookData(m, _attestation(m), mallory, auditorPk);
        _expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, authority.APPROVER(), vm.addr(mallory))
        );
        _swap(m, hd_);
    }

    function test_revert_tamperedMandate() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        NidhiHook.GrantAuth memory g = abi.decode(hd, (NidhiHook.GrantAuth));
        g.mandate.recipient = makeAddr("attacker"); // changed after signing
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.BadSignature.selector, approver));
        _swap(g.mandate, abi.encode(g));
    }

    function test_revert_forgedAuditorSignature() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        NidhiHook.GrantAuth memory g = abi.decode(_hookData(m), (NidhiHook.GrantAuth));
        g.auditorSig = _sign(0xBAD, hook.attestationDigest(g.attestation));
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.BadSignature.selector, auditor));
        _swap(m, abi.encode(g));
    }

    function test_revert_attestationForDifferentEvidence() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        Attestation memory a = _attestation(m);
        a.evidenceHash = keccak256("other evidence");
        bytes memory hd_ = _hookData(m, a, approverPk, auditorPk);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.AttestationMismatch.selector));
        _swap(m, hd_);
    }

    function test_revert_sameKeyForBothRoles() public {
        eac.grant(AUDITOR_RES, ROLE_SET_TEXT, approver);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m, _attestation(m), approverPk, approverPk);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.SameSigner.selector));
        _swap(m, hd_);
    }

    function test_revert_replaySameGrant() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.GrantAlreadyUsed.selector, m.grantId)
        );
        _swap(m, hd);
    }

    function test_revert_expiredMandate() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        vm.warp(m.deadline + 1);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.MandateExpired.selector));
        _swap(m, hd);
    }

    function test_revert_wrongExecutor_frontRunWithLeakedMandate() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        address thief = makeAddr("thief");
        weth.mint(thief, 1 ether);
        vm.startPrank(thief);
        weth.approve(address(nidhiRouter), type(uint256).max);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.WrongExecutor.selector, executor, thief)
        );
        nidhiRouter.swap(key, _params(AMOUNT_IN), hd, block.timestamp);
        vm.stopPrank();
    }

    function test_revert_untrustedRouter() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        weth.approve(address(swapRouter), type(uint256).max);
        weth.mint(address(this), 1 ether);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.UntrustedRouter.selector, address(swapRouter))
        );
        swapRouter.swap(key, _params(AMOUNT_IN), PoolSwapTest.TestSettings(false, false), hd);
    }

    function test_revert_amountDiffersFromMandate() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        vm.prank(executor);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.NotExactInput.selector));
        nidhiRouter.swap(key, _params(AMOUNT_IN * 2), hd, block.timestamp);
    }

    function test_revert_exactOutputSwap() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        SwapParams memory p = _params(AMOUNT_IN);
        p.amountSpecified = int256(uint256(AMOUNT_IN));
        vm.prank(executor);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.NotExactInput.selector));
        nidhiRouter.swap(key, p, hd, block.timestamp);
    }

    function test_revert_wrongDirection() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        (m.tokenIn, m.tokenOut) = (m.tokenOut, m.tokenIn); // signed for the reverse direction
        bytes memory hd = _hookData(m);
        vm.prank(executor);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.WrongDirection.selector));
        nidhiRouter.swap(key, _params(AMOUNT_IN), hd, block.timestamp);
    }

    function test_revert_invalidMandateBand() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.minOut = m.maxOut + 1;
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.InvalidMandate.selector));
        _swap(m, hd_);
    }

    function test_revert_mandateForOtherPool() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.poolId = keccak256("another pool");
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.WrongPool.selector));
        _swap(m, hd_);
    }

    // =================================================================== capture (afterSwap)

    function test_revert_outputBelowMin() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.minOut = AMOUNT_IN; // impossible after fee + price impact
        uint256 expectedOut = _quoteOut(AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(NidhiHook.OutputOutOfBounds.selector, expectedOut, m.minOut, m.maxOut)
        );
        _swap(m, hd_);
    }

    function test_revert_outputAboveMax() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.maxOut = 1;
        uint256 expectedOut = _quoteOut(AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(NidhiHook.OutputOutOfBounds.selector, expectedOut, m.minOut, m.maxOut)
        );
        _swap(m, hd_);
    }

    function test_revert_wrongDestinationInMandate() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.destReceiver = makeAddr("rogue receiver");
        bytes memory hd_ = _hookData(m);
        _expectHookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(NidhiDispatcher.WrongDestination.selector));
        _swap(m, hd_);
    }

    // =================================================================== access control

    function test_revert_directHookCall() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(nidhiRouter), key, _params(AMOUNT_IN), hd_);
    }

    function test_revert_dispatchFromNonHook() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        vm.expectRevert(NidhiDispatcher.OnlyHook.selector);
        dispatcher.dispatch(m, 1);
    }

    function test_revert_ccipReceiveFromNonRouter() public {
        Client.Any2EVMMessage memory msg_;
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(this)));
        dispatcher.ccipReceive(msg_);
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(this)));
        receiver.ccipReceive(msg_);
    }

    function test_revert_forgedAckFromUnknownSender() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: chainSelector,
            sender: abi.encode(makeAddr("forger")),
            data: AckLib.encodeAck(bytes32(uint256(7)), bytes32(0), 0, AckLib.PAID),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.prank(address(ccipRouter));
        vm.expectRevert(
            abi.encodeWithSelector(NidhiDispatcher.UnknownSource.selector, chainSelector, makeAddr("forger"))
        );
        dispatcher.ccipReceive(msg_);
    }

    function test_revert_forgedGrantAtDestination() public {
        Client.EVMTokenAmount[] memory t = new Client.EVMTokenAmount[](1);
        t[0] = Client.EVMTokenAmount({token: address(bnm), amount: 1 ether});
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: chainSelector,
            sender: abi.encode(makeAddr("forger")),
            data: AckLib.encodeGrant(bytes32(uint256(7)), makeAddr("forger"), 1 ether),
            destTokenAmounts: t
        });
        vm.prank(address(ccipRouter));
        vm.expectRevert(
            abi.encodeWithSelector(DestinationReceiver.UnknownSource.selector, chainSelector, makeAddr("forger"))
        );
        receiver.ccipReceive(msg_);
    }

    function test_oneTimeWiring() public {
        vm.startPrank(daoOwner);
        vm.expectRevert(NidhiHook.PoolAlreadySet.selector);
        hook.setPool(key);
        vm.expectRevert(NidhiDispatcher.AlreadySet.selector);
        dispatcher.setHook(address(1));
        vm.expectRevert(NidhiDispatcher.AlreadySet.selector);
        dispatcher.setDestReceiver(address(1));
        vm.expectRevert(DestinationReceiver.AlreadySet.selector);
        receiver.setSourceDispatcher(address(1));
        vm.stopPrank();
    }

    // =================================================================== destination failure + recovery

    function test_pausedPayoutIsHeldThenRecovered() public {
        vm.prank(daoOwner);
        receiver.setPayoutsPaused(true);

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        assertEq(bnm.balanceOf(recipient), 0, "nothing paid while paused");
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.HELD), "source knows it is held");
        uint256 held = receiver.getPayout(m.grantId).amount;
        assertEq(bnm.balanceOf(address(receiver)), held, "funds held at receiver");

        address safe = makeAddr("dao recovery safe");
        vm.prank(daoOwner);
        receiver.recover(m.grantId, safe);

        assertEq(bnm.balanceOf(safe), held);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        assertEq(dispatcher.getGrant(m.grantId).outcome, AckLib.RECOVERED);
    }

    function test_heldPayoutRetriedToRecipient() public {
        vm.prank(daoOwner);
        receiver.setPayoutsPaused(true);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        vm.expectRevert(DestinationReceiver.Paused.selector);
        receiver.retryPayout(m.grantId);

        vm.prank(daoOwner);
        receiver.setPayoutsPaused(false);
        receiver.retryPayout(m.grantId); // anyone may retry; funds only go to the recipient

        assertEq(bnm.balanceOf(recipient), receiver.getPayout(m.grantId).amount);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.NotHeld.selector, m.grantId));
        receiver.retryPayout(m.grantId);
    }

    function test_recoverOnlyOwnerAndOnlyHeld() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        _swap(m, _hookData(m)); // PAID
        vm.expectRevert();
        receiver.recover(m.grantId, address(this));
        vm.prank(daoOwner);
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.NotHeld.selector, m.grantId));
        receiver.recover(m.grantId, address(this));
    }

    function test_ackFailureNeverRollsBackPayout_thenRetryAck() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.1 ether);
        uint256 recvLinkBal = _linkBal(address(receiver));
        vm.prank(daoOwner);
        receiver.withdrawFees(daoOwner, recvLinkBal); // receiver cannot pay the ACK fee

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        assertGt(bnm.balanceOf(recipient), 0, "payout happened");
        assertTrue(receiver.getPayout(m.grantId).ackPending, "ACK queued");
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.DISPATCHED), "awaiting ACK");

        sim.requestLinkFromFaucet(address(receiver), 1 ether);
        receiver.retryAck(m.grantId);

        assertFalse(receiver.getPayout(m.grantId).ackPending);
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
    }

    function test_flagStuck() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.1 ether);
        uint256 recvLinkBal = _linkBal(address(receiver));
        vm.prank(daoOwner);
        receiver.withdrawFees(daoOwner, recvLinkBal);
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.NotStuck.selector, m.grantId));
        dispatcher.flagStuck(m.grantId);
        vm.warp(block.timestamp + 6 hours + 1);
        vm.expectEmit(true, false, false, false, address(dispatcher));
        emit NidhiDispatcher.GrantStuck(m.grantId, bytes32(0), 0);
        dispatcher.flagStuck(m.grantId);
    }

    function test_insufficientSourceFeeReverts() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(100 ether); // more than the dispatcher holds
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd_ = _hookData(m);
        vm.expectRevert(); // InsufficientFee, wrapped by afterSwap
        _swap(m, hd_);
        assertFalse(hook.grantUsed(m.grantId), "whole tx reverted, grant still usable");
    }

    // =================================================================== fuzz

    function testFuzz_payoutConservesValue(uint128 amountIn) public {
        amountIn = uint128(bound(amountIn, 1e9, 0.002 ether));
        Mandate memory m = _mandate(_newGrantId(), amountIn);
        uint256 expected = _quoteOut(amountIn);
        vm.assume(expected > 0);

        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);

        assertEq(bnm.balanceOf(recipient), expected, "recipient gets exactly the swap output");
        assertEq(uint8(dispatcher.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        _assertNoResidualBalances();
    }

    // =================================================================== helpers

    function _linkBal(address a) internal view returns (uint256) {
        return IERC20Like(link).balanceOf(a);
    }

    /// Simulate the swap without the hook capture to learn the exact output (state is reverted).
    function _quoteOut(uint128 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        Mandate memory m = _mandate(_newGrantId(), amountIn);
        bytes memory hd_ = _hookData(m);
        _swap(m, hd_);
        out = bnm.balanceOf(recipient);
        vm.revertToState(snap);
    }

    function _assertNoResidualBalances() internal view {
        assertEq(bnm.balanceOf(address(hook)), 0, "hook holds no output");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds no input");
        assertEq(bnm.balanceOf(address(dispatcher)), 0, "dispatcher holds no grant tokens");
        assertEq(bnm.balanceOf(address(nidhiRouter)), 0, "router holds nothing");
        assertEq(weth.balanceOf(address(nidhiRouter)), 0, "router holds nothing");
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
