// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {SuperIMDHookFactory} from "../src/SuperIMDHookFactory.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {PoolHarness} from "./helpers/PoolHarness.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract FeeSequenceHandler {
    PoolHarness public immutable router;
    SuperIMDHook public hook;
    PoolKey public key;
    PoolKey public baseline;
    address public immutable setupCaller;
    uint256 public earnedNative;
    uint256 public earnedToken;
    uint256 public collectedNative;
    uint256 public collectedToken;

    constructor(IPoolManager manager) {
        router = new PoolHarness(manager);
        setupCaller = msg.sender;
    }

    receive() external payable {}

    function initialize(SuperIMDHook hook_, SuperIMD token) external {
        require(msg.sender == setupCaller && address(hook) == address(0), "fixture setup only");
        hook = hook_;
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, hook);
        baseline = PoolKey(key.currency0, key.currency1, 0, 60, IHooks(address(0)));
        IPoolManager manager = hook.poolManager();
        manager.initialize(key, 1 << 96);
        manager.initialize(baseline, 1 << 96);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0));
        router.liquidity(key, lp);
        router.liquidity(baseline, lp);
    }

    function swap(bool exactInput, bool zeroForOne, uint96 seed) external {
        uint256 amount = uint256(seed) % 1 ether + 1;
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        BalanceDelta gross = router.swap(baseline, params, 0, type(uint256).max);
        BalanceDelta net = router.swap(key, params, 0, type(uint256).max);
        bool currency1 = exactInput == zeroForOne;
        int256 unspecified = currency1 ? int256(gross.amount1()) : int256(gross.amount0());
        uint256 fee = uint256(unspecified < 0 ? -unspecified : unspecified) / 50;
        if (currency1) earnedToken += fee;
        else earnedNative += fee;
        require(
            int256(net.amount0()) == int256(gross.amount0()) - (currency1 ? int256(0) : int256(fee)), "delta0"
        );
        require(
            int256(net.amount1()) == int256(gross.amount1()) - (currency1 ? int256(fee) : int256(0)), "delta1"
        );
    }

    function collect(bool nativeCurrency, uint96 seed) external {
        Currency currency = nativeCurrency ? key.currency0 : key.currency1;
        uint256 available = hook.accruedFees(currency);
        if (available == 0) return;
        uint256 amount = uint256(seed) % available + 1;
        hook.collectFees(currency, amount, address(this));
        if (nativeCurrency) collectedNative += amount;
        else collectedToken += amount;
    }
}

contract HookInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant NATIVE_FUNDS = 1_000_000 ether;
    PoolManager manager;
    SuperIMD token;
    SuperIMDHook hook;
    FeeSequenceHandler handler;
    PoolHarness router;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new SuperIMD(SUPPLY, address(this));
        handler = new FeeSequenceHandler(manager);
        router = handler.router();
        token.transfer(address(router), SUPPLY);
        vm.deal(address(router), NATIVE_FUNDS);
        SuperIMDHookFactory factory = new SuperIMDHookFactory(address(this), address(handler), address(token));
        factory.setPoolManager(manager);
        (, bytes32 salt) = HookSaltMiner.mine(address(factory), factory.hookInitCodeHash(), 0, 200_000);
        hook = factory.deployHook(salt);
        handler.initialize(hook, token);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FeeSequenceHandler.swap.selector;
        selectors[1] = FeeSequenceHandler.collect.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_feeClaimsPlusCollectionsEqualEarnedFees() public view {
        assertEq(
            hook.accruedFees(Currency.wrap(address(0))) + handler.collectedNative(), handler.earnedNative()
        );
        assertEq(
            hook.accruedFees(Currency.wrap(address(token))) + handler.collectedToken(), handler.earnedToken()
        );
        assertEq(address(handler).balance, handler.collectedNative());
        assertEq(token.balanceOf(address(handler)), handler.collectedToken());
    }

    function invariant_currencyConservationAndNoUnsettledDebts() public view {
        assertEq(address(router).balance + address(manager).balance + address(handler).balance, NATIVE_FUNDS);
        assertEq(
            token.balanceOf(address(router)) + token.balanceOf(address(manager))
                + token.balanceOf(address(handler)),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
    }
}
