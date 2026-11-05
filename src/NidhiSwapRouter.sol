// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";

/// @dev Minimal WETH9 interface — only used when the pool's currency0 is native ETH (address(0)).
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal Permit2 interface (Uniswap universal approval contract).
///      Canonical address: 0x000000000022D473030F116dDEE9F6B43aC78BA3 on all EVM chains.
///      Enables gasless approvals for burner wallets (zero nonce, no prior ERC-20 approve history).
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/// @title NidhiSwapRouter
/// @notice Minimal, single-purpose router trusted by NidhiHook.
///         - The caller (`msg.sender`) pays the input token via ERC-20 allowance to this router.
///         - For native ETH pools (currency0 == address(0)), the caller sends ETH and the router
///           wraps it to WETH9 before settling. This enables raw-ETH inputs without prior WETH wrapping.
///         - Optional `permitData` enables Permit2 gasless approvals for wallets with no prior
///           approval history (burner/new accounts). Encode as: abi.encode(PermitTransferFrom, sig).
///         - `msgSender()` exposes the real initiator to the hook, so a mandate can be bound to its executor.
///         - Any positive output delta is paid to the caller; with NidhiHook the output is redirected to
///           the bridge, so the caller receives nothing.
///
/// @dev Supported tokenIn types:
///      1. Any ERC-20 (USDC, DAI, LINK, ARB…): caller approves this router, router settles via transfer.
///      2. Native ETH: caller sends msg.value; router wraps to WETH9 (requires weth9 != address(0)).
///      3. Any ERC-20 via Permit2: caller signs off-chain; no prior approve needed (burner wallets).
contract NidhiSwapRouter is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;

    /// @notice WETH9 address. Used to auto-wrap native ETH for pools where currency0 == address(0).
    ///         Set to address(0) to disable native ETH wrapping (reverts if native pool encountered).
    address public immutable weth9;

    /// @notice Canonical Permit2 contract address.
    ///         Set to address(0) to disable Permit2 (swap with permitData will revert).
    address public immutable permit2;

    /// @dev EIP-1153 slot holding the initiator of the swap in flight; auto-cleared at the end of the tx.
    ///      keccak256("nidhi.router.initiator") - 1
    bytes32 private constant INITIATOR_SLOT = 0x9346a4b651cc340b90da1e22cbfd4bf765afbd1e85b1d229e12f56e37e0a2f98;

    /// @dev EIP-1153 slot: tracks whether the in-flight tokenIn was pulled via Permit2 (into this router).
    ///      keccak256("nidhi.router.permit2pulled") - 1
    bytes32 private constant PERMIT2_PULLED_SLOT = 0x5b5b0a3e5fc84e1f9e2f7a3f7cd84e7a3f6be3f8e1c2d5f4a7b8c9d0e1f2a3b4;

    error NotPoolManager();
    error Reentrant();
    error NativeWethNotConfigured();
    error Permit2NotConfigured();
    error DeadlinePassed();

    /// @param poolManager_  Uniswap v4 PoolManager
    /// @param weth9_        WETH9 address (address(0) to disable native ETH wrapping)
    /// @param permit2_      Permit2 address (address(0) to disable Permit2 support)
    constructor(IPoolManager poolManager_, address weth9_, address permit2_) {
        poolManager = poolManager_;
        weth9 = weth9_;
        permit2 = permit2_;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        return _initiator();
    }

    function _initiator() private view returns (address a) {
        assembly ("memory-safe") {
            a := tload(INITIATOR_SLOT)
        }
    }

    function _setInitiator(address a) private {
        assembly ("memory-safe") {
            tstore(INITIATOR_SLOT, a)
        }
    }

    function _setPermit2Pulled(bool v) private {
        assembly ("memory-safe") {
            tstore(PERMIT2_PULLED_SLOT, v)
        }
    }

    function _permit2Pulled() private view returns (bool v) {
        assembly ("memory-safe") {
            v := tload(PERMIT2_PULLED_SLOT)
        }
    }

    /// @notice Execute a swap on `key`. `hookData` is forwarded to the pool's hook unchanged.
    /// @param key        The pool key (supports any ERC-20 pair; native ETH as currency0 requires weth9)
    /// @param params     Swap parameters (use negative amountSpecified for exact-input)
    /// @param hookData   Forwarded to the hook unchanged (encodes GrantAuth for NidhiHook)
    /// @param deadline   Unix timestamp; reverts if block.timestamp > deadline
    /// @param permitData If non-empty: abi.encode(IPermit2.PermitTransferFrom, bytes signature).
    ///                   The router calls Permit2.permitTransferFrom before entering the unlock,
    ///                   pulling tokenIn from the caller without requiring a prior ERC-20 approve.
    ///                   This enables brand-new EOAs / burner wallets to execute grants.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData,
        uint256 deadline,
        bytes calldata permitData
    ) external payable returns (BalanceDelta delta) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (_initiator() != address(0)) revert Reentrant();

        // Permit2: pull tokenIn to this router before entering the unlock callback.
        if (permitData.length > 0) {
            if (permit2 == address(0)) revert Permit2NotConfigured();
            (IPermit2.PermitTransferFrom memory p, bytes memory sig) =
                abi.decode(permitData, (IPermit2.PermitTransferFrom, bytes));
            IPermit2(permit2).permitTransferFrom(
                p,
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: p.permitted.amount}),
                msg.sender,
                sig
            );
            // Allow PoolManager to pull from this contract during settle.
            IERC20(p.permitted.token).approve(address(poolManager), p.permitted.amount);
            _setPermit2Pulled(true);
        }

        _setInitiator(msg.sender);
        delta = abi.decode(poolManager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        _setInitiator(address(0));
        _setPermit2Pulled(false);
    }

    /// @notice Backward-compatible overload: same 4-argument signature as v1/v2.
    ///         No Permit2, no native ETH wrapping. All existing tests and scripts use this.
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData, uint256 deadline)
        external
        returns (BalanceDelta delta)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (_initiator() != address(0)) revert Reentrant();
        _setInitiator(msg.sender);
        delta = abi.decode(poolManager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        _setInitiator(address(0));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));

        BalanceDelta delta = poolManager.swap(key, params, hookData);

        _resolve(key.currency0, delta.amount0(), key.currency1);
        _resolve(key.currency1, delta.amount1(), key.currency0);
        return abi.encode(delta);
    }

    /// @dev Settle or take a currency delta.
    /// @param currency    The currency whose delta is being resolved.
    /// @param amount      Signed delta: negative = caller owes pool, positive = pool owes caller.
    /// @param otherCcy    The other currency in the pool (used to identify the native-ETH case).
    function _resolve(Currency currency, int128 amount, Currency otherCcy) private {
        // Suppress unused param warning — kept for future multi-hop disambiguation.
        otherCcy;
        address initiator = _initiator();

        if (amount < 0) {
            // Caller owes tokens INTO the pool.
            uint256 needed = uint256(uint128(-amount));

            if (currency.isAddressZero()) {
                // Native ETH pool: wrap the ETH the caller sent.
                if (weth9 == address(0)) revert NativeWethNotConfigured();
                IWETH9(weth9).deposit{value: needed}();
                // Settle using WETH9 — the PoolManager maps address(0) to its own native tracker,
                // but CurrencySettler with the wrapped token + useBalance settles correctly.
                Currency wethCurrency = Currency.wrap(weth9);
                wethCurrency.settle(poolManager, address(this), needed, true);
            } else if (_permit2Pulled()) {
                // Permit2 pre-pulled tokens into this router; settle from our own balance.
                currency.settle(poolManager, address(this), needed, true);
            } else {
                // Standard ERC-20: pull from the initiator via their prior approve.
                currency.settle(poolManager, initiator, needed, false);
            }
        } else if (amount > 0) {
            // Pool owes tokens TO the initiator.
            // NidhiHook returns delta=+out meaning it already took the output via afterSwapReturnDelta;
            // the PoolManager books the credit to the hook, so the pool delta seen here is 0.
            // For non-hook pools this directly pays the caller.
            currency.take(poolManager, initiator, uint256(uint128(amount)), false);
        }
    }

    /// @dev Accept ETH sent by callers for native-ETH pools, or returned from WETH9.withdraw().
    receive() external payable {}
}
