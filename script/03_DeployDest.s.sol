// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {DestinationReceiver} from "../src/DestinationReceiver.sol";

/// @notice Step 3 (Base Sepolia): deploy the DestinationReceiver, bind it to the Sepolia dispatcher, and fund a
///         native-ETH reserve for ACK fees (CCIP fees on the return lane are paid in native gas).
/// forge script script/03_DeployDest.s.sol --rpc-url base_sepolia --broadcast
contract DeployDest is NidhiScript {
    function run() external {
        _requireChain(84532);
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);
        address dispatcher = _readAddress(SEP_JSON, ".dispatcher");
        uint256 ackReserve = vm.envOr("ACK_FEE_RESERVE", uint256(0.003 ether));

        vm.startBroadcast(pk);
        DestinationReceiver receiver = new DestinationReceiver(BASE_CCIP_ROUTER, SEP_SELECTOR, BASE_BNM, address(0), deployer);
        receiver.setSourceDispatcher(dispatcher);
        (bool ok,) = address(receiver).call{value: ackReserve}("");
        require(ok, "fund ACK reserve");
        vm.stopBroadcast();

        string memory o = "base";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "receiver", address(receiver));
        vm.serializeAddress(o, "sourceDispatcher", dispatcher);
        string memory json = vm.serializeAddress(o, "token", BASE_BNM);
        vm.writeJson(json, BASE_JSON);

        console2.log("DestinationReceiver:", address(receiver));
        console2.log("ACK reserve (wei)  :", ackReserve);
    }
}
