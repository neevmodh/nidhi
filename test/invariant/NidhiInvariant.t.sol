// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CCIPLocalRouter} from "@chainlink/local/src/ccip/CCIPLocalRouter.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {Mandate} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";

/// @notice Drives the deployed system with random valid and invalid grant attempts.
contract NidhiHandler is Test {
    NidhiInvariantTest internal t;

    bytes32[] public grants;
    mapping(bytes32 => uint8) public lastStatus;
    uint256 public totalCaptured; // sum of amounts the dispatcher recorded as dispatched
    uint256 public successfulSwaps;
    uint256 public rejectedSwaps;

    constructor(NidhiInvariantTest t_) {
        t = t_;
    }

    /// A grant attempt with randomized amount and an optional single defect.
    function attempt(uint128 amountIn, uint8 defect, bool pauseDest) external {
        amountIn = uint128(bound(amountIn, 1e9, 0.002 ether));
        t.setPaused(pauseDest);
        // ~56% valid attempts (defect >= 7 means none), the rest carry exactly one defect.
        uint8 d = defect % 16;
        (bool ok, bytes32 grantId) = t.tryGrant(amountIn, d < 7 ? d : 0);
        if (ok) {
            successfulSwaps++;
            grants.push(grantId);
            totalCaptured += t.dispatcherAmount(grantId);
        } else {
            rejectedSwaps++;
        }
        _checkMonotonic();
    }

    /// Resolve a HELD grant via retry or DAO recovery.
    function resolveHeld(uint256 idx, bool recoverIt) external {
        if (grants.length == 0) return;
        bytes32 g = grants[idx % grants.length];
        t.resolve(g, recoverIt);
        _checkMonotonic();
    }

    function replay(uint256 idx) external {
        if (grants.length == 0) return;
        t.tryReplay(grants[idx % grants.length]);
    }

    function grantCount() external view returns (uint256) {
        return grants.length;
    }

    function _checkMonotonic() internal {
        for (uint256 i; i < grants.length; ++i) {
            uint8 s = t.statusOf(grants[i]);
            require(s >= lastStatus[grants[i]], "status went backwards");
            lastStatus[grants[i]] = s;
        }
    }
}

