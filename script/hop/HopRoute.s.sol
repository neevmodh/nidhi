// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {NidhiHopRelay} from "../../src/NidhiHopRelay.sol";

/// @notice A two-hop CCIP route for grants between chains with no direct lane:
///   SOURCE (hop stack dispatcher) --lane--> VIA (NidhiHopRelay) --lane--> FINAL (DestinationReceiver) --> grantee
/// Defaults: Base Sepolia -> Arbitrum Sepolia -> Unichain Sepolia (Base and Unichain share no CCIP lane).
/// Run per chain, in this order (each step is idempotent):
///   STEP=relay    on VIA:    deploy the relay, allow the payout token, accept the source dispatcher, fund fees
///   STEP=receiver on FINAL:  deploy a receiver that accepts only the relay, fund its ACK fees
///   STEP=onward   on VIA:    relay.setOnward(FINAL, receiver)
///   STEP=source   on SOURCE: hop dispatcher.addDestination(VIA, relay)
/// Reads deployments/hop-v4-stack.json (the source stack); writes deployments/hop-v4-route.json.
contract HopRoute is Script {
    string constant ROUTE = "deployments/hop-v4-route.json";

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory reg = vm.readFile("chains/testnets.json");
        uint256 sourceId = vm.envOr("HOP_SOURCE", uint256(84532));
        uint256 viaId = vm.envOr("HOP_VIA", uint256(421614));
        uint256 finalId = vm.envOr("HOP_FINAL", uint256(1301));
        string memory step = vm.envString("STEP");
        address dispatcher = vm.parseJsonAddress(vm.readFile("deployments/hop-v4-stack.json"), ".dispatcher");

        vm.startBroadcast(pk);
        if (_eq(step, "relay")) {
            require(block.chainid == viaId, "run STEP=relay on the via chain");
            NidhiHopRelay relay = new NidhiHopRelay(_router(reg, viaId), deployer);
            relay.allowToken(_payout(reg, viaId));
            relay.addUpstream(_sel(reg, sourceId), dispatcher);
            payable(address(relay)).transfer(vm.envOr("RELAY_RESERVE_WEI", uint256(0.003 ether)));
            vm.stopBroadcast();
            _save("relay", address(relay), sourceId, viaId, finalId);
            console2.log("relay", address(relay));
            return;
        }
        string memory route = vm.readFile(ROUTE);
        address relayAddr = vm.parseJsonAddress(route, ".relay");
        if (_eq(step, "receiver")) {
            require(block.chainid == finalId, "run STEP=receiver on the final chain");
            DestinationReceiver rx = new DestinationReceiver(_router(reg, finalId), address(0), deployer);
            rx.allowToken(_payout(reg, finalId));
            rx.addSource(_sel(reg, viaId), relayAddr);
            // its ACK lands in the relay, which forwards it with a ccipSend inside try/catch: give it room
            rx.setAckGasLimit(1_500_000);
            payable(address(rx)).transfer(vm.envOr("ACK_RESERVE_WEI", uint256(0.0015 ether)));
            vm.stopBroadcast();
            vm.writeJson(vm.toString(address(rx)), ROUTE, ".finalReceiver");
            console2.log("final receiver", address(rx));
        } else if (_eq(step, "onward")) {
            require(block.chainid == viaId, "run STEP=onward on the via chain");
            NidhiHopRelay relay = NidhiHopRelay(payable(relayAddr));
            if (relay.onwardReceiver() == address(0)) relay.setOnward(_sel(reg, finalId), vm.parseJsonAddress(route, ".finalReceiver"));
            vm.stopBroadcast();
            console2.log("relay forwards to", relay.onwardReceiver());
        } else if (_eq(step, "source")) {
            require(block.chainid == sourceId, "run STEP=source on the source chain");
            uint64 via = _sel(reg, viaId);
            if (NidhiDispatcher(payable(dispatcher)).destReceivers(via) == address(0)) NidhiDispatcher(payable(dispatcher)).addDestination(via, relayAddr);
            // the relay forwards with a ccipSend inside try/catch on delivery: 600k is not enough for CCIP 2.0 onramps
            if (NidhiDispatcher(payable(dispatcher)).destGasLimit() < 2_000_000) NidhiDispatcher(payable(dispatcher)).setDestGasLimit(2_000_000);
            vm.stopBroadcast();
            console2.log("source routes via the relay", relayAddr);
        } else {
            revert("STEP must be relay | receiver | onward | source");
        }
    }

    function _save(string memory k, address a, uint256 s, uint256 v, uint256 f) internal {
        string memory o = "route";
        vm.serializeUint(o, "source", s);
        vm.serializeUint(o, "via", v);
        vm.serializeUint(o, "final", f);
        vm.serializeAddress(o, "finalReceiver", address(0));
        string memory json = vm.serializeAddress(o, k, a);
        vm.writeJson(json, ROUTE);
    }

    function _router(string memory reg, uint256 id) internal pure returns (address) {
        return vm.parseJsonAddress(reg, string.concat(".chains.", vm.toString(id), ".ccip.router"));
    }

    function _payout(string memory reg, uint256 id) internal pure returns (address) {
        return vm.parseJsonAddress(reg, string.concat(".chains.", vm.toString(id), ".payoutToken.address"));
    }

    function _sel(string memory reg, uint256 id) internal pure returns (uint64) {
        return uint64(vm.parseUint(vm.parseJsonString(reg, string.concat(".chains.", vm.toString(id), ".ccip.selector"))));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
