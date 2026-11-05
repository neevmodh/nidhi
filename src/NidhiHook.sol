// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Mandate, Attestation, MandateLib} from "./libraries/Mandate.sol";
import {IGrantAuthority} from "./interfaces/IGrantAuthority.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";
import {INidhiDispatcher} from "./interfaces/INidhiDispatcher.sol";

/// @title NidhiHook
/// @notice Uniswap v4 hook that turns one pool into a mandate-gated grant payout rail.
///
///  beforeSwap  - the firewall. A swap only proceeds if it carries an EIP-712 Mandate signed by an ENS-role APPROVER
///                and an Attestation signed by a distinct ENS-role AUDITOR, both bound to exactly this swap
///                (pool, direction, exact input, executor, deadline) and never used before.
///  afterSwap   - the capture. The output must land inside the mandate's [minOut, maxOut] band. The hook claims the
///                entire output via AFTER_SWAP_RETURNS_DELTA, takes it from the PoolManager straight into the
///                dispatcher, and the dispatcher sends it cross-chain with CCIP in the same transaction.
///                The swapper receives zero output; funds never rest in a human-controlled wallet.
///
/// @dev Permissions are minimal: beforeSwap, afterSwap, afterSwapReturnDelta (address flag bits 0xC4).
contract NidhiHook is BaseHook, EIP712 {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    /// hookData = abi.encode(GrantAuth)
    struct GrantAuth {
        Mandate mandate;
        address approver;
        bytes approverSig;
        Attestation attestation;
        address auditor;
        bytes auditorSig;
    }

    IGrantAuthority public immutable authority;
    INidhiDispatcher public immutable dispatcher;
    address public immutable trustedRouter;
    address public immutable owner;

    /// @notice The single pool this hook serves. Set once.
    PoolId public poolId;
    bool public poolSet;

    /// @notice grantId => consumed. A grant can authorize exactly one swap, ever.
    mapping(bytes32 => bool) public grantUsed;

    /// @dev EIP-1153 slot: grantId authorized in beforeSwap, consumed in afterSwap of the same swap.
    ///      keccak256("nidhi.hook.activeGrant") - 1
    bytes32 private constant ACTIVE_GRANT_SLOT = 0x2b1573794054b185ae7a85e8b935417166be5ab2d0db553bb8ff1e38fd4c3c7a;

    event PoolBound(PoolId indexed poolId);
    event GrantAuthorized(bytes32 indexed grantId, address indexed approver, address indexed auditor, address executor);
    event GrantCaptured(bytes32 indexed grantId, address indexed tokenOut, uint256 amountOut, bytes32 messageId);

    error ZeroAddress();
    error NotOwner();
    error PoolAlreadySet();
    error WrongPool();
    error UntrustedRouter(address router);
    error WrongExecutor(address expected, address actual);
    error MandateExpired();
    error GrantAlreadyUsed(bytes32 grantId);
    error NotExactInput();
    error WrongDirection();
    error InvalidMandate();
    error AttestationMismatch();
    error SameSigner();
    error BadSignature(address signer);
    error NotAuthorized(bytes32 role, address account);
    error NoActiveGrant();
    error OutputOutOfBounds(uint256 out, uint256 minOut, uint256 maxOut);

    constructor(
        IPoolManager poolManager_,
        IGrantAuthority authority_,
        INidhiDispatcher dispatcher_,
        address trustedRouter_,
        address owner_
    ) BaseHook(poolManager_) EIP712("Nidhi", "1") {
        if (
            address(authority_) == address(0) || address(dispatcher_) == address(0) || trustedRouter_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        authority = authority_;
        dispatcher = dispatcher_;
        trustedRouter = trustedRouter_;
        owner = owner_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Bind the hook to its one pool. Callable once by the owner; the key must name this hook.
    function setPool(PoolKey calldata key) external {
        if (msg.sender != owner) revert NotOwner();
        if (poolSet) revert PoolAlreadySet();
        if (address(key.hooks) != address(this)) revert WrongPool();
        poolId = key.toId();
        poolSet = true;
        emit PoolBound(poolId);
    }

    // ------------------------------------------------------------------ EIP-712 views (for off-chain signers)

    function mandateDigest(Mandate calldata m) public view returns (bytes32) {
        return _hashTypedDataV4(MandateLib.hash(m));
    }

    function attestationDigest(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(MandateLib.hash(a));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------ beforeSwap: the firewall

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!poolSet || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        if (sender != trustedRouter) revert UntrustedRouter(sender);

        GrantAuth memory g = abi.decode(hookData, (GrantAuth));
        Mandate memory m = g.mandate;

        _checkBinding(m, key, params);

        address executor = IMsgSender(sender).msgSender();
        if (executor != m.executor) revert WrongExecutor(m.executor, executor);

        if (grantUsed[m.grantId]) revert GrantAlreadyUsed(m.grantId);
        _checkSignatures(g);
        grantUsed[m.grantId] = true;

        _setActiveGrant(m.grantId);
        emit GrantAuthorized(m.grantId, g.approver, g.auditor, executor);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _checkBinding(Mandate memory m, PoolKey calldata key, SwapParams calldata params) private view {
        if (block.timestamp > m.deadline) revert MandateExpired();
        if (m.poolId != PoolId.unwrap(poolId)) revert WrongPool();
        if (m.recipient == address(0) || m.amountIn == 0 || m.minOut == 0 || m.minOut > m.maxOut) {
            revert InvalidMandate();
        }
        if (params.amountSpecified != -int256(uint256(m.amountIn))) revert NotExactInput();

        (Currency inC, Currency outC) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (Currency.unwrap(inC) != m.tokenIn || Currency.unwrap(outC) != m.tokenOut) revert WrongDirection();
    }

    function _checkSignatures(GrantAuth memory g) private view {
        Attestation memory a = g.attestation;
        if (a.grantId != g.mandate.grantId || a.evidenceHash != g.mandate.evidenceHash) revert AttestationMismatch();
        if (g.approver == g.auditor) revert SameSigner();

        bytes32 mDigest = _hashTypedDataV4(MandateLib.hash(g.mandate));
        if (!_isValidSignature(g.approver, mDigest, g.approverSig)) revert BadSignature(g.approver);

        bytes32 aDigest = _hashTypedDataV4(MandateLib.hash(a));
        if (!_isValidSignature(g.auditor, aDigest, g.auditorSig)) revert BadSignature(g.auditor);

        bytes32 approverRole = authority.APPROVER();
        if (!authority.isAuthorized(approverRole, g.approver)) revert NotAuthorized(approverRole, g.approver);
        bytes32 auditorRole = authority.AUDITOR();
        if (!authority.isAuthorized(auditorRole, g.auditor)) revert NotAuthorized(auditorRole, g.auditor);
    }

    function _activeGrant() private view returns (bytes32 g) {
        assembly ("memory-safe") {
            g := tload(ACTIVE_GRANT_SLOT)
        }
    }

    function _setActiveGrant(bytes32 g) private {
        assembly ("memory-safe") {
            tstore(ACTIVE_GRANT_SLOT, g)
        }
    }

    /// @dev Accepts (1) an ECDSA signature by the signer's own key - including EIP-7702-delegated EOAs, which have
    ///      code but are still controlled by their key - or (2) an ERC-1271 signature from a contract wallet (Safe).
    ///      OZ SignatureChecker alone routes every address with code to ERC-1271 and would reject 7702 accounts.
    ///      A pure contract has no private key, so path (1) can never match it.
    function _isValidSignature(address signer, bytes32 digest, bytes memory sig) private view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, digest, sig);
    }

    // ------------------------------------------------------------------ afterSwap: capture + atomic dispatch

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        Mandate memory m = abi.decode(hookData, (GrantAuth)).mandate;
        bytes32 active = _activeGrant();
        if (active == bytes32(0) || active != m.grantId) revert NoActiveGrant();
        _setActiveGrant(bytes32(0));

        // Exact-input: the unspecified (output) side is positive = owed to the swapper.
        int128 outSigned = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 out = outSigned > 0 ? SafeCast.toUint256(int256(outSigned)) : 0;
        if (out < m.minOut || out > m.maxOut) revert OutputOutOfBounds(out, m.minOut, m.maxOut);

        Currency outC = params.zeroForOne ? key.currency1 : key.currency0;

        // Move the full output from the PoolManager straight into the dispatcher. The matching +out credit
        // to the hook is booked by the PoolManager from our returned delta, netting the hook to zero.
        outC.take(poolManager, address(dispatcher), out, false);
        bytes32 messageId = dispatcher.dispatch(m, out);

        emit GrantCaptured(m.grantId, m.tokenOut, out, messageId);
        return (this.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(out)));
    }
}
