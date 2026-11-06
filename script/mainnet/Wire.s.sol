// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";

/// @notice PHASE 2 (run once per chain, AFTER Deploy has run on every chain you want connected):
///   forge script script/mainnet/Wire.s.sol --rpc-url <chain rpc> --broadcast --slow
///
/// For THIS chain X it reads chains/registry.json (payout lanes) and deployments/<id>.json of every deployed chain:
///   - dispatcher(X).addDestination(selector(Y), receiver(Y))   for every deployed Y that X can pay in USDC
///   - receiver(X).addSource(selector(Z), dispatcher(Z))        for every deployed Z that can pay X
/// Routes are add-only on-chain, so this is idempotent: existing routes are skipped, and chains that are not deployed
/// yet are skipped (run again after deploying them). Ownership is still the deployer's at this point; Handover follows.
contract Wire is Script {
    struct Me {
        uint256 id;
        string json;
        address dispatcher;
        address receiver;
    }

    function run() external {
        string memory reg = vm.readFile(vm.envOr("REGISTRY", string("chains/registry.json")));
        Me memory me;
        me.id = block.chainid;
        me.json = reg;
        string memory mine = vm.readFile(_dep(me.id));
        me.dispatcher = vm.parseJsonAddress(mine, ".dispatcher");
        me.receiver = vm.parseJsonAddress(mine, ".receiver");

        uint256 pk = vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY");
        uint256 added;

        vm.startBroadcast(pk);
        // outbound: where this chain can pay
        uint256[] memory out = vm.parseJsonUintArray(reg, string.concat(".chains.", vm.toString(me.id), ".payoutLanes"));
        for (uint256 i; i < out.length; ++i) {
            if (!vm.exists(_dep(out[i]))) continue; // not deployed yet
            uint64 sel = _selector(reg, out[i]);
            address rx = vm.parseJsonAddress(vm.readFile(_dep(out[i])), ".receiver");
            if (NidhiDispatcher(payable(me.dispatcher)).destReceivers(sel) == address(0)) {
                NidhiDispatcher(payable(me.dispatcher)).addDestination(sel, rx);
                ++added;
            }
        }
        // inbound: who can pay this chain
        uint256[] memory sources = vm.parseJsonUintArray(reg, ".sourceChains");
        for (uint256 i; i < sources.length; ++i) {
            if (sources[i] == me.id || !vm.exists(_dep(sources[i]))) continue;
            if (!_pays(reg, sources[i], me.id)) continue;
            uint64 sel = _selector(reg, sources[i]);
            address disp = vm.parseJsonAddress(vm.readFile(_dep(sources[i])), ".dispatcher");
            if (DestinationReceiver(payable(me.receiver)).sourceDispatchers(sel) == address(0)) {
                DestinationReceiver(payable(me.receiver)).addSource(sel, disp);
                ++added;
            }
        }
        vm.stopBroadcast();
        console2.log("chain", me.id);
        console2.log("routes added", added);
    }

    function _dep(uint256 id) internal pure returns (string memory) {
        return string.concat("deployments/", vm.toString(id), ".json");
    }

    function _selector(string memory reg, uint256 id) internal pure returns (uint64) {
        return
            uint64(vm.parseUint(vm.parseJsonString(reg, string.concat(".chains.", vm.toString(id), ".ccip.selector"))));
    }

    function _pays(string memory reg, uint256 from, uint256 to) internal pure returns (bool) {
        uint256[] memory lanes =
            vm.parseJsonUintArray(reg, string.concat(".chains.", vm.toString(from), ".payoutLanes"));
        for (uint256 i; i < lanes.length; ++i) {
            if (lanes[i] == to) return true;
        }
        return false;
    }
}
