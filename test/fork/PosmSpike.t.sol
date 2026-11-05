// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Spike: seed liquidity through the LIVE v4 PositionManager (NFT owned by the DAO), not the test router.
contract PosmSpikeTest is Test {
    IPoolManager constant PM = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPositionManager constant POSM = IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function test_spike_posmMintOwnedByDao() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        address dao = makeAddr("dao");
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(address(0)));
        PM.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(dao, 10 ether);
        t1.mint(dao, 10 ether);
        vm.startPrank(dao);
        for (uint256 i; i < 2; ++i) {
            address t = i == 0 ? address(t0) : address(t1);
            MockERC20(t).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(t, address(POSM), type(uint160).max, uint48(block.timestamp + 1 hours));
        }
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-887220), int24(887220), uint256(1 ether), uint128(10 ether), uint128(10 ether), dao, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        uint256 id = POSM.nextTokenId();
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        vm.stopPrank();

        assertEq(POSM.getPositionLiquidity(id), 1 ether, "position minted");
        (bool ok, bytes memory r) = address(POSM).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        assertTrue(ok);
        assertEq(abi.decode(r, (address)), dao, "NFT owned by the DAO, not a shared router");
    }
}
