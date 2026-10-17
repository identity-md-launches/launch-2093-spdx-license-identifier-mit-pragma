// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {SuperIMDHookFactory} from "../src/SuperIMDHookFactory.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {PoolHarness, QuoteToken} from "./helpers/PoolHarness.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Three hooked pools (native quote, SIMD as currency0, SIMD as currency1), each mirrored by an
///      identical hookless pool. Liquidity moves are applied to both, so the mirror's swap result is the
///      gross amount the hook must charge 2% of. Outsiders repeatedly try to collect or fake callbacks.
contract MultiPoolHandler is Test {
    uint256 constant POOLS = 3;
    uint256 constant RANGES = 3;

    IPoolManager public immutable manager;
    PoolHarness public immutable router;
    SuperIMDHook public hook;
    address public beneficiary;
    address[3] public destinations;
    Currency[4] public currencies;

    PoolKey[POOLS] internal keys;
    PoolKey[POOLS] internal mirrors;
    mapping(uint256 => mapping(uint256 => uint256)) public extraLiquidity;

    mapping(uint256 => uint256) public earned;
    mapping(uint256 => uint256) public collected;
    uint256 public swaps;
    uint256 public feeBearingSwaps;
    uint256 public outsiderAttempts;
    uint256 public collections;

    constructor(IPoolManager manager_) {
        manager = manager_;
        router = new PoolHarness(manager_);
        destinations = [makeAddr("dest a"), makeAddr("dest b"), makeAddr("dest c")];
    }

    function bind(SuperIMDHook hook_, Currency native, Currency simd, Currency lower, Currency upper)
        external
    {
        require(address(hook) == address(0), "bound");
        hook = hook_;
        beneficiary = hook_.feeRecipient();
        currencies = [native, simd, lower, upper];
        keys[0] = PoolKey(native, simd, 0, 60, hook_);
        keys[1] = PoolKey(simd, upper, 500, 10, hook_);
        keys[2] = PoolKey(lower, simd, 3000, 60, hook_);
        for (uint256 i; i < POOLS; ++i) {
            mirrors[i] = keys[i];
            mirrors[i].hooks = IHooks(address(0));
            manager.initialize(keys[i], 1 << 96);
            manager.initialize(mirrors[i], 1 << 96);
            ModifyLiquidityParams memory base = ModifyLiquidityParams(-6000, 6000, 50_000 ether, bytes32(0));
            router.liquidity(keys[i], base);
            router.liquidity(mirrors[i], base);
        }
    }

    function _currencyIndex(Currency c) internal view returns (uint256) {
        for (uint256 i; i < 4; ++i) {
            if (Currency.unwrap(currencies[i]) == Currency.unwrap(c)) return i;
        }
        revert("unknown currency");
    }

    function swap(uint256 poolSeed, bool exactInput, bool zeroForOne, uint256 amount, bool dust) external {
        uint256 p = poolSeed % POOLS;
        amount = dust ? bound(amount, 1, 200) : bound(amount, 1, 20 ether);
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        bool feeOn1 = exactInput == zeroForOne;
        Currency feeCurrency = feeOn1 ? keys[p].currency1 : keys[p].currency0;
        uint256 claimsBefore = hook.accruedFees(feeCurrency);

        BalanceDelta gross = router.swap(mirrors[p], params, 0, type(uint256).max);
        BalanceDelta net = router.swap(keys[p], params, 0, type(uint256).max);

        int256 unspecified = feeOn1 ? int256(gross.amount1()) : int256(gross.amount0());
        uint256 magnitude = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint256 fee = magnitude * 200 / 10_000;
        // The specified side is untouched; the unspecified side moves against the trader by exactly the fee.
        assertEq(
            int256(net.amount0()), int256(gross.amount0()) - (feeOn1 ? int256(0) : int256(fee)), "amount0"
        );
        assertEq(
            int256(net.amount1()), int256(gross.amount1()) - (feeOn1 ? int256(fee) : int256(0)), "amount1"
        );
        assertEq(hook.accruedFees(feeCurrency) - claimsBefore, fee, "claim minted");
        // Never more than 2% of the gross unspecified amount, and never charged on the specified side.
        assertLe(fee * 50, magnitude);
        earned[_currencyIndex(feeCurrency)] += fee;
        ++swaps;
        if (fee > 0) ++feeBearingSwaps;
    }

    function addLiquidity(uint256 poolSeed, uint256 rangeSeed, uint256 amount) external {
        uint256 p = poolSeed % POOLS;
        uint256 r = rangeSeed % RANGES;
        amount = bound(amount, 1 ether, 5_000 ether);
        ModifyLiquidityParams memory lp = _range(p, r, int256(amount));
        router.liquidity(keys[p], lp);
        router.liquidity(mirrors[p], lp);
        extraLiquidity[p][r] += amount;
    }

    function removeLiquidity(uint256 poolSeed, uint256 rangeSeed, uint256 amount) external {
        uint256 p = poolSeed % POOLS;
        uint256 r = rangeSeed % RANGES;
        uint256 held = extraLiquidity[p][r];
        if (held == 0) return;
        amount = bound(amount, 1, held);
        ModifyLiquidityParams memory lp = _range(p, r, -int256(amount));
        // LP principal is never trapped by the hook: removal must succeed in both pools.
        router.liquidity(keys[p], lp);
        router.liquidity(mirrors[p], lp);
        extraLiquidity[p][r] = held - amount;
    }

    function _range(uint256 p, uint256 r, int256 delta) internal view returns (ModifyLiquidityParams memory) {
        int24 spacing = keys[p].tickSpacing;
        int24 width = int24(int256(r + 1)) * 40 * spacing;
        return ModifyLiquidityParams(-width, width, delta, bytes32(r + 1));
    }

    function collect(uint256 currencySeed, uint256 amount, uint256 destSeed) external {
        uint256 c = currencySeed % 4;
        Currency currency = currencies[c];
        uint256 available = hook.accruedFees(currency);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        address to = destinations[destSeed % 3];
        uint256 before = currency.balanceOf(to);
        vm.prank(beneficiary);
        hook.collectFees(currency, amount, to);
        assertEq(currency.balanceOf(to) - before, amount, "paid amount");
        assertEq(hook.accruedFees(currency), available - amount, "claims burned");
        collected[c] += amount;
        ++collections;
    }

    function overCollect(uint256 currencySeed, uint256 excess) external {
        Currency currency = currencies[currencySeed % 4];
        uint256 available = hook.accruedFees(currency);
        uint256 amount = available + bound(excess, 1, 1 ether);
        vm.prank(beneficiary);
        try hook.collectFees(currency, amount, destinations[0]) {
            revert("collected more than accrued");
        } catch {}
        assertEq(hook.accruedFees(currency), available);
    }

    function outsiderCollect(address caller, uint256 currencySeed, uint256 amount) external {
        if (caller == beneficiary) caller = address(this);
        Currency currency = currencies[currencySeed % 4];
        uint256 available = hook.accruedFees(currency);
        amount = bound(amount, 1, available + 1);
        vm.prank(caller);
        try hook.collectFees(currency, amount, caller) {
            revert("outsider collected fees");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(SuperIMDHook.NotFeeRecipient.selector));
        }
        assertEq(hook.accruedFees(currency), available);
        ++outsiderAttempts;
    }

    function outsiderCallbacks(address caller, uint256 poolSeed, int128 amount) external {
        if (caller == address(manager)) caller = address(this);
        PoolKey memory key = keys[poolSeed % POOLS];
        vm.prank(caller);
        try hook.afterSwap(caller, key, SwapParams(true, -1, 0), toBalanceDelta(-1, amount), "") {
            revert("fake afterSwap accepted");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(BaseHook.NotPoolManager.selector));
        }
        vm.prank(caller);
        try hook.unlockCallback(abi.encode(key.currency0, uint256(1), caller)) {
            revert("fake unlockCallback accepted");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(BaseHook.NotPoolManager.selector));
        }
        ++outsiderAttempts;
    }

    function poolKey(uint256 i) external view returns (PoolKey memory) {
        return keys[i];
    }
}

