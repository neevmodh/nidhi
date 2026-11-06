// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {NidhiScript} from "./NidhiScript.sol";

interface IFeeWithdrawV3 {
    function withdrawFees(address to, uint256 amount) external;
}

interface IBalV3 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Retire a v3 deployment before redeploying (the hook is immutable). Reads the CURRENT deployments/*.json.
///   Sepolia      : burn the DAO's PositionManager LP NFT (liquidity -> deployer) and withdraw the dispatcher's LINK.
///   Base Sepolia : withdraw the receiver's native ACK-fee reserve.
/// forge script script/10_MigrateFromV3.s.sol --rpc-url sepolia --broadcast
/// forge script script/10_MigrateFromV3.s.sol --rpc-url base_sepolia --broadcast
contract MigrateFromV3 is NidhiScript {
    function run() external {
        uint256 pk = _deployerPk();
        address deployer = vm.addr(pk);

        if (block.chainid == 11155111) {
            string memory sj = vm.readFile(SEP_JSON);
            uint256 tokenId = vm.parseJsonUint(sj, ".positionId");
            address dispatcher = vm.parseJsonAddress(sj, ".dispatcher");
            PoolKey memory key = PoolKey(
                Currency.wrap(SEP_WETH), Currency.wrap(SEP_BNM), 3000, 60, IHooks(vm.parseJsonAddress(sj, ".hook"))
            );
            uint256 link = IBalV3(SEP_LINK).balanceOf(dispatcher);

            bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1, deployer);

            vm.startBroadcast(pk);
            IPositionManager(SEP_POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
            if (link > 0) IFeeWithdrawV3(dispatcher).withdrawFees(deployer, link);
            vm.stopBroadcast();
            console2.log("burned LP NFT        :", tokenId);
            console2.log("LINK recovered       :", link);
            console2.log("deployer WETH / BnM  :", IBalV3(SEP_WETH).balanceOf(deployer), IBalV3(SEP_BNM).balanceOf(deployer));
        } else if (block.chainid == 84532) {
            address receiver = vm.parseJsonAddress(vm.readFile(BASE_JSON), ".receiver");
            uint256 bal = receiver.balance;
            vm.startBroadcast(pk);
            if (bal > 0) IFeeWithdrawV3(receiver).withdrawFees(deployer, bal);
            vm.stopBroadcast();
            console2.log("receiver ETH recovered:", bal);
        } else {
            revert("run on sepolia or base_sepolia");
        }
    }
}
