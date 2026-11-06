// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";

interface INft {
    function transferFrom(address from, address to, uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
}

/// @notice PHASE 3 (per chain, after Wire): hand control to the DAO admin (MAINNET_ADMIN).
///   forge script script/mainnet/Handover.s.sol --rpc-url <chain rpc> --broadcast --slow
///   - dispatcher and receiver: Ownable2Step.transferOwnership(admin). The admin must then call acceptOwnership().
///   - the liquidity NFT (PositionManager) is transferred to the admin outright.
///   - RoleAuthority admin was already handed over in Deploy (the deployer renounced).
/// After this the deployer key holds no authority anywhere and can be discarded.
contract Handover is Script {
    function run() external {
        uint256 id = block.chainid;
        string memory dep = vm.readFile(string.concat("deployments/", vm.toString(id), ".json"));
        string memory reg = vm.readFile(vm.envOr("REGISTRY", string("chains/registry.json")));
        address admin = vm.envAddress("MAINNET_ADMIN");
        require(admin == vm.parseJsonAddress(dep, ".admin"), "MAINNET_ADMIN differs from the admin recorded at deploy time");

        address dispatcher = vm.parseJsonAddress(dep, ".dispatcher");
        address receiver = vm.parseJsonAddress(dep, ".receiver");
        address posm = vm.parseJsonAddress(reg, string.concat(".chains.", vm.toString(id), ".uniswap.positionManager"));
        uint256 tokenId = vm.parseJsonUint(dep, ".positionId");

        vm.startBroadcast(vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY"));
        if (NidhiDispatcher(payable(dispatcher)).owner() != admin && NidhiDispatcher(payable(dispatcher)).pendingOwner() != admin) {
            NidhiDispatcher(payable(dispatcher)).transferOwnership(admin);
        }
        if (DestinationReceiver(payable(receiver)).owner() != admin && DestinationReceiver(payable(receiver)).pendingOwner() != admin) {
            DestinationReceiver(payable(receiver)).transferOwnership(admin);
        }
        if (INft(posm).ownerOf(tokenId) != admin) INft(posm).transferFrom(vm.addr(vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY")), admin, tokenId);
        vm.stopBroadcast();

        console2.log("chain", id);
        console2.log("admin must now call acceptOwnership() on:");
        console2.log("  dispatcher", dispatcher);
        console2.log("  receiver  ", receiver);
    }
}
