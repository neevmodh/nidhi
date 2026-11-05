// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {IETHRegistrar, IMockUSDC} from "./ens/IENSv2.sol";
import {ENSv2Authority, IENSv2Registry} from "../src/ENSv2Authority.sol";

/// @notice Step 1 (Sepolia, >= 60s after step 0): register "<label>.eth" on the ENSv2 ETHRegistrar with the
///         PermissionedResolver from step 0, so the DAO name resolves through the same contract that holds the roles.
/// forge script script/01_EnsRegister.s.sol --rpc-url sepolia --broadcast
contract EnsRegister is NidhiScript {
    uint64 constant DURATION = 365 days;

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);
        string memory json = vm.readFile(ENS_JSON);
        string memory label = vm.parseJsonString(json, ".label");
        address resolver = vm.parseJsonAddress(json, ".resolver");
        bytes32 secret = vm.parseJsonBytes32(json, ".secret");
        IETHRegistrar registrar = IETHRegistrar(ENS_ETH_REGISTRAR);

        (uint256 base, uint256 premium) = registrar.getRegisterPrice(label, DURATION, ENS_MOCK_USDC);

        vm.startBroadcast(pk);
        IMockUSDC(ENS_MOCK_USDC).approve(ENS_ETH_REGISTRAR, base + premium);
        uint256 tokenId =
            registrar.register(label, deployer, secret, address(0), resolver, DURATION, ENS_MOCK_USDC, bytes32(0));
        vm.stopBroadcast();

        // End-to-end check through the exact adapter the hook uses: name -> registry -> resolver -> EAC role.
        ENSv2Authority probe = new ENSv2Authority(IENSv2Registry(ENS_ETH_REGISTRY), label);
        require(probe.currentResolver() == resolver, "name does not resolve to the DAO resolver");
        require(probe.isAuthorized(probe.APPROVER(), vm.parseJsonAddress(json, ".approver")), "approver not authorized");
        require(probe.isAuthorized(probe.AUDITOR(), vm.parseJsonAddress(json, ".auditor")), "auditor not authorized");
        require(!probe.isAuthorized(probe.APPROVER(), deployer), "admin must not be an approver");

        console2.log("Registered      :", string.concat(label, ".eth"));
        console2.log("Token id        :", tokenId);
        console2.log("Resolver        :", resolver);
    }
}
