// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ENSv2Authority, IENSv2Registry} from "../../src/ENSv2Authority.sol";
import {MockEAC} from "../mocks/MockEAC.sol";
import {MockENSv2Registry} from "../mocks/MockENSv2Registry.sol";

contract ENSv2AuthorityTest is Test {
    MockEAC eac;
    MockENSv2Registry registry;
    ENSv2Authority auth;
    uint256 constant SET_TEXT = 1 << 4;
    uint256 constant APPROVER_RES = uint256(keccak256("nidhi.role.approver"));
    uint256 constant AUDITOR_RES = uint256(keccak256("nidhi.role.auditor"));
    address op = address(0xA1);
    address ai = address(0xA2);

    function setUp() public {
        eac = new MockEAC();
        registry = new MockENSv2Registry();
        registry.set("nidhi-dao", address(eac), uint64(block.timestamp + 365 days));
        auth = new ENSv2Authority(IENSv2Registry(address(registry)), "nidhi-dao", 0x80000000 | 84532);
    }

    function test_resourceMatchesPermissionedResolverLib() public view {
        assertEq(auth.resourceOf(auth.APPROVER()), APPROVER_RES);
        assertEq(auth.resourceOf(auth.AUDITOR()), AUDITOR_RES);
        assertEq(auth.resourceOf(keccak256("other")), 0);
    }

    function test_keyScopedGrantAuthorizesOnlyThatRole() public {
        eac.grant(APPROVER_RES, SET_TEXT, op);
        assertTrue(auth.isAuthorized(auth.APPROVER(), op));
        assertFalse(auth.isAuthorized(auth.AUDITOR(), op));
    }

    function test_rootGrantCoversEveryRole() public {
        eac.grant(0, SET_TEXT, op);
        assertTrue(auth.isAuthorized(auth.APPROVER(), op));
        assertTrue(auth.isAuthorized(auth.AUDITOR(), op));
    }

    function test_revokeBlocksImmediately() public {
        eac.grant(APPROVER_RES, SET_TEXT, op);
        assertTrue(auth.isAuthorized(auth.APPROVER(), op));
        eac.revoke(APPROVER_RES, SET_TEXT, op);
        assertFalse(auth.isAuthorized(auth.APPROVER(), op));
    }

    function test_adminBitAloneDoesNotAuthorize() public {
        eac.grant(0, SET_TEXT << 128, op); // ROLE_SET_TEXT_ADMIN: may delegate, may not approve
        assertFalse(auth.isAuthorized(auth.APPROVER(), op));
    }

    function test_wrongBitOrUnknownRoleDoesNotAuthorize() public {
        eac.grant(APPROVER_RES, 1 << 0, ai); // ROLE_SET_ADDRESS
        assertFalse(auth.isAuthorized(auth.APPROVER(), ai));
        eac.grant(APPROVER_RES, SET_TEXT, ai);
        assertFalse(auth.isAuthorized(keccak256("something.else"), ai));
    }

    function test_nameExpiryFreezesAllPayouts() public {
        eac.grant(APPROVER_RES, SET_TEXT, op);
        assertTrue(auth.isAuthorized(auth.APPROVER(), op));
        vm.warp(block.timestamp + 366 days);
        assertEq(auth.currentResolver(), address(0));
        assertFalse(auth.isAuthorized(auth.APPROVER(), op), "fail closed when the DAO name lapses");
    }

    function test_permissionsFollowTheNamesResolver() public {
        eac.grant(APPROVER_RES, SET_TEXT, op);
        MockEAC newResolver = new MockEAC();
        newResolver.grant(APPROVER_RES, SET_TEXT, ai);
        registry.set("nidhi-dao", address(newResolver), uint64(block.timestamp + 365 days));
        assertFalse(auth.isAuthorized(auth.APPROVER(), op), "old resolver's grants no longer count");
        assertTrue(auth.isAuthorized(auth.APPROVER(), ai), "new resolver is authoritative");
    }

    function test_constructorRejectsBadConfig() public {
        vm.expectRevert(ENSv2Authority.BadConfig.selector);
        new ENSv2Authority(IENSv2Registry(address(0)), "nidhi-dao", 1);
        vm.expectRevert(ENSv2Authority.BadConfig.selector);
        new ENSv2Authority(IENSv2Registry(address(registry)), "", 1);
    }
}
