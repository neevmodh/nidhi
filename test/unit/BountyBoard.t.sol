// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {NidhiBountyBoard, IMandateDigest} from "../../src/NidhiBountyBoard.sol";
import {RoleAuthority} from "../../src/RoleAuthority.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";

/// The board is the approver (ERC-1271): it approves a payout only if it matches a posted milestone. The hook is
/// unchanged and still checks the auditor, the roles, the ENS-style grantee resolution, the cap and the band.
contract BountyBoardTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;
    RoleAuthority internal roles;
    NidhiBountyBoard internal board;
    address internal carol = makeAddr("carol"); // an open-bounty winner, registered as a grantee name
    bytes32 constant SPEC = keccak256("spec: write the guide");

    function _deployAuthority() internal override returns (IGrantAuthority) {
        roles = new RoleAuthority(daoOwner);
        vm.startPrank(daoOwner);
        roles.grantRole(roles.APPROVER(), approver);
        roles.grantRole(roles.AUDITOR(), auditor);
        roles.grantRole(roles.GUARDIAN(), guardian);
        roles.setGrantee(GRANTEE_LABEL, chainSelector, recipient);
        roles.setGrantee("carol", chainSelector, carol);
        vm.stopPrank();
        return IGrantAuthority(address(roles));
    }

    function setUp() public override {
        super.setUp();
        board = new NidhiBountyBoard(IMandateDigest(address(hook)), IGrantAuthority(address(roles)));
        bytes32 approverRole = roles.APPROVER();
        vm.prank(daoOwner);
        roles.grantRole(approverRole, address(board)); // the board holds the approver role itself
    }

    // ------------------------------------------------------------------ helpers

    function _post(string memory grantee) internal returns (uint256 id, NidhiBountyBoard.Bounty memory b) {
        Mandate memory t = _mandate(bytes32(0), AMOUNT_IN);
        b = NidhiBountyBoard.Bounty({
            poster: address(0),
            cancelled: false,
            grantId: bytes32(0),
            specHash: SPEC,
            granteeLabelHash: bytes(grantee).length == 0 ? bytes32(0) : keccak256(bytes(grantee)),
            executor: t.executor,
            tokenIn: t.tokenIn,
            tokenOut: t.tokenOut,
            amountIn: t.amountIn,
            minOut: t.minOut,
            maxOut: t.maxOut,
            destChainSelector: t.destChainSelector,
            destReceiver: t.destReceiver,
            poolId: t.poolId,
            deadline: t.deadline
        });
        NidhiBountyBoard.Spec memory spec = NidhiBountyBoard.Spec("Guide", "neevmodh/nidhi", "write it", "{}", grantee);
        vm.prank(approver);
        id = board.post(b, spec);
        b = board.getBounty(id);
    }

    function _payoutMandate(NidhiBountyBoard.Bounty memory b, string memory label, address to)
        internal
        view
        returns (Mandate memory m)
    {
        m = _mandate(b.grantId, b.amountIn);
        m.evidenceHash = b.specHash;
        m.recipient = to;
        m.recipientLabelHash = keccak256(bytes(label));
    }

    function _boardHookData(uint256 id, Mandate memory m, string memory label) internal view returns (bytes memory) {
        Attestation memory a = _attestation(m);
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: address(board),
            approverSig: abi.encode(id, m),
            attestation: a,
            auditor: auditor,
            auditorSig: _sign(auditorPk, hook.attestationDigest(a)),
            recipientLabel: label
        });
        return abi.encode(g);
    }

    // ------------------------------------------------------------------ tests

    function test_openBountyPaysTheWinner() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        Mandate memory m = _payoutMandate(b, "carol", carol);
        assertTrue(board.matches(id, m));
        _swap(m, _boardHookData(id, m, "carol"));
        assertEq(uint8(dispatcher.statusOf(b.grantId)), uint8(NidhiDispatcher.Status.SETTLED), "settled");
        assertGt(bnm.balanceOf(carol), 0, "the winner was paid");
    }

    function test_assignedBountyPaysOnlyItsGrantee() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post(GRANTEE_LABEL);
        Mandate memory wrong = _payoutMandate(b, "carol", carol);
        assertFalse(board.matches(id, wrong), "another name is not this milestone's grantee");
        bytes memory hd = _boardHookData(id, wrong, "carol");
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.BadSignature.selector, address(board))
        );
        _swap(wrong, hd);

        Mandate memory right = _payoutMandate(b, GRANTEE_LABEL, recipient);
        _swap(right, _boardHookData(id, right, GRANTEE_LABEL));
        assertGt(bnm.balanceOf(recipient), 0);
    }

    function test_paysAtMostOnce() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        Mandate memory m = _payoutMandate(b, "carol", carol);
        _swap(m, _boardHookData(id, m, "carol"));
        Mandate memory again = _payoutMandate(b, GRANTEE_LABEL, recipient);
        bytes memory hd = _boardHookData(id, again, GRANTEE_LABEL);
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.GrantAlreadyUsed.selector, b.grantId)
        );
        _swap(again, hd);
    }

    function test_tamperedAmountOrSpecIsRefused() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        Mandate memory m = _payoutMandate(b, "carol", carol);
        m.amountIn = b.amountIn + 1;
        assertFalse(board.matches(id, m), "amount");
        m = _payoutMandate(b, "carol", carol);
        m.evidenceHash = keccak256("another spec");
        assertFalse(board.matches(id, m), "spec");
        m = _payoutMandate(b, "carol", carol);
        m.maxOut = b.maxOut + 1;
        assertFalse(board.matches(id, m), "band");
        m = _payoutMandate(b, "carol", carol);
        m.destReceiver = makeAddr("elsewhere");
        assertFalse(board.matches(id, m), "destination");
        m = _payoutMandate(b, "carol", carol);
        m.recipient = address(0);
        assertFalse(board.matches(id, m), "recipient required");
    }

    function test_signatureMustHashToTheDigest() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        Mandate memory m = _payoutMandate(b, "carol", carol);
        assertEq(board.isValidSignature(hook.mandateDigest(m), abi.encode(id, m)), bytes4(0x1626ba7e));
        assertEq(board.isValidSignature(keccak256("other"), abi.encode(id, m)), bytes4(0xffffffff));
        assertEq(board.isValidSignature(hook.mandateDigest(m), hex"01"), bytes4(0xffffffff));
    }

    function test_cancelledBountyIsRefused() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        vm.prank(approver);
        board.cancel(id);
        assertFalse(board.matches(id, _payoutMandate(b, "carol", carol)));
    }

    function test_expiredBountyIsRefused() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        vm.warp(b.deadline + 1);
        assertFalse(board.matches(id, _payoutMandate(b, "carol", carol)));
    }

    function test_onlyApproversPostAndCancel() public {
        Mandate memory t = _mandate(bytes32(0), AMOUNT_IN);
        NidhiBountyBoard.Bounty memory b;
        b.specHash = SPEC;
        b.executor = t.executor;
        b.amountIn = t.amountIn;
        b.minOut = t.minOut;
        b.maxOut = t.maxOut;
        b.destChainSelector = t.destChainSelector;
        b.destReceiver = t.destReceiver;
        b.deadline = t.deadline;
        NidhiBountyBoard.Spec memory spec;
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NidhiBountyBoard.NotApprover.selector, stranger));
        board.post(b, spec);

        (uint256 id,) = _post("");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NidhiBountyBoard.NotPosterOrApprover.selector, stranger));
        board.cancel(id);
    }

    function test_revokingTheBoardsRoleStopsPayouts() public {
        (uint256 id, NidhiBountyBoard.Bounty memory b) = _post("");
        bytes32 role = roles.APPROVER();
        vm.prank(daoOwner);
        roles.revokeRole(role, address(board));
        Mandate memory m = _payoutMandate(b, "carol", carol);
        bytes memory hd = _boardHookData(id, m, "carol");
        _expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NidhiHook.NotAuthorized.selector, role, address(board))
        );
        _swap(m, hd);
    }
}
