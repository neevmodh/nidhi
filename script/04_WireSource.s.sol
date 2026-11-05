// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";

/// @notice Step 4 (Sepolia): point the dispatcher at the Base Sepolia receiver (one-time, irreversible).
/// forge script script/04_WireSource.s.sol --rpc-url sepolia --broadcast
contract WireSource is NidhiScript {
    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        NidhiDispatcher dispatcher = NidhiDispatcher(payable(_readAddress(SEP_JSON, ".dispatcher")));
        address receiver = _readAddress(BASE_JSON, ".receiver");

        vm.startBroadcast(pk);
        dispatcher.setDestReceiver(receiver);
        vm.stopBroadcast();

        console2.log("Dispatcher", address(dispatcher), "-> receiver", receiver);
    }
}