contract HookMultiPoolInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant NATIVE = 10_000_000 ether;
    PoolManager manager;
    SuperIMD token;
    SuperIMDHook hook;
    MultiPoolHandler handler;
    QuoteToken lower;
    QuoteToken upper;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new SuperIMD(SUPPLY, address(this));
        for (uint256 i; i < 100 && (address(lower) == address(0) || address(upper) == address(0)); ++i) {
            QuoteToken quote = new QuoteToken();
            if (address(quote) < address(token) && address(lower) == address(0)) lower = quote;
            if (address(quote) > address(token) && address(upper) == address(0)) upper = quote;
        }
        require(address(lower) != address(0) && address(upper) != address(0), "quote ordering");

        handler = new MultiPoolHandler(manager);
        address beneficiary = makeAddr("fee beneficiary");
        SuperIMDHookFactory factory = new SuperIMDHookFactory(address(this), beneficiary, address(token));
        factory.setPoolManager(manager);
        (, bytes32 salt) = HookSaltMiner.mine(address(factory), factory.hookInitCodeHash(), 0, 200_000);
        hook = factory.deployHook(salt);

        PoolHarness router = handler.router();
        token.transfer(address(router), SUPPLY);
        lower.transfer(address(router), lower.balanceOf(address(this)));
        upper.transfer(address(router), upper.balanceOf(address(this)));
        vm.deal(address(router), NATIVE);
        handler.bind(
            hook,
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            Currency.wrap(address(lower)),
            Currency.wrap(address(upper))
        );

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = MultiPoolHandler.swap.selector;
        selectors[1] = MultiPoolHandler.addLiquidity.selector;
        selectors[2] = MultiPoolHandler.removeLiquidity.selector;
        selectors[3] = MultiPoolHandler.collect.selector;
        selectors[4] = MultiPoolHandler.overCollect.selector;
        selectors[5] = MultiPoolHandler.outsiderCollect.selector;
        selectors[6] = MultiPoolHandler.outsiderCallbacks.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous handler: a fixed sequence must earn and pay out fees in every pool.
    function test_handlerSequenceEarnsAndCollectsInEveryPool() public {
        for (uint256 p; p < 3; ++p) {
            handler.swap(p, true, true, 1 ether, false);
            handler.swap(p, true, false, 1 ether, false);
            handler.swap(p, false, true, 1 ether, false);
            handler.swap(p, false, false, 1 ether, false);
        }
        assertEq(handler.feeBearingSwaps(), 12);
        for (uint256 c; c < 4; ++c) {
            assertGt(handler.earned(c), 0);
            handler.collect(c, type(uint256).max, c);
            handler.outsiderCollect(address(0xBEEF), c, 1);
        }
        assertEq(handler.collections(), 4);
        invariant_claimsPlusCollectedEqualsEarnedPerCurrency();
        invariant_claimsAreBackedAndHookHoldsNoCurrency();
        invariant_currencyConservedAcrossRouterManagerAndDestinations();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_claimsPlusCollectedEqualsEarnedPerCurrency() public view {
        for (uint256 c; c < 4; ++c) {
            Currency currency = handler.currencies(c);
            assertEq(hook.accruedFees(currency) + handler.collected(c), handler.earned(c));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_claimsAreBackedAndHookHoldsNoCurrency() public view {
        for (uint256 c; c < 4; ++c) {
            Currency currency = handler.currencies(c);
            assertGe(currency.balanceOf(address(manager)), hook.accruedFees(currency), "unbacked claims");
            assertEq(currency.balanceOf(address(hook)), 0, "hook holds raw currency");
        }
        assertFalse(IPoolManager(address(manager)).isUnlocked());
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_currencyConservedAcrossRouterManagerAndDestinations() public view {
        for (uint256 c; c < 4; ++c) {
            Currency currency = handler.currencies(c);
            uint256 total =
                currency.balanceOf(address(handler.router())) + currency.balanceOf(address(manager));
            for (uint256 d; d < 3; ++d) {
                total += currency.balanceOf(handler.destinations(d));
            }
            uint256 expected = c == 0 ? NATIVE : IERC20(Currency.unwrap(currency)).totalSupply();
            assertEq(total, expected);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
