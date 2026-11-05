// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {NidhiScript} from "./NidhiScript.sol";
import {NidhiHook} from "../src/NidhiHook.sol";
import {NidhiSwapRouter} from "../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../src/NidhiDispatcher.sol";
import {Mandate, Attestation} from "../src/libraries/Mandate.sol";

interface IGranteeResolver {
    function resolveGrantee(string calldata label) external view returns (address);
}

interface IWETH9Demo {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 5 (Sepolia): pay one grant end to end.
///   - If offchain/out/attestation.json exists (written by `node offchain/src/audit.ts <grant>`), the grant id,
///     evidence hashes, recipient and amount all come from it - i.e. from the DAO's pre-committed grant table -
///     and the AI auditor's own signature is used. Otherwise a demo grant is built from env vars.
///   - The APPROVER signs the Mandate. The deployer is the executor that submits the swap.
///   - minOut/maxOut is a +/-1% band around an exact quote computed from live pool state with v4's SqrtPriceMath
///     (includes the 0.30% fee and price impact). The hook reverts the whole payout if output leaves the band.
/// forge script script/05_Demo.s.sol --rpc-url sepolia --broadcast
contract Demo is NidhiScript {
    using StateLibrary for IPoolManager;

    string constant ATTESTATION_JSON = "offchain/out/attestation.json";

    NidhiHook internal hook;
    NidhiSwapRouter internal router;
    PoolKey internal key;
    bytes32 internal poolId;

    function run() external {
        _requireChain(11155111);
        uint256 pk = _deployerPk();
        address executor = vm.addr(pk);

        NidhiDispatcher dispatcher = _init();

        (Attestation memory a, address recipient, uint128 amountIn) = _loadGrant();
        Mandate memory m = _mandate(a, executor, recipient, amountIn);
        bytes memory hookData = _hookData(m, a);

        vm.startBroadcast(pk);
        if (IWETH9Demo(SEP_WETH).balanceOf(executor) < amountIn) IWETH9Demo(SEP_WETH).deposit{value: amountIn}();
        IWETH9Demo(SEP_WETH).approve(address(router), amountIn);
        router.swap(
            key,
            SwapParams(true, -int256(uint256(amountIn)), TickMath.MIN_SQRT_PRICE + 1),
            hookData,
            block.timestamp + 300
        );
        vm.stopBroadcast();

        NidhiDispatcher.Grant memory g = dispatcher.getGrant(m.grantId);
        console2.log("Grant id        :");
        console2.logBytes32(m.grantId);
        console2.log("Recipient (Base):", recipient);
        console2.log("Amount bridged  :", g.amount);
        console2.log("CCIP message id :");
        console2.logBytes32(g.messageId);
        console2.log(string.concat("Track: https://ccip.chain.link/msg/", vm.toString(g.messageId)));
        console2.log("Ledger: cast call <dispatcher> 'statusOf(bytes32)(uint8)' <grantId>   (1 DISPATCHED, 3 SETTLED)");
    }

    function _init() internal returns (NidhiDispatcher dispatcher) {
        string memory sj = vm.readFile(SEP_JSON);
        hook = NidhiHook(vm.parseJsonAddress(sj, ".hook"));
        router = NidhiSwapRouter(vm.parseJsonAddress(sj, ".router"));
        poolId = vm.parseJsonBytes32(sj, ".poolId");
        dispatcher = NidhiDispatcher(payable(vm.parseJsonAddress(sj, ".dispatcher")));
        key = PoolKey(Currency.wrap(SEP_WETH), Currency.wrap(SEP_BNM), 3000, 60, IHooks(address(hook)));
    }

    // ---------------------------------------------------------------- grant inputs

    function _loadGrant() internal view returns (Attestation memory a, address recipient, uint128 amountIn) {
        if (vm.exists(ATTESTATION_JSON)) {
            string memory aj = vm.readFile(ATTESTATION_JSON);
            a = Attestation({
                grantId: vm.parseJsonBytes32(aj, ".grantId"),
                evidenceHash: vm.parseJsonBytes32(aj, ".evidenceHash"),
                inputsHash: vm.parseJsonBytes32(aj, ".inputsHash"),
                rubricHash: vm.parseJsonBytes32(aj, ".rubricHash"),
                issuedAt: uint64(vm.parseJsonUint(aj, ".issuedAt"))
            });
            recipient = _resolveGrantee();
            amountIn = uint128(vm.parseUint(vm.parseJsonString(aj, ".amountInWei")));
        } else {
            bytes32 grantId = keccak256(abi.encode("nidhi-demo", block.timestamp));
            a = Attestation({
                grantId: grantId,
                evidenceHash: keccak256(abi.encode("demo-evidence", grantId)),
                inputsHash: keccak256("demo-inputs"),
                rubricHash: keccak256("demo-rubric"),
                issuedAt: uint64(block.timestamp)
            });
            recipient = _resolveGrantee();
            amountIn = uint128(vm.envOr("AMOUNT_IN_WEI", uint256(0.0001 ether)));
        }
    }

    function _mandate(Attestation memory a, address executor, address recipient, uint128 amountIn)
        internal
        view
        returns (Mandate memory)
    {
        return _mandateAt(a, executor, recipient, amountIn, 0);
    }

    /// Mandate for a grant that executes after `priorIn` of input has already been swapped in the same batch:
    /// its band is the exact marginal quote quote(prior + amount) - quote(prior).
    function _mandateAt(Attestation memory a, address executor, address recipient, uint128 amountIn, uint128 priorIn)
        internal
        view
        returns (Mandate memory)
    {
        uint256 quote = _quote(priorIn + amountIn) - (priorIn == 0 ? 0 : _quote(priorIn));
        return Mandate({
            grantId: a.grantId,
            executor: executor,
            recipient: recipient,
            tokenIn: SEP_WETH,
            tokenOut: SEP_BNM,
            amountIn: amountIn,
            minOut: uint128(quote * 99 / 100),
            maxOut: uint128(quote * 101 / 100),
            destChainSelector: BASE_SELECTOR,
            destReceiver: _readAddress(BASE_JSON, ".receiver"),
            evidenceHash: a.evidenceHash,
            deadline: uint64(block.timestamp + 1 hours),
            poolId: poolId,
            recipientLabelHash: keccak256(bytes(_granteeLabel()))
        });
    }

    /// Exact-input quote for WETH -> CCIP-BnM against the single full-range position (no tick crossing).
    function _quote(uint128 amountIn) internal view returns (uint256) {
        IPoolManager pm = IPoolManager(SEP_POOL_MANAGER);
        (uint160 sqrtP,,,) = pm.getSlot0(PoolId.wrap(poolId));
        uint128 liquidity = pm.getLiquidity(PoolId.wrap(poolId));
        uint256 inLessFee = uint256(amountIn) * (1e6 - 3000) / 1e6;
        uint160 sqrtNext = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, liquidity, inLessFee, true);
        return SqrtPriceMath.getAmount1Delta(sqrtNext, sqrtP, liquidity, false);
    }

