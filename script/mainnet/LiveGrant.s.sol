// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {NidhiHook} from "../../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {Mandate, Attestation} from "../../src/libraries/Mandate.sol";

interface IWrapped {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Send ONE real grant on the current chain, to another chain, through the live hook:
///   forge script script/mainnet/LiveGrant.s.sol --rpc-url <source chain> --broadcast
///
/// env: REGISTRY, DEST_CHAIN (chain id), GRANT_LABEL (default "alice"), GRANTEE (payee on the destination chain),
///      AMOUNT_IN_WEI (default 0.0003 ether), EVIDENCE_HASH (from `node offchain/src/audit.ts`),
///      MAINNET_DEPLOYER_PRIVATE_KEY (the executor), MAINNET_APPROVER_PRIVATE_KEY, MAINNET_AUDITOR_PRIVATE_KEY.
/// The grantee label must already be registered on the source chain's RoleAuthority (admin transaction).
contract LiveGrant is Script {
    struct Ctx {
        string reg;
        string dep;
        uint256 destId;
        NidhiHook hook;
        NidhiSwapRouter router;
        PoolKey key;
        address base;
        address payout;
        uint64 destSelector;
        address destReceiver;
        uint128 amountIn;
        string label;
        address grantee;
    }

    function run() external {
        Ctx memory c = _ctx();
        uint256 pk = vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY");
        address executor = vm.addr(pk);
        bool zeroForOne = c.base < c.payout;

        Mandate memory m = _mandate(c, executor, zeroForOne);
        bytes memory hookData = _hookData(c, m);

        vm.startBroadcast(pk);
        if (IWrapped(c.base).balanceOf(executor) < c.amountIn) IWrapped(c.base).deposit{value: c.amountIn}();
        IWrapped(c.base).approve(address(c.router), c.amountIn);
        c.router.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(c.amountIn)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData,
            block.timestamp + 600
        );
        vm.stopBroadcast();

        console2.log("grantId");
        console2.logBytes32(m.grantId);
        console2.log("source chain", block.chainid);
        console2.log("dest chain", c.destId);
        console2.log("grantee", c.grantee);
    }

    function _ctx() internal view returns (Ctx memory c) {
        c.reg = vm.readFile(vm.envOr("REGISTRY", string("chains/registry.json")));
        c.dep = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        c.destId = vm.envUint("DEST_CHAIN");
        string memory rk = string.concat(".chains.", vm.toString(block.chainid));
        string memory dk = string.concat(".chains.", vm.toString(c.destId));
        c.hook = NidhiHook(vm.parseJsonAddress(c.dep, ".hook"));
        c.router = NidhiSwapRouter(vm.parseJsonAddress(c.dep, ".router"));
        c.base = vm.parseJsonAddress(c.reg, string.concat(rk, ".wrappedNative.address"));
        c.payout = vm.parseJsonAddress(c.reg, string.concat(rk, ".payoutToken.address"));
        c.destSelector = uint64(vm.parseUint(vm.parseJsonString(c.reg, string.concat(dk, ".ccip.selector"))));
        c.destReceiver = vm.parseJsonAddress(vm.readFile(string.concat("deployments/", vm.toString(c.destId), ".json")), ".receiver");
        c.amountIn = uint128(vm.envOr("AMOUNT_IN_WEI", uint256(0.0003 ether)));
        c.label = vm.envOr("GRANT_LABEL", string("alice"));
        c.grantee = vm.envAddress("GRANTEE");
        (address t0, address t1) = c.base < c.payout ? (c.base, c.payout) : (c.payout, c.base);
        c.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(address(c.hook)));
    }

    function _mandate(Ctx memory c, address executor, bool zeroForOne) internal view returns (Mandate memory m) {
        // the pool opens near 1 WETH = ~1000 payout tokens (testnets); accept a wide, bounded band around that
        zeroForOne; // direction does not change the band: it is expressed in payout-token units
        m = Mandate({
            grantId: keccak256(abi.encode("nidhi-live", block.chainid, c.destId, block.timestamp, c.label)),
            executor: executor,
            recipient: c.grantee,
            tokenIn: c.base,
            tokenOut: c.payout,
            amountIn: c.amountIn,
            minOut: uint128(uint256(c.amountIn) * 500),
            maxOut: uint128(uint256(c.amountIn) * 1500),
            destChainSelector: c.destSelector,
            destReceiver: c.destReceiver,
            evidenceHash: vm.envOr("EVIDENCE_HASH", keccak256("nidhi-live-evidence")),
            deadline: uint64(block.timestamp + 1 hours),
            poolId: keccak256(abi.encode(c.key)),
            recipientLabelHash: keccak256(bytes(c.label))
        });
    }

    function _hookData(Ctx memory c, Mandate memory m) internal view returns (bytes memory) {
        uint256 apPk = vm.envUint("MAINNET_APPROVER_PRIVATE_KEY");
        uint256 auPk = vm.envUint("MAINNET_AUDITOR_PRIVATE_KEY");
        Attestation memory a = Attestation({
            grantId: m.grantId,
            evidenceHash: m.evidenceHash,
            inputsHash: keccak256("nidhi-live-inputs"),
            rubricHash: keccak256("nidhi-live-rubric"),
            issuedAt: uint64(block.timestamp)
        });
        NidhiHook.GrantAuth memory g = NidhiHook.GrantAuth({
            mandate: m,
            approver: vm.addr(apPk),
            approverSig: _sign(apPk, c.hook.mandateDigest(m)),
            attestation: a,
            auditor: vm.addr(auPk),
            auditorSig: _sign(auPk, c.hook.attestationDigest(a)),
            recipientLabel: c.label
        });
        return abi.encode(g);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
