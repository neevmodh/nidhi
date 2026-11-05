// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {IVerifiableFactory, IPermissionedResolver, IETHRegistrar, IMockUSDC} from "./ens/IENSv2.sol";


/// @notice Step 0 (Sepolia): create the DAO's ENSv2 PermissionedResolver, delegate the two Nidhi roles via
///         Enhanced Access Control, and commit to registering "<ENS_LABEL>.eth".
///   The deployer receives ONLY ROLE_SET_TEXT_ADMIN: it can delegate/revoke Nidhi roles but cannot itself act
///   as an approver or auditor (separation of duties).
/// forge script script/00_EnsCommit.s.sol --rpc-url sepolia --broadcast
contract EnsCommit is NidhiScript {
    uint64 constant DURATION = 365 days;

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);
        address approver = vm.addr(vm.envUint("APPROVER_PRIVATE_KEY"));
        address auditor = vm.addr(vm.envUint("AUDITOR_PRIVATE_KEY"));
        string memory label = _label();
        bytes memory dns = _dnsName(label);
        IETHRegistrar registrar = IETHRegistrar(ENS_ETH_REGISTRAR);

        require(registrar.isAvailable(label), "ENS label not available; set ENS_LABEL");
        (uint256 base, uint256 premium) = registrar.getRegisterPrice(label, DURATION, ENS_MOCK_USDC);
        bytes32 secret = keccak256(abi.encode(vm.randomUint(), deployer, label));

        IPermissionedResolver.Grant[] memory grants = new IPermissionedResolver.Grant[](1);
        grants[0] = IPermissionedResolver.Grant({account: deployer, roleBitmap: ROLE_SET_TEXT_ADMIN});

        vm.startBroadcast(pk);
        IMockUSDC(ENS_MOCK_USDC).mint(deployer, base + premium);
        address resolver = IVerifiableFactory(ENS_VERIFIABLE_FACTORY).deployProxy(
            ENS_RESOLVER_IMPL,
            uint256(keccak256(abi.encode("nidhi", label, deployer))),
            abi.encodeCall(IPermissionedResolver.initialize, (grants, new bytes[](0)))
        );
        IPermissionedResolver(resolver).grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.role.approver", "")), approver
        );
        IPermissionedResolver(resolver).grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.role.auditor", "")), auditor
        );
        registrar.commit(registrar.makeCommitment(label, deployer, secret, address(0), resolver, DURATION, bytes32(0)));
        vm.stopBroadcast();

        // Post-conditions on the live resolver (same check ENSv2Authority performs once the name is registered).
        IPermissionedResolver r = IPermissionedResolver(resolver);
        require(r.hasRoles(APPROVER_RES, ROLE_SET_TEXT, approver), "approver role missing");
        require(r.hasRoles(AUDITOR_RES, ROLE_SET_TEXT, auditor), "auditor role missing");
        require(!r.hasRoles(APPROVER_RES, ROLE_SET_TEXT, deployer), "deployer must not hold the approver role");
        require(!r.hasRoles(APPROVER_RES, ROLE_SET_TEXT, auditor), "auditor must not be an approver");

        string memory o = "ens";
        vm.serializeString(o, "label", label);
        vm.serializeString(o, "name", string.concat(label, ".eth"));
        vm.serializeBytes32(o, "node", _namehash(label));
        vm.serializeAddress(o, "resolver", resolver);
        vm.serializeAddress(o, "approver", approver);
        vm.serializeAddress(o, "auditor", auditor);
        vm.serializeAddress(o, "admin", deployer);
        vm.serializeUint(o, "committedAt", block.timestamp);
        string memory json = vm.serializeBytes32(o, "secret", secret);
        vm.writeJson(json, ENS_JSON);

        console2.log("ENS name        :", string.concat(label, ".eth"));
        console2.log("Resolver (proxy):", resolver);
        console2.log("Approver role   :", approver);
        console2.log("Auditor role    :", auditor);
        console2.log("Price (MockUSDC):", base + premium);
        console2.log("Next: wait >= 60s, then run script/01_EnsRegister.s.sol");
    }
}