    /// "Pay a name, not an address": the recipient is whatever the grantee subname resolves to on Base right now.
    function _resolveGrantee() internal view returns (address a) {
        a = IGranteeResolver(vm.parseJsonAddress(vm.readFile(SEP_JSON), ".authority")).resolveGrantee(_granteeLabel());
        require(a != address(0), "grantee subname does not resolve - run 06_EnsSubnames");
    }

    function _granteeLabel() internal view returns (string memory) {
        if (vm.exists(ATTESTATION_JSON)) {
            string memory aj = vm.readFile(ATTESTATION_JSON);
            if (vm.keyExistsJson(aj, ".granteeLabel")) return vm.parseJsonString(aj, ".granteeLabel");
        }
        return vm.envOr("GRANTEE_LABEL", string("alice"));
    }

    // ---------------------------------------------------------------- signatures

    function _hookData(Mandate memory m, Attestation memory a) internal view returns (bytes memory) {
        uint256 apk = vm.envUint("APPROVER_PRIVATE_KEY");
        (address auditor, bytes memory auditorSig) = _auditorSignature(a);
        return abi.encode(
            NidhiHook.GrantAuth({
                mandate: m,
                approver: vm.addr(apk),
                approverSig: _sig(apk, hook.mandateDigest(m)),
                attestation: a,
                auditor: auditor,
                auditorSig: auditorSig,
                recipientLabel: _granteeLabel()
            })
        );
    }

    /// Prefer the signature the AI auditor produced itself; otherwise sign with the AUDITOR key here.
    function _auditorSignature(Attestation memory a) internal view returns (address, bytes memory) {
        if (vm.exists(ATTESTATION_JSON)) {
            string memory aj = vm.readFile(ATTESTATION_JSON);
            if (vm.keyExistsJson(aj, ".auditorSig") && vm.parseJsonBytes32(aj, ".grantId") == a.grantId) {
                return (vm.parseJsonAddress(aj, ".auditor"), vm.parseJsonBytes(aj, ".auditorSig"));
            }
        }
        uint256 upk = vm.envUint("AUDITOR_PRIVATE_KEY");
        return (vm.addr(upk), _sig(upk, hook.attestationDigest(a)));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
