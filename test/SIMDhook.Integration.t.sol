// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {SuperIMDHookFactory} from "../src/SuperIMDHookFactory.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {PoolHarness, QuoteToken} from "./helpers/PoolHarness.sol";
import {OriginalHook, RejectingBeneficiary, ReenteringBeneficiary} from "./helpers/HookFixtures.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

contract HookIntegrationTest is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    uint160 constant START_PRICE = 1 << 96;
    uint256 constant LIQUIDITY = 100_000 ether;
    PoolManager manager;
    PoolHarness router;
    SuperIMD token;
    SuperIMDHook hook;
    address beneficiary;
    PoolKey nativeKey;
    PoolKey nativeBaseline;
    PoolKey token0Key;
    PoolKey token0Baseline;
    PoolKey token1Key;
    PoolKey token1Baseline;
    QuoteToken lowerQuote;
    QuoteToken upperQuote;

    function setUp() public {
        beneficiary = makeAddr("fee beneficiary");
        manager = new PoolManager(address(this));
        router = new PoolHarness(manager);
        token = new SuperIMD(1_000_000_000 ether, address(this));
        token.transfer(address(router), 100_000_000 ether);
        vm.deal(address(router), 100_000_000 ether);
        hook = _deployHook(beneficiary);
        // Both real token address orderings, with no code injection into production contracts.
        for (
            uint256 i;
            i < 100 && (address(lowerQuote) == address(0) || address(upperQuote) == address(0));
            ++i
        ) {
            QuoteToken quote = new QuoteToken();
            if (address(quote) < address(token) && address(lowerQuote) == address(0)) lowerQuote = quote;
            if (address(quote) > address(token) && address(upperQuote) == address(0)) upperQuote = quote;
        }
        require(
            address(lowerQuote) != address(0) && address(upperQuote) != address(0), "quote ordering fixture"
        );
        lowerQuote.transfer(address(router), 100_000_000 ether);
        upperQuote.transfer(address(router), 100_000_000 ether);
        (nativeKey, nativeBaseline) =
            _pools(Currency.wrap(address(0)), Currency.wrap(address(token)), hook, 0);
        (token0Key, token0Baseline) =
            _pools(Currency.wrap(address(token)), Currency.wrap(address(upperQuote)), hook, 0);
        (token1Key, token1Baseline) =
            _pools(Currency.wrap(address(lowerQuote)), Currency.wrap(address(token)), hook, 0);
    }

    function _deployHook(address recipient) internal returns (SuperIMDHook deployed) {
        SuperIMDHookFactory factory = new SuperIMDHookFactory(address(this), recipient, address(token));
        factory.setPoolManager(manager);
        (, bytes32 salt) = HookSaltMiner.mine(address(factory), factory.hookInitCodeHash(), 0, 200_000);
        deployed = factory.deployHook(salt);
    }

    function _pools(Currency c0, Currency c1, IHooks target, uint24 fee)
        internal
        returns (PoolKey memory key, PoolKey memory baseline)
    {
        key = PoolKey(c0, c1, fee, 60, target);
        baseline = PoolKey(c0, c1, fee, 60, IHooks(address(0)));
        _initialize(key);
        _initialize(baseline);
    }

    function _initialize(PoolKey memory key) internal {
        manager.initialize(key, START_PRICE);
        router.liquidity(key, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), bytes32(0)));
    }

    function _params(bool zeroForOne, bool exactInput, uint256 amount)
        internal
        pure
        returns (SwapParams memory)
    {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _compare(PoolKey memory key, PoolKey memory baseline, SwapParams memory params) internal {
        bool currency1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency feeCurrency = currency1 ? key.currency1 : key.currency0;
        uint256 claimsBefore = hook.accruedFees(feeCurrency);
        uint256 router0 = key.currency0.balanceOf(address(router));
        uint256 router1 = key.currency1.balanceOf(address(router));
        uint256 manager0 = key.currency0.balanceOf(address(manager));
        uint256 manager1 = key.currency1.balanceOf(address(manager));
        BalanceDelta net = router.swap(key, params, 0, type(uint256).max);
        assertEq(int256(key.currency0.balanceOf(address(router))) - int256(router0), int256(net.amount0()));
        assertEq(int256(key.currency1.balanceOf(address(router))) - int256(router1), int256(net.amount1()));
        assertEq(int256(key.currency0.balanceOf(address(manager))) - int256(manager0), -int256(net.amount0()));
        assertEq(int256(key.currency1.balanceOf(address(manager))) - int256(manager1), -int256(net.amount1()));
        BalanceDelta gross = router.swap(baseline, params, 0, type(uint256).max);
        int256 unspecified = currency1 ? int256(gross.amount1()) : int256(gross.amount0());
        uint256 expectedFee = uint256(unspecified < 0 ? -unspecified : unspecified) / 50;
        assertEq(
            int256(net.amount0()), int256(gross.amount0()) - (currency1 ? int256(0) : int256(expectedFee))
        );
        assertEq(
            int256(net.amount1()), int256(gross.amount1()) - (currency1 ? int256(expectedFee) : int256(0))
        );
        assertEq(hook.accruedFees(feeCurrency) - claimsBefore, expectedFee);
        _assertSettled(key);
    }

    function _assertSettled(PoolKey memory key) internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        assertEq(pm.currencyDelta(address(router), key.currency0), 0);
        assertEq(pm.currencyDelta(address(router), key.currency1), 0);
        assertFalse(pm.isUnlocked());
    }

    function test_nativeBuySellExactInputAndExactOutput() public {
        _compare(nativeKey, nativeBaseline, _params(true, true, 1 ether));
        _compare(nativeKey, nativeBaseline, _params(false, true, 1 ether));
        _compare(nativeKey, nativeBaseline, _params(true, false, 1 ether));
        _compare(nativeKey, nativeBaseline, _params(false, false, 1 ether));
    }

    function test_erc20BothTokenOrdersAndAllSwapModes() public {
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i % 2 == 0, i < 2, 2 ether);
            _compare(token0Key, token0Baseline, params);
            _compare(token1Key, token1Baseline, params);
        }
    }

    function testFuzz_realSwapFeeAndSettlement(
        bool nativeQuote,
        bool tokenIs0,
        bool exactInput,
        bool zeroForOne,
        uint96 amount
    ) public {
        amount = uint96(bound(amount, 1, 10 ether));
        (PoolKey memory key, PoolKey memory baseline) = nativeQuote
            ? (nativeKey, nativeBaseline)
            : tokenIs0 ? (token0Key, token0Baseline) : (token1Key, token1Baseline);
        _compare(key, baseline, _params(zeroForOne, exactInput, amount));
    }

    function test_partialFillsChargeExecutedAmountOnly() public {
        SwapParams memory params = _params(true, true, 10_000 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-60);
        _compare(nativeKey, nativeBaseline, params);
        params = _params(false, false, 10_000 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(60);
        _compare(nativeKey, nativeBaseline, params);
    }

    function test_tinySwapRoundsFeeDown() public {
        _compare(nativeKey, nativeBaseline, _params(true, true, 49));
        assertEq(hook.accruedFees(nativeKey.currency1), 0);
    }

    function test_zeroLiquiditySwapDoesNotAccrueFees() public {
        router.liquidity(nativeKey, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        BalanceDelta delta = router.swap(nativeKey, _params(true, true, 1 ether), 0, type(uint256).max);
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(hook.accruedFees(nativeKey.currency0), 0);
        assertEq(hook.accruedFees(nativeKey.currency1), 0);
        _assertSettled(nativeKey);
    }

    function test_lpFeeIsAdditionalAndHookRateUnchanged() public {
        (PoolKey memory key, PoolKey memory baseline) =
            _pools(nativeKey.currency0, nativeKey.currency1, hook, 3000);
        _compare(key, baseline, _params(true, true, 1 ether));
        _compare(key, baseline, _params(false, false, 1 ether));
    }

    function test_collectNativeAndERC20FeesWithPartialWithdrawal() public {
        router.swap(nativeKey, _params(true, true, 2 ether), 0, type(uint256).max);
        router.swap(nativeKey, _params(false, true, 2 ether), 0, type(uint256).max);
        uint256 nativeFees = hook.accruedFees(nativeKey.currency0);
        uint256 tokenFees = hook.accruedFees(nativeKey.currency1);
        address destination = makeAddr("fee destination");
        vm.startPrank(beneficiary);
        hook.collectFees(nativeKey.currency0, nativeFees / 2, destination);
        assertEq(destination.balance, nativeFees / 2);
        assertEq(hook.accruedFees(nativeKey.currency0), nativeFees - nativeFees / 2);
        hook.collectFees(nativeKey.currency0, nativeFees - nativeFees / 2, destination);
        hook.collectFees(nativeKey.currency1, tokenFees, destination);
        vm.stopPrank();
        assertEq(destination.balance, nativeFees);
        assertEq(token.balanceOf(destination), tokenFees);
        assertEq(hook.accruedFees(nativeKey.currency0), 0);
        assertEq(hook.accruedFees(nativeKey.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        _assertSettled(nativeKey);
    }

    function test_failedCollectionPreservesClaimsAndDoesNotBlockSwap() public {
        RejectingBeneficiary rejector = new RejectingBeneficiary();
        router.swap(nativeKey, _params(false, true, 2 ether), 0, type(uint256).max);
        uint256 fees = hook.accruedFees(nativeKey.currency0);
        vm.prank(beneficiary);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        hook.collectFees(nativeKey.currency0, fees, address(rejector));
        assertEq(hook.accruedFees(nativeKey.currency0), fees);
        router.swap(nativeKey, _params(false, true, 2 ether), 0, type(uint256).max);
        assertGt(hook.accruedFees(nativeKey.currency0), fees);
        vm.prank(beneficiary);
        hook.collectFees(nativeKey.currency0, fees, beneficiary);
        assertEq(beneficiary.balance, fees);
        _assertSettled(nativeKey);
    }

    function test_overcollectionAndDoubleCollectionRevertWithoutLoss() public {
        router.swap(nativeKey, _params(false, true, 2 ether), 0, type(uint256).max);
        uint256 fees = hook.accruedFees(nativeKey.currency0);
        vm.startPrank(beneficiary);
        vm.expectRevert();
        hook.collectFees(nativeKey.currency0, fees + 1, beneficiary);
        assertEq(hook.accruedFees(nativeKey.currency0), fees);
        hook.collectFees(nativeKey.currency0, fees, beneficiary);
        vm.expectRevert();
        hook.collectFees(nativeKey.currency0, fees, beneficiary);
        vm.stopPrank();
        assertEq(beneficiary.balance, fees);
        _assertSettled(nativeKey);
    }

    function test_rejectingBeneficiaryDoesNotBlockNativeFeeSwaps() public {
        RejectingBeneficiary rejector = new RejectingBeneficiary();
        SuperIMDHook pullHook = _deployHook(address(rejector));
        PoolKey memory key = nativeKey;
        key.hooks = pullHook;
        _initialize(key);
        router.swap(key, _params(false, true, 1 ether), 0, type(uint256).max);
        uint256 fees = pullHook.accruedFees(key.currency0);
        assertGt(fees, 0);
        assertEq(address(rejector).balance, 0);
        rejector.collect(pullHook, key.currency0, fees, beneficiary);
        assertEq(beneficiary.balance, fees);
        assertEq(pullHook.accruedFees(key.currency0), 0);
    }

    function test_reentrantCollectionCannotSpendClaimsTwice() public {
        ReenteringBeneficiary reentrant = new ReenteringBeneficiary();
        SuperIMDHook reentrantHook = _deployHook(address(reentrant));
        reentrant.setHook(reentrantHook);
        PoolKey memory key = nativeKey;
        key.hooks = reentrantHook;
        _initialize(key);
        router.swap(key, _params(false, true, 1 ether), 0, type(uint256).max);
        uint256 fees = reentrantHook.accruedFees(key.currency0);
        reentrant.collect(fees / 2);
        assertTrue(reentrant.attempted());
        assertFalse(reentrant.succeeded());
        assertEq(reentrant.result(), abi.encodeWithSelector(SuperIMDHook.CollectionInProgress.selector));
        assertEq(address(reentrant).balance, fees / 2);
        assertEq(reentrantHook.accruedFees(key.currency0), fees - fees / 2);
    }

    function test_regressionOriginalRecipientRejectionRevertsNativeFeeSwap() public {
        RejectingBeneficiary rejector = new RejectingBeneficiary();
        bytes32 hash = keccak256(
            abi.encodePacked(type(OriginalHook).creationCode, abi.encode(manager, rejector, token))
        );
        (, bytes32 salt) = HookSaltMiner.mine(address(this), hash, 0, 200_000);
        OriginalHook original = new OriginalHook{salt: salt}(manager, address(rejector), address(token));
        PoolKey memory key = nativeKey;
        key.hooks = original;
        _initialize(key);
        uint256 routerNative = address(router).balance;
        uint256 routerTokens = token.balanceOf(address(router));
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swap(key, _params(false, true, 1 ether), 0, type(uint256).max);
        assertEq(address(router).balance, routerNative);
        assertEq(token.balanceOf(address(router)), routerTokens);
    }

    function test_unrelatedPoolCannotSwapThroughHook() public {
        PoolKey memory unrelated =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(upperQuote)), 0, 60, hook);
        _initialize(unrelated);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swap(unrelated, _params(true, true, 1 ether), 0, type(uint256).max);
        // Rejection does not trap LP principal: no liquidity callback blocks removal.
        router.liquidity(unrelated, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        assertEq(hook.accruedFees(unrelated.currency0), 0);
        assertEq(hook.accruedFees(unrelated.currency1), 0);
    }

    function test_routerEnforcesSlippageAfterHookFeesAndRollsBack() public {
        SwapParams memory params = _params(true, true, 1 ether);
        BalanceDelta gross = router.swap(nativeBaseline, params, 0, type(uint256).max);
        vm.expectRevert(PoolHarness.Slippage.selector);
        router.swap(nativeKey, params, uint128(gross.amount1()), type(uint256).max);
        assertEq(hook.accruedFees(nativeKey.currency1), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(nativeKey.toId());
        assertEq(price, START_PRICE);
        params = _params(false, false, 1 ether);
        // Gross input < 1.01 ETH worth of input at this pool depth; the 2% surcharge exceeds it.
        vm.expectRevert(PoolHarness.Slippage.selector);
        router.swap(nativeKey, params, 0, 1.01 ether);
        assertEq(hook.accruedFees(nativeKey.currency1), 0);
        _assertSettled(nativeKey);
    }
}
