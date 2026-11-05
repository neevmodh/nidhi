// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {NidhiScript} from "./NidhiScript.sol";

/// Chainlink AutomationRegistrar 2.3 (Base Sepolia 0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A).
interface IAutomationRegistrar2_3 {
    struct RegistrationParams {
        address upkeepContract;
        uint96 amount;
        address adminAddress;
        uint32 gasLimit;
        uint8 triggerType;
        address billingToken;
        string name;
        bytes encryptedEmail;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
    }

    function registerUpkeep(RegistrationParams calldata requestParams) external payable returns (uint256);
}

interface ILink {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 9 (Base Sepolia): register a Chainlink Automation (conditional) upkeep for the DestinationReceiver,
///         so stuck ACKs and held payouts are retried automatically. Funds the upkeep with UPKEEP_LINK (default 3).
/// forge script script/09_RegisterUpkeep.s.sol --rpc-url base_sepolia --broadcast
contract RegisterUpkeep is NidhiScript {
    function run() external {
        _requireChain(84532);
        uint256 pk = _deployerPk();
        address admin = vm.addr(pk);
        address receiver = _readAddress(BASE_JSON, ".receiver");
        uint96 amount = uint96(vm.envOr("UPKEEP_LINK", uint256(3 ether)));
        require(ILink(BASE_LINK).balanceOf(admin) >= amount, "need LINK on Base Sepolia for the upkeep");

        IAutomationRegistrar2_3.RegistrationParams memory p = IAutomationRegistrar2_3.RegistrationParams({
            upkeepContract: receiver,
            amount: amount,
            adminAddress: admin,
            gasLimit: 2_000_000,
            triggerType: 0, // conditional: checkUpkeep / performUpkeep
            billingToken: BASE_LINK,
            name: "nidhi-destination-receiver",
            encryptedEmail: "",
            checkData: "",
            triggerConfig: "",
            offchainConfig: ""
        });

        vm.startBroadcast(pk);
        ILink(BASE_LINK).approve(BASE_AUTOMATION_REGISTRAR, amount);
        uint256 upkeepId = IAutomationRegistrar2_3(BASE_AUTOMATION_REGISTRAR).registerUpkeep(p);
        vm.stopBroadcast();

        string memory json = vm.serializeUint("upkeep", "upkeepId", upkeepId);
        vm.writeJson(json, "deployments/base-sepolia-upkeep.json");
        console2.log("Automation upkeep id:", upkeepId);
        console2.log("Manage: https://automation.chain.link/base-sepolia/", vm.toString(upkeepId));
    }
}
