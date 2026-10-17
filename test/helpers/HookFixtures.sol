// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";
import {SuperIMDHook} from "../../src/SIMDhook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @dev Original supplied token constructor, retained only for audit reproduction.
contract OriginalToken is ERC20, ERC20Permit {
    constructor(uint256 initialSupply, address recipient)
        ERC20("Super IMD", "SIMD")
        ERC20Permit("Super IMD")
    {
        _mint(recipient, initialSupply);
    }
}

/// @dev Original supplied hook body. The missing base is replaced by our guarded base
///      to isolate defects in the submitted body, not speculate about the missing dependency.
contract OriginalHook is BaseHook {
    using SafeCast for uint256;
    uint256 public constant FEE_BIPS = 200;
    uint256 public constant TOTAL_BIPS = 10_000;
    address public immutable feeRecipient;
    address public immutable projectToken;

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
        (Currency feeCurrency, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;
        uint256 feeAmount = (uint128(unspecifiedAmount) * FEE_BIPS) / TOTAL_BIPS;
        if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);
        poolManager.take(feeCurrency, feeRecipient, feeAmount);
        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }
}

contract AccountingMock {
    address public mintedTo;
    uint256 public mintedId;
    uint256 public mintedAmount;
    uint256 public mintCalls;
    address public takenTo;
    Currency public takenCurrency;
    uint256 public takenAmount;

    function mint(address to, uint256 id, uint256 amount) external {
        mintedTo = to;
        mintedId = id;
        mintedAmount = amount;
        ++mintCalls;
    }

    function take(Currency currency, address to, uint256 amount) external {
        takenTo = to;
        takenCurrency = currency;
        takenAmount = amount;
    }
}

contract RejectingBeneficiary {
    receive() external payable {
        revert("reject native");
    }

    function collect(SuperIMDHook hook, Currency currency, uint256 amount, address recipient) external {
        hook.collectFees(currency, amount, recipient);
    }
}

contract ReenteringBeneficiary {
    SuperIMDHook public hook;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    function setHook(SuperIMDHook hook_) external {
        hook = hook_;
    }

    function collect(uint256 amount) external {
        hook.collectFees(Currency.wrap(address(0)), amount, address(this));
    }

    receive() external payable {
        attempted = true;
        (succeeded, result) = address(hook)
            .call(abi.encodeCall(SuperIMDHook.collectFees, (Currency.wrap(address(0)), 1, address(this))));
    }
}
