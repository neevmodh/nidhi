// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {IVerifiableFactory, IPermissionedResolver, IUserRegistry, IETHRegistryV2} from "./ens/IENSv2.sol";
import {ENSv2Authority, IENSv2Registry} from "../src/ENSv2Authority.sol";

/// @notice Step 6 (Sepolia), v3: ENS-native identities under nidhi-dao.eth.
///   - UserRegistry subregistry for the DAO name (real ENSv2 subnames).
///   - "grants resolver": a PermissionedResolver the DAO controls for subname records.
///   - <GRANTEE_LABEL>.nidhi-dao.eth -> grantee wallet on Base Sepolia (ENSIP-11 coin type). Grants pay this name.
///   - auditor.nidhi-dao.eth          -> the AI auditor key; it may write ONLY the "nidhi.attestation" text record.
/// GRANTEE_LABEL=alice GRANTEE_ADDRESS=0x... forge script script/06_EnsSubnames.s.sol --rpc-url sepolia --broadcast
contract EnsSubnames is NidhiScript {
    // RegistryRolesLib
    uint256 constant ROLE_REGISTRAR = 1 << 0;
    uint256 constant ROLE_SET_RESOLVER = 1 << 24;
    // PermissionedResolverLib
    uint256 constant ROLE_SET_ADDRESS = 1 << 0;

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address dao = vm.addr(pk);
        address auditor = vm.addr(vm.envUint("AUDITOR_PRIVATE_KEY"));
        string memory label = vm.parseJsonString(vm.readFile(ENS_JSON), ".label");
        string memory grantee = vm.envOr("GRANTEE_LABEL", string("alice"));
        address granteeWallet = vm.envAddress("GRANTEE_ADDRESS");
        uint64 expiry = uint64(block.timestamp + 180 days);

        IUserRegistry.Grant[] memory rg = new IUserRegistry.Grant[](1);
        rg[0] = IUserRegistry.Grant(
            dao, ROLE_REGISTRAR | (ROLE_REGISTRAR << 128) | ROLE_SET_RESOLVER | (ROLE_SET_RESOLVER << 128)
        );
        IPermissionedResolver.Grant[] memory g = new IPermissionedResolver.Grant[](1);
        g[0] = IPermissionedResolver.Grant(dao, ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << 128) | (ROLE_SET_TEXT << 128));

        vm.startBroadcast(pk);
        address sub = IETHRegistryV2(ENS_ETH_REGISTRY).getSubregistry(label);
        if (sub == address(0)) {
            sub = IVerifiableFactory(ENS_VERIFIABLE_FACTORY)
                .deployProxy(
                    ENS_USER_REGISTRY_IMPL,
                    uint256(keccak256(abi.encode("nidhi.sub", label, dao))),
                    abi.encodeCall(IUserRegistry.initialize, (rg))
                );
            IETHRegistryV2(ENS_ETH_REGISTRY).setSubregistry(uint256(keccak256(bytes(label))), sub);
        }
        address gres = IVerifiableFactory(ENS_VERIFIABLE_FACTORY)
            .deployProxy(
                ENS_RESOLVER_IMPL,
                uint256(keccak256(abi.encode("nidhi.grants", label, dao, block.timestamp))),
                abi.encodeCall(IPermissionedResolver.initialize, (g, new bytes[](0)))
            );

        IUserRegistry(sub).register(grantee, dao, address(0), gres, 0, expiry);
        IPermissionedResolver(gres)
            .setAddress(_dnsSubname(grantee, label), BASE_SEPOLIA_COIN_TYPE, abi.encodePacked(granteeWallet));

        IUserRegistry(sub).register("auditor", dao, address(0), gres, 0, expiry);
        IPermissionedResolver(gres).setAddress(_dnsSubname("auditor", label), 60, abi.encodePacked(auditor));
        IPermissionedResolver(gres)
            .grantSetterRoles(
                abi.encodeCall(IPermissionedResolver.setText, (_dnsSubname("auditor", label), "nidhi.attestation", "")),
                auditor
            );
        vm.stopBroadcast();

        // Post-condition through the exact resolution path the hook uses.
        ENSv2Authority probe = new ENSv2Authority(IENSv2Registry(ENS_ETH_REGISTRY), label, BASE_SEPOLIA_COIN_TYPE);
        require(probe.resolveGrantee(grantee) == granteeWallet, "grantee subname does not resolve");

        string memory o = "subnames";
        vm.serializeAddress(o, "subregistry", sub);
        vm.serializeAddress(o, "grantsResolver", gres);
        vm.serializeString(o, "grantee", string.concat(grantee, ".", label, ".eth"));
        vm.serializeAddress(o, "granteeWallet", granteeWallet);
        string memory json = vm.serializeString(o, "auditor", string.concat("auditor.", label, ".eth"));
        vm.writeJson(json, SUBNAMES_JSON);

        console2.log("Subregistry    :", sub);
        console2.log("Grants resolver:", gres);
        console2.log(string.concat(grantee, ".", label, ".eth -> "), granteeWallet);
        console2.log(string.concat("auditor.", label, ".eth -> "), auditor);
    }
}