contract NidhiInvariantTest is NidhiBase {
    NidhiHandler internal handler;

    function setUp() public override {
        super.setUp();
        weth.mint(executor, 1_000 ether);
        // Deep full-range liquidity so random grant sequences never exhaust the pool (output -> 0).
        for (uint256 i; i < 40; ++i) {
            bnm.drip(address(this));
        }
        weth.mint(address(this), 100 ether);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 20e18, 0), ZERO_BYTES);
        handler = new NidhiHandler(this);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ invariants

    function invariant_noFundsRestInIntermediaries() public view {
        assertEq(bnm.balanceOf(address(hook)), 0);
        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(bnm.balanceOf(address(dispatcher)), 0);
        assertEq(bnm.balanceOf(address(nidhiRouter)), 0);
        assertEq(weth.balanceOf(address(nidhiRouter)), 0);
    }

    /// Everything captured is either with the grantee, held at the receiver, or with the recovery address.
    function invariant_valueConserved() public view {
        uint256 accounted = bnm.balanceOf(recipient) + bnm.balanceOf(address(receiver)) + bnm.balanceOf(RECOVERY);
        assertEq(accounted, handler.totalCaptured());
    }

    /// Source ledger agrees with the destination for every grant.
    function invariant_ledgersAgree() public view {
        for (uint256 i; i < handler.grantCount(); ++i) {
            bytes32 g = handler.grants(i);
            NidhiDispatcher.Grant memory sg = dispatcher.getGrant(g);
            DestinationReceiver.Payout memory dp = receiver.getPayout(g);
            assertEq(sg.amount, dp.amount);
            assertEq(sg.messageId, dp.messageId);
            assertTrue(hook.grantUsed(g));
            if (dp.outcome == AckLib.HELD) assertEq(uint8(sg.status), uint8(NidhiDispatcher.Status.HELD));
            else assertEq(uint8(sg.status), uint8(NidhiDispatcher.Status.SETTLED));
        }
    }

    /// The rolling daily cap is never exceeded, whatever sequence of grants runs.
    function invariant_dailyCapNeverExceeded() public view {
        assertLe(hook.spentPerDay(block.timestamp / 1 days), hook.maxAmountInPerDay());
    }

    /// The Automation queue holds exactly the grants that still need work (ACK owed or payout HELD).
    function invariant_automationQueueIsExact() public view {
        uint256 needing;
        for (uint256 i; i < handler.grantCount(); ++i) {
            DestinationReceiver.Payout memory p = receiver.getPayout(handler.grants(i));
            bool needs = p.ackPending || p.outcome == AckLib.HELD;
            if (needs) needing++;
            bool queued;
            for (uint256 j; j < receiver.queueLength(); ++j) {
                if (receiver.queuedAt(j) == handler.grants(i)) queued = true;
            }
            assertEq(queued, needs, "queue membership must equal needs-work");
        }
        assertEq(receiver.queueLength(), needing);
    }

    /// Guard against a vacuous run: both accepted and rejected paths must be exercised.
    function afterInvariant() public view {
        console2.log("successful grants:", handler.successfulSwaps());
        console2.log("rejected grants:  ", handler.rejectedSwaps());
        assertGt(handler.successfulSwaps(), 0, "no grant ever succeeded");
        assertGt(handler.rejectedSwaps(), 0, "no defect ever exercised");
    }

    // ------------------------------------------------------------------ handler plumbing

    address internal constant RECOVERY = address(0x5AFE);

    function setPaused(bool p) external {
        vm.prank(daoOwner);
        receiver.setPayoutsPaused(p);
    }

    function tryGrant(uint128 amountIn, uint8 defect) external returns (bool ok, bytes32 grantId) {
        grantId = _newGrantId();
        Mandate memory m = _mandate(grantId, amountIn);
        uint256 apPk = approverPk;
        uint256 auPk = auditorPk;
        if (defect == 1) m.deadline = uint64(block.timestamp - 1);
        if (defect == 2) m.minOut = m.maxOut + 1;
        if (defect == 3) apPk = 0xBAD; // no role
        if (defect == 4) auPk = approverPk; // same signer
        if (defect == 5) m.destReceiver = address(0xDEAD);
        if (defect == 6) m.maxOut = 1; // output above band
        bytes memory hd = _hookData(m, _attestation(m), apPk, auPk);
        vm.prank(executor);
        try nidhiRouter.swap(key, _params(amountIn), hd, block.timestamp) {
            ok = true;
        } catch {
            ok = false;
        }
        if (defect != 0) assertFalse(ok, "defective grant must be rejected");
        if (defect == 0) assertTrue(ok, "valid grant must succeed");
    }

    function tryReplay(bytes32 grantId) external {
        Mandate memory m = _mandate(grantId, 0.001 ether);
        bytes memory hd = _hookData(m);
        vm.prank(executor);
        try nidhiRouter.swap(key, _params(m.amountIn), hd, block.timestamp) {
            revert("replay succeeded");
        } catch {}
    }

    function resolve(bytes32 grantId, bool recoverIt) external {
        if (receiver.getPayout(grantId).outcome != AckLib.HELD) return;
        vm.startPrank(daoOwner);
        receiver.setPayoutsPaused(false);
        if (recoverIt) receiver.recover(grantId, RECOVERY);
        vm.stopPrank();
        if (!recoverIt) receiver.retryPayout(grantId);
    }

    function dispatcherAmount(bytes32 g) external view returns (uint256) {
        return dispatcher.getGrant(g).amount;
    }

    function statusOf(bytes32 g) external view returns (uint8) {
        return uint8(dispatcher.statusOf(g));
    }
}
