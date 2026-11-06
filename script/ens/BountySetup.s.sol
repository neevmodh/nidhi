// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPermissionedResolver} from "../../test/interfaces/IENSv2.sol";
import {NidhiBountyBoard, IMandateDigest} from "../../src/NidhiBountyBoard.sol";
import {IGrantAuthority} from "../../src/interfaces/IGrantAuthority.sol";

/// @notice On-chain milestones for the ENS-gated Sepolia stack.
///   forge script script/ens/BountySetup.s.sol --rpc-url <sepolia> --broadcast --slow
///   - deploys NidhiBountyBoard on the ENS stack's hook and ENSv2Authority
///   - grants the board the approver role on nidhi-dao.eth (ENSv2 Enhanced Access Control): it can approve only
///     payouts that match a posted milestone
///   - grants APPROVER_WALLET (e.g. the DAO admin's MetaMask) the approver role, so it can post milestones from the app
/// Writes deployments/bounty-board.json. Run with PRIVATE_KEY = the account that administers nidhi-dao.eth's resolver.
contract BountySetup is Script {
    function run() external {
        require(block.chainid == 11155111, "ENSv2 lives on Sepolia");
        string memory stack = vm.readFile(vm.envOr("STACK", string("deployments/ens-v4-stack.json")));
        string memory ens = vm.readFile("deployments/sepolia-ens.json");
        address hook = vm.parseJsonAddress(stack, ".hook");
        address authority = vm.parseJsonAddress(stack, ".authority");
        address resolver = vm.parseJsonAddress(ens, ".resolver");
        string memory label = vm.parseJsonString(ens, ".label");
        address wallet = vm.envOr("APPROVER_WALLET", address(0));
        bytes memory setter = abi.encodeCall(IPermissionedResolver.setText, (_name(label), "nidhi.role.approver", ""));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        NidhiBountyBoard board = new NidhiBountyBoard(IMandateDigest(hook), IGrantAuthority(authority));
        IPermissionedResolver(resolver).grantSetterRoles(setter, address(board));
        if (wallet != address(0)) IPermissionedResolver(resolver).grantSetterRoles(setter, wallet);
        vm.stopBroadcast();

        IGrantAuthority a = IGrantAuthority(authority);
        require(a.isAuthorized(a.APPROVER(), address(board)), "board did not get the ENS approver role");
        if (wallet != address(0)) {
            require(a.isAuthorized(a.APPROVER(), wallet), "wallet did not get the ENS approver role");
        }

        string memory o = "board";
        vm.serializeAddress(o, "hook", hook);
        vm.serializeAddress(o, "authority", authority);
        vm.serializeUint(o, "deployBlock", block.number);
        string memory json = vm.serializeAddress(o, "board", address(board));
        vm.writeJson(json, "deployments/bounty-board.json");
        console2.log("bounty board", address(board));
        console2.log("approver wallet", wallet);
    }

    function _name(string memory label) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, uint8(3), "eth", uint8(0));
    }
}
