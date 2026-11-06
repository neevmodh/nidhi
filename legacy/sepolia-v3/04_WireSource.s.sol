// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";
import {IPermissionedResolver} from "./ens/IENSv2.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";

/// @notice Step 4 (Sepolia): point the dispatcher at the Base Sepolia receiver (one-time, irreversible) and publish
///         the receiver address as the "nidhi.contract.receiver" text record on the DAO name.
/// forge script script/04_WireSource.s.sol --rpc-url sepolia --broadcast
contract WireSource is NidhiScript {
    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        NidhiDispatcher dispatcher = NidhiDispatcher(payable(_readAddress(SEP_JSON, ".dispatcher")));
        address receiver = _readAddress(BASE_JSON, ".receiver");
        string memory label = vm.parseJsonString(vm.readFile(ENS_JSON), ".label");
        IPermissionedResolver r = IPermissionedResolver(vm.parseJsonAddress(vm.readFile(ENS_JSON), ".resolver"));
        bytes memory dns = _dnsName(label);

        vm.startBroadcast(pk);
        dispatcher.setDestReceiver(receiver);
        r.grantSetterRoles(
            abi.encodeCall(IPermissionedResolver.setText, (dns, "nidhi.contract.receiver", "")), vm.addr(pk)
        );
        r.setText(dns, "nidhi.contract.receiver", vm.toString(receiver));
        vm.stopBroadcast();

        console2.log("Dispatcher", address(dispatcher), "-> receiver", receiver);
    }
}
