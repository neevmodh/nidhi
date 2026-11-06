// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";

/// @notice Routes for the ENS-gated Sepolia stack. Routes are add-only, so the existing receivers on Base and Arbitrum
/// keep serving the RoleAuthority stack, and the ENS stack gets its own receivers:
///   on Base Sepolia / Arbitrum Sepolia:  deploy a receiver that accepts ONLY the ENS dispatcher, fund its ACK fees
///   on Sepolia:                          ENS dispatcher.addDestination(base|arb, that receiver)
/// Run on the destinations first, then on Sepolia. Reads deployments/ens-v4-stack.json; writes ens-v4-receiver-<id>.json.
contract EnsRoutes is Script {
    uint64 constant SEPOLIA_SEL = 16015286601757825753;
    uint64 constant BASE_SEL = 10344971235874465080;
    uint64 constant ARB_SEL = 3478487238524512106;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory stack = vm.readFile("deployments/ens-v4-stack.json");
        address dispatcher = vm.parseJsonAddress(stack, ".dispatcher");
        string memory reg = vm.readFile("chains/testnets.json");

        if (block.chainid == 11155111) {
            vm.startBroadcast(pk);
            _add(dispatcher, BASE_SEL, 84532);
            _add(dispatcher, ARB_SEL, 421614);
            vm.stopBroadcast();
            return;
        }
        require(block.chainid == 84532 || block.chainid == 421614, "run on Sepolia, Base Sepolia or Arbitrum Sepolia");
        string memory k = string.concat(".chains.", vm.toString(block.chainid));
        address router = vm.parseJsonAddress(reg, string.concat(k, ".ccip.router"));
        address payout = vm.parseJsonAddress(reg, string.concat(k, ".payoutToken.address"));

        vm.startBroadcast(pk);
        DestinationReceiver rx = new DestinationReceiver(router, address(0), deployer);
        rx.allowToken(payout);
        rx.addSource(SEPOLIA_SEL, dispatcher);
        payable(address(rx)).transfer(vm.envOr("ACK_RESERVE_WEI", uint256(0.0015 ether)));
        vm.stopBroadcast();

        string memory o = "rx";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "sourceDispatcher", dispatcher);
        string memory json = vm.serializeAddress(o, "receiver", address(rx));
        vm.writeJson(json, string.concat("deployments/ens-v4-receiver-", vm.toString(block.chainid), ".json"));
        console2.log("ENS-stack receiver", address(rx));
    }

    function _add(address dispatcher, uint64 sel, uint256 id) internal {
        address rx = vm.parseJsonAddress(
            vm.readFile(string.concat("deployments/ens-v4-receiver-", vm.toString(id), ".json")), ".receiver"
        );
        if (NidhiDispatcher(payable(dispatcher)).destReceivers(sel) == address(0)) {
            NidhiDispatcher(payable(dispatcher)).addDestination(sel, rx);
            console2.log("route added to", id);
        }
    }
}
