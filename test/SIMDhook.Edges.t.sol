// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {SuperIMDHookFactory} from "../src/SuperIMDHookFactory.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {PoolHarness} from "./helpers/PoolHarness.sol";
import {AccountingMock} from "./helpers/HookFixtures.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev A beneficiary contract that tries to collect while it already holds the manager lock.
contract NestedCollector is IUnlockCallback {
    IPoolManager public immutable manager;
    SuperIMDHook public hook;
    bytes public nestedError;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function setHook(SuperIMDHook hook_) external {
        hook = hook_;
    }

    function collectInsideUnlock(Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(currency, amount));
    }

    function collect(Currency currency, uint256 amount, address to) external {
        hook.collectFees(currency, amount, to);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        try hook.collectFees(currency, amount, address(this)) {
            revert("nested collection succeeded");
        } catch (bytes memory reason) {
            nestedError = reason;
        }
        return "";
    }

    receive() external payable {}
}

/// @dev Pays native currency into the manager and mints the resulting claim straight to the hook.
contract ClaimDonor is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(address to, uint256 amount) external payable {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(Currency.wrap(address(0)));
        manager.settle{value: amount}();
        manager.mint(to, 0, amount);
        return "";
    }
}

contract HookEdgeTest is Test {
    using TransientStateLibrary for IPoolManager;

    PoolManager manager;
    PoolHarness router;
    SuperIMD token;
    PoolKey key;
    Currency constant NATIVE = Currency.wrap(address(0));

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new PoolHarness(manager);
        token = new SuperIMD(1_000_000_000 ether, address(this));
        token.transfer(address(router), 100_000_000 ether);
        vm.deal(address(router), 100_000_000 ether);
    }

    function _deploy(IPoolManager pm, address beneficiary) internal returns (SuperIMDHook hook) {
        SuperIMDHookFactory factory = new SuperIMDHookFactory(address(this), beneficiary, address(token));
        factory.setPoolManager(pm);
        (, bytes32 salt) = HookSaltMiner.mine(address(factory), factory.hookInitCodeHash(), 0, 200_000);
        hook = factory.deployHook(salt);
    }

    function _pool(SuperIMDHook hook) internal returns (PoolKey memory k) {
        k = PoolKey(NATIVE, Currency.wrap(address(token)), 0, 60, hook);
        manager.initialize(k, 1 << 96);
        router.liquidity(k, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
    }

    function _sell(PoolKey memory k, uint256 amount) internal {
        // Exact-input SIMD -> ETH: the fee is taken in native currency.
        router.swap(k, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), 0, type(uint256).max);
    }

    function test_collectionInsideAnotherUnlockFailsAndLeavesGuardUsable() public {
        NestedCollector collector = new NestedCollector(manager);
        SuperIMDHook hook = _deploy(manager, address(collector));
        collector.setHook(hook);
        PoolKey memory k = _pool(hook);
        _sell(k, 1 ether);
        uint256 fees = hook.accruedFees(NATIVE);
        assertGt(fees, 0);

        collector.collectInsideUnlock(NATIVE, fees);
        assertEq(collector.nestedError(), abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(hook.accruedFees(NATIVE), fees);
        assertEq(address(collector).balance, 0);

        // The failed attempt rolled the collection guard back, so a normal collection still works.
        address payee = makeAddr("payee");
        collector.collect(NATIVE, fees, payee);
        assertEq(payee.balance, fees);
        assertEq(hook.accruedFees(NATIVE), 0);
    }

    function test_claimsMintedToHookByThirdPartyOnlyReachBeneficiary() public {
        address beneficiary = makeAddr("beneficiary");
        SuperIMDHook hook = _deploy(manager, beneficiary);
        ClaimDonor donor = new ClaimDonor(manager);
        vm.deal(address(this), 5 ether);
        donor.donate{value: 5 ether}(address(hook), 5 ether);
        assertEq(hook.accruedFees(NATIVE), 5 ether);

        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(SuperIMDHook.NotFeeRecipient.selector);
        hook.collectFees(NATIVE, 5 ether, thief);

        vm.prank(beneficiary);
        hook.collectFees(NATIVE, 5 ether, beneficiary);
        assertEq(beneficiary.balance, 5 ether);
        assertEq(hook.accruedFees(NATIVE), 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
    }

    function test_collectingNeverAccruedCurrencyRevertsWithoutSideEffects() public {
        address beneficiary = makeAddr("beneficiary");
        SuperIMDHook hook = _deploy(manager, beneficiary);
        PoolKey memory k = _pool(hook);
        _sell(k, 1 ether);
        uint256 nativeFees = hook.accruedFees(NATIVE);
        Currency simd = Currency.wrap(address(token));
        assertEq(hook.accruedFees(simd), 0);
        vm.prank(beneficiary);
        vm.expectRevert();
        hook.collectFees(simd, 1, beneficiary);
        assertEq(hook.accruedFees(NATIVE), nativeFees);
        assertEq(token.balanceOf(beneficiary), 0);
        // Collection also stays usable afterwards.
        vm.prank(beneficiary);
        hook.collectFees(NATIVE, nativeFees, beneficiary);
        assertEq(beneficiary.balance, nativeFees);
    }

    function test_poolOnForeignManagerCannotSwapThroughHook() public {
        SuperIMDHook hook = _deploy(manager, makeAddr("beneficiary"));
        PoolManager foreign = new PoolManager(address(this));
        PoolHarness foreignRouter = new PoolHarness(foreign);
        token.transfer(address(foreignRouter), 1_000_000 ether);
        vm.deal(address(foreignRouter), 1_000_000 ether);
        PoolKey memory k = PoolKey(NATIVE, Currency.wrap(address(token)), 0, 60, hook);
        foreign.initialize(k, 1 << 96);
        foreignRouter.liquidity(k, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        foreignRouter.swap(k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), 0, type(uint256).max);
        assertEq(hook.accruedFees(NATIVE), 0);
        // LPs on the foreign manager can still exit.
        foreignRouter.liquidity(k, ModifyLiquidityParams(-600, 600, -100_000 ether, bytes32(0)));
    }

    function test_feeStillChargedWhenDustSwapsAreBatchedInOneLargeSwap() public {
        SuperIMDHook hook = _deploy(manager, makeAddr("beneficiary"));
        PoolKey memory k = _pool(hook);
        // 49 base units of output round the fee to zero; this is the per-swap floor documented as residual.
        for (uint256 i; i < 3; ++i) {
            _sell(k, 49);
        }
        assertEq(hook.accruedFees(NATIVE), 0);
        _sell(k, 10_000);
        assertGt(hook.accruedFees(NATIVE), 0);
        assertLe(hook.accruedFees(NATIVE) * 50, 10_000);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_factoryRejectsEveryNonOwner(address caller, bytes32 salt) public {
        address owner = makeAddr("owner");
        vm.assume(caller != owner);
        SuperIMDHookFactory factory = new SuperIMDHookFactory(owner, makeAddr("beneficiary"), address(token));
        IPoolManager pm = IPoolManager(address(new AccountingMock()));
        vm.prank(caller);
        vm.expectRevert(SuperIMDHookFactory.NotOwner.selector);
        factory.setPoolManager(pm);
        vm.prank(owner);
        factory.setPoolManager(pm);
        vm.prank(caller);
        vm.expectRevert(SuperIMDHookFactory.NotOwner.selector);
        factory.deployHook(salt);
        assertEq(address(factory.hook()), address(0));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_factoryDeploysOnlyAtPredictedFlaggedAddress(bytes32 salt) public {
        address owner = makeAddr("owner");
        SuperIMDHookFactory factory = new SuperIMDHookFactory(owner, makeAddr("beneficiary"), address(token));
        vm.prank(owner);
        factory.setPoolManager(manager);
        address predicted = factory.predictHookAddress(salt);
        bool flagged = (uint160(predicted) & Hooks.ALL_HOOK_MASK) == factory.HOOK_FLAGS();
        vm.prank(owner);
        if (!flagged) {
            vm.expectRevert(
                abi.encodeWithSelector(SuperIMDHookFactory.InvalidHookAddress.selector, predicted)
            );
            factory.deployHook(salt);
            assertEq(address(factory.hook()), address(0));
        } else {
            SuperIMDHook deployed = factory.deployHook(salt);
            assertEq(address(deployed), predicted);
        }
    }

    function test_factoryFlagsMatchHookPermissions() public {
        SuperIMDHook hook = _deploy(manager, makeAddr("beneficiary"));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_FLAG) == p.afterSwap);
        assertTrue(
            Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                == p.afterSwapReturnDelta
        );
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_INITIALIZE_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
    }

    receive() external payable {}
}
