// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract QuoteToken is ERC20 {
    constructor() ERC20("Test IMD Quote", "IMD") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/// @dev Test-only payer/router. Exercises real unlock, swap, liquidity, settlement and take.
contract PoolHarness is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable controller;
    error NotController();
    error WrongCallbackCaller();
    error Slippage();

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params, uint256 minOut, uint256 maxIn)
        external
        returns (BalanceDelta)
    {
        if (msg.sender != controller) revert NotController();
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), key, abi.encode(params, minOut, maxIn))), (BalanceDelta)
        );
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta)
    {
        if (msg.sender != controller) revert NotController();
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert WrongCallbackCaller();
        (uint8 action, PoolKey memory key, bytes memory encoded) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (SwapParams memory params, uint256 minOut, uint256 maxIn) =
                abi.decode(encoded, (SwapParams, uint256, uint256));
            delta = manager.swap(key, params, "");
            int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (
                input > 0 || output < 0 || uint256(-int256(input)) > maxIn || uint256(int256(output)) < minOut
            ) {
                revert Slippage();
            }
        } else {
            ModifyLiquidityParams memory params = abi.decode(encoded, (ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "test transfer");
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}
