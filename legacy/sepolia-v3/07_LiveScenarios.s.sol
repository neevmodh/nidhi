// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Demo, IWETH9Demo} from "./05_Demo.s.sol";
import {IPermissionedResolver} from "./ens/IENSv2.sol";
import {NidhiHook} from "../src/NidhiHook.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";
import {Mandate, Attestation} from "../src/libraries/Mandate.sol";

/// @notice Step 7 (Sepolia): exercise every v3 safety property against the LIVE deployment.
///   State changes (pause, revoke, cancel, batch) are broadcast as real transactions. Expected failures are proven by
///   simulating the grant against live state (never broadcast), decoding the hook's revert reason.
///
///   forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "pause()"
///   ... --sig "unpause()" | "revoke()" | "regrant()" | "tamper()" | "cancel()" | "batch()" | "probe()"
contract LiveScenarios is Demo {
    uint128 constant SCENARIO_AMOUNT = 0.0001 ether;
    uint256 constant ROLE_TEXT = 1 << 4;

    // ---------------------------------------------------------------- guardian kill-switch

    function pause() external {
        _init();
        _fund(vm.addr(vm.envUint("GUARDIAN_PRIVATE_KEY")));
        vm.broadcast(vm.envUint("GUARDIAN_PRIVATE_KEY"));
        hook.setPaused(true);
        _expect("guardian paused -> grant blocked", _probeFresh(false), NidhiHook.Paused.selector);
    }

    function unpause() external {
        _init();
        vm.broadcast(vm.envUint("GUARDIAN_PRIVATE_KEY"));
        hook.setPaused(false);
        _expect("guardian unpaused -> grant allowed", _probeFresh(false), bytes4(0));
    }

    // ---------------------------------------------------------------- ENS role revocation

    function revoke() external {
        _init();
        vm.broadcast(_deployerPk()); // DAO admin holds only ROLE_SET_TEXT_ADMIN: it can revoke, not approve
        _daoResolver().revokeRoles(uint256(keccak256("nidhi.role.approver")), ROLE_TEXT, _approver());
        _expect("approver role revoked in ENS -> grant blocked", _probeFresh(false), NidhiHook.NotAuthorized.selector);
    }

    function regrant() external {
        _init();
        string memory label = vm.parseJsonString(vm.readFile(ENS_JSON), ".label");
        vm.broadcast(_deployerPk());
        _daoResolver()
            .grantSetterRoles(
                abi.encodeCall(IPermissionedResolver.setText, (_dnsName(label), "nidhi.role.approver", "")), _approver()
            );
        _expect("approver role restored -> grant allowed", _probeFresh(false), bytes4(0));
    }

    // ---------------------------------------------------------------- tampering and cancellation

    function tamper() external {
        _init();
        _expect("recipient swapped after signing -> blocked", _probeFresh(true), NidhiHook.BadSignature.selector);
    }

    function cancel() external {
        _init();
        (Mandate memory m, Attestation memory a) = _fresh();
        address approver = _approver();
        _fund(approver);
        vm.broadcast(vm.envUint("APPROVER_PRIVATE_KEY"));
        hook.cancelGrant(m.grantId);
        _expect(
            "cancelled grant -> execution blocked", _simulate(m, _hookData(m, a)), NidhiHook.GrantAlreadyUsed.selector
        );
    }

    function probe() external {
        _init();
        _expect("dry-run of a valid grant", _probeFresh(false), bytes4(0));
    }

    // ---------------------------------------------------------------- batch payout (real)

    function batch() external {
        NidhiDispatcher dispatcher = _init();
        uint256 pk = _deployerPk();
        SwapParams[] memory ps = new SwapParams[](2);
        bytes[] memory hs = new bytes[](2);
        bytes32[] memory ids = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            (Mandate memory m, Attestation memory a) = _freshSalted(i);
            ids[i] = m.grantId;
            ps[i] = SwapParams(true, -int256(uint256(m.amountIn)), TickMath.MIN_SQRT_PRICE + 1);
            hs[i] = _hookData(m, a);
        }
        vm.startBroadcast(pk);
        IWETH9Demo(SEP_WETH).deposit{value: 2 * SCENARIO_AMOUNT}();
        IWETH9Demo(SEP_WETH).approve(address(router), 2 * SCENARIO_AMOUNT);
        router.swapBatch(key, ps, hs, block.timestamp + 300);
        vm.stopBroadcast();
        for (uint256 i; i < 2; ++i) {
            console2.log("batch grant dispatched; CCIP message:");
            console2.logBytes32(dispatcher.getGrant(ids[i]).messageId);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _fresh() internal returns (Mandate memory m, Attestation memory a) {
        return _freshSalted(99);
    }

    function _freshSalted(uint256 salt) internal returns (Mandate memory m, Attestation memory a) {
        bytes32 grantId = keccak256(abi.encode("nidhi-scenario", block.timestamp, salt));
        a = Attestation(
            grantId,
            keccak256(abi.encode("scenario-evidence", grantId)),
            keccak256("in"),
            keccak256("rubric"),
            uint64(block.timestamp)
        );
        uint128 prior = salt < 99 ? uint128(salt) * SCENARIO_AMOUNT : 0; // position within a batch
        m = _mandateAt(a, vm.addr(_deployerPk()), _resolveGrantee(), SCENARIO_AMOUNT, prior);
    }

    function _probeFresh(bool tamperRecipient) internal returns (bytes memory) {
        (Mandate memory m, Attestation memory a) = _fresh();
        bytes memory hd = _hookData(m, a);
        if (tamperRecipient) {
            NidhiHook.GrantAuth memory g = abi.decode(hd, (NidhiHook.GrantAuth));
            g.mandate.recipient = address(0xBEEF);
            hd = abi.encode(g);
        }
        return _simulate(m, hd);
    }

    /// Simulate the executor submitting the grant against live state. Not broadcast.
    function _simulate(Mandate memory m, bytes memory hd) internal returns (bytes memory err) {
        address executor = vm.addr(_deployerPk());
        vm.deal(executor, executor.balance + 1 ether);
        vm.startPrank(executor);
        IWETH9Demo(SEP_WETH).deposit{value: m.amountIn}();
        IWETH9Demo(SEP_WETH).approve(address(router), m.amountIn);
        try router.swap(
            key, SwapParams(true, -int256(uint256(m.amountIn)), TickMath.MIN_SQRT_PRICE + 1), hd, block.timestamp + 300
        ) {
            err = "";
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    /// Unwrap v4's WrappedError(hook, callback, reason, details) and compare the hook's own error selector.
    function _expect(string memory what, bytes memory err, bytes4 expected) internal pure {
        bytes4 got;
        if (err.length >= 4) {
            got = bytes4(err);
            if (got == CustomRevert.WrappedError.selector) {
                bytes memory body = new bytes(err.length - 4);
                for (uint256 i; i < body.length; ++i) {
                    body[i] = err[i + 4];
                }
                (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
                got = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            }
        }
        require(got == expected, string.concat("UNEXPECTED: ", what));
        console2.log(string.concat("OK  ", what));
    }

    function _fund(address who) internal {
        if (who.balance < 0.0002 ether) {
            vm.broadcast(_deployerPk());
            payable(who).transfer(0.0005 ether);
        }
    }

    function _approver() internal view returns (address) {
        return vm.addr(vm.envUint("APPROVER_PRIVATE_KEY"));
    }

    function _daoResolver() internal view returns (IPermissionedResolver) {
        return IPermissionedResolver(vm.parseJsonAddress(vm.readFile(ENS_JSON), ".resolver"));
    }
}
