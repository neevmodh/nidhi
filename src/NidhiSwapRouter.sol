// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";

/// @title NidhiSwapRouter
/// @notice Minimal, single-purpose router trusted by NidhiHook.
///         - The caller (`msg.sender`) pays the input token via ERC-20 allowance to this router.
///         - `msgSender()` exposes the real initiator to the hook, so a mandate can be bound to its executor.
///         - Any positive output delta is paid to the caller; with NidhiHook the output is redirected to the bridge,
///           so the caller receives nothing.
contract NidhiSwapRouter is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;

    /// @dev EIP-1153 slot holding the initiator of the swap in flight; auto-cleared at the end of the tx.
    ///      keccak256("nidhi.router.initiator") - 1
    bytes32 private constant INITIATOR_SLOT = 0x9346a4b651cc340b90da1e22cbfd4bf765afbd1e85b1d229e12f56e37e0a2f98;

    error NotPoolManager();
    error Reentrant();
    error NativeNotSupported();
    error DeadlinePassed();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
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

    /// @notice Execute a swap on `key`. `hookData` is forwarded to the pool's hook unchanged.
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData, uint256 deadline)
        external
        returns (BalanceDelta delta)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (_initiator() != address(0)) revert Reentrant();
        if (key.currency0.isAddressZero()) revert NativeNotSupported();
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

        _resolve(key.currency0, delta.amount0());
        _resolve(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _resolve(Currency currency, int128 amount) private {
        if (amount < 0) {
            currency.settle(poolManager, _initiator(), uint256(uint128(-amount)), false);
        } else if (amount > 0) {
            currency.take(poolManager, _initiator(), uint256(uint128(amount)), false);
        }
    }
}
