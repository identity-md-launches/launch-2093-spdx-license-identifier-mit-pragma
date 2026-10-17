// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title SuperIMDHook
/// @notice Immutable 2% fee on the unspecified currency of each swap in pools containing SIMD.
///         Exact input: deducted from output. Exact output: added to input.
///         Fees accrue as PoolManager claims, collectible only by feeRecipient.
///         Website: https://www.si-md.xyz/ | X: https://x.com/SuperIMD_eth
contract SuperIMDHook is BaseHook, IUnlockCallback {
    using SafeCast for uint256;

    uint256 public constant FEE_BIPS = 200;
    uint256 public constant TOTAL_BIPS = 10_000;

    address public immutable feeRecipient;
    address public immutable projectToken;
    bool private collecting;

    error InvalidPool();
    error InvalidSwapDelta();
    error NotFeeRecipient();
    error InvalidCollection();
    error CollectionInProgress();
    error NoCollectionInProgress();

    event FeeAccrued(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager manager, address feeRecipient_, address projectToken_) BaseHook(manager) {
        if (feeRecipient_ == address(0) || projectToken_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        projectToken = projectToken_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (
            address(key.hooks) != address(this) || key.currency0 >= key.currency1
                || (Currency.unwrap(key.currency0) != projectToken
                    && Currency.unwrap(key.currency1) != projectToken)
        ) revert InvalidPool();

        bool exactInput = params.amountSpecified < 0;
        (Currency feeCurrency, int128 unspecifiedAmount) = (exactInput == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (params.amountSpecified == 0 || (exactInput ? unspecifiedAmount < 0 : unspecifiedAmount > 0)) {
            revert InvalidSwapDelta();
        }

        // Widen before negation: -type(int128).min is not representable as int128.
        int256 signedAmount = int256(unspecifiedAmount);
        // This nonnegative magnitude is at most 2**127, so conversion and multiplication are safe.
        uint256 magnitude = uint256(signedAmount < 0 ? -signedAmount : signedAmount);
        uint256 feeAmount = magnitude * FEE_BIPS / TOTAL_BIPS;
        if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);

        // Minting claims debits our transient delta just like take(), but makes no receiver call.
        // The positive return delta credits that debit when PoolManager finishes this swap.
        poolManager.mint(address(this), feeCurrency.toId(), feeAmount);
        emit FeeAccrued(key.toId(), feeCurrency, feeAmount);
        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    function accruedFees(Currency currency) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice Redeem fee claims to an address chosen by the immutable beneficiary.
    /// @dev Call outside any other PoolManager unlock. Partial collection is supported.
    ///      A failed transfer reverts the burn, leaving the claims available to retry.
    function collectFees(Currency currency, uint256 amount, address recipient) external {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (collecting) revert CollectionInProgress();
        if (recipient == address(0) || recipient == address(this) || amount == 0) revert InvalidCollection();
        collecting = true;
        // The guard is active throughout unlock and its receiver call. Reset only after success;
        // a revert restores both the guard and all manager claim/transfer state atomically.
        poolManager.unlock(abi.encode(currency, amount, recipient));
        collecting = false;
        emit FeesCollected(currency, recipient, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!collecting) revert NoCollectionInProgress();
        (Currency currency, uint256 amount, address recipient) =
            abi.decode(data, (Currency, uint256, address));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        return bytes("");
    }
}
