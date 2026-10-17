// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {AccountingMock, OriginalHook, OriginalToken} from "./helpers/HookFixtures.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract HookUnitTest is Test {
    SuperIMDHook hook;
    AccountingMock manager;
    address token;
    address beneficiary;
    PoolKey key;

    function setUp() public {
        token = makeAddr("SIMD");
        beneficiary = makeAddr("beneficiary");
        manager = new AccountingMock();
        hook = _deploy(IPoolManager(address(manager)), beneficiary, token);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, hook);
    }

    function _deploy(IPoolManager manager_, address beneficiary_, address token_)
        internal
        returns (SuperIMDHook)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(type(SuperIMDHook).creationCode, abi.encode(manager_, beneficiary_, token_))
        );
        (, bytes32 salt) = HookSaltMiner.mine(address(this), hash, 0, 200_000);
        return new SuperIMDHook{salt: salt}(manager_, beneficiary_, token_);
    }

    function _original() internal returns (OriginalHook original) {
        bytes32 hash = keccak256(
            abi.encodePacked(type(OriginalHook).creationCode, abi.encode(manager, beneficiary, token))
        );
        (, bytes32 salt) = HookSaltMiner.mine(address(this), hash, 0, 200_000);
        original = new OriginalHook{salt: salt}(IPoolManager(address(manager)), beneficiary, token);
    }

    function test_permissionsAndImmutableParameters() public view {
        Hooks.Permissions memory expected;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x44);
        assertEq(hook.FEE_BIPS(), 200);
        assertEq(hook.TOTAL_BIPS(), 10_000);
        assertEq(hook.feeRecipient(), beneficiary);
        assertEq(hook.projectToken(), token);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function testFuzz_feeArithmeticAllFourModes(bool exactInput, bool zeroForOne, uint128 magnitude) public {
        magnitude = uint128(bound(magnitude, 0, uint128(type(int128).max)));
        int128 amount = exactInput ? int128(magnitude) : -int128(magnitude);
        bool currency1 = exactInput == zeroForOne;
        BalanceDelta delta = currency1 ? toBalanceDelta(0, amount) : toBalanceDelta(amount, 0);
        vm.prank(address(manager));
        (bytes4 selector, int128 fee) = hook.afterSwap(
            address(this), key, SwapParams(zeroForOne, exactInput ? int256(-100) : int256(100), 0), delta, ""
        );
        uint256 expected = uint256(magnitude) * 200 / 10_000;
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(uint128(fee), expected);
        if (expected == 0) {
            assertEq(manager.mintCalls(), 0);
        } else {
            assertEq(manager.mintedTo(), address(hook));
            assertEq(manager.mintedId(), (currency1 ? key.currency1 : key.currency0).toId());
            assertEq(manager.mintedAmount(), expected);
            assertEq(manager.mintCalls(), 1);
        }
        assertEq(manager.takenAmount(), 0);
    }

    function test_roundingThresholds() public {
        uint128[5] memory amounts = [uint128(0), 49, 50, 99, 100];
        uint128[5] memory fees = [uint128(0), 0, 1, 1, 2];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(address(manager));
            (, int128 fee) = hook.afterSwap(
                address(this), key, SwapParams(true, -100, 0), toBalanceDelta(-100, int128(amounts[i])), ""
            );
            assertEq(uint128(fee), fees[i]);
        }
    }

    function test_minInt128ArithmeticDoesNotPanic() public {
        vm.prank(address(manager));
        (, int128 fee) = hook.afterSwap(
            address(this), key, SwapParams(true, 100, 0), toBalanceDelta(type(int128).min, 100), ""
        );
        assertEq(uint128(fee), (uint256(1) << 127) / 50);
    }

    function test_rejectsUnauthorizedAfterSwapAndCallback() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(manager), key, SwapParams(true, -100, 0), toBalanceDelta(-100, 100), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(Currency.wrap(address(0)), 1, beneficiary));
        vm.prank(address(manager));
        vm.expectRevert(SuperIMDHook.NoCollectionInProgress.selector);
        hook.unlockCallback(abi.encode(Currency.wrap(address(0)), 1, beneficiary));
    }

    function test_rejectsUnauthorizedFeeCollection() public {
        vm.expectRevert(SuperIMDHook.NotFeeRecipient.selector);
        hook.collectFees(key.currency1, 1, address(this));
    }

    function test_rejectsInvalidCollections() public {
        vm.startPrank(beneficiary);
        vm.expectRevert(SuperIMDHook.InvalidCollection.selector);
        hook.collectFees(key.currency1, 1, address(0));
        vm.expectRevert(SuperIMDHook.InvalidCollection.selector);
        hook.collectFees(key.currency1, 1, address(hook));
        vm.expectRevert(SuperIMDHook.InvalidCollection.selector);
        hook.collectFees(key.currency1, 0, beneficiary);
        vm.stopPrank();
    }

    function test_rejectsWrongPoolOrHook() public {
        key.currency1 = Currency.wrap(makeAddr("unrelated"));
        _expectInvalidPool();
        key.currency1 = Currency.wrap(token);
        key.hooks = IHooks(beneficiary);
        _expectInvalidPool();
        key.hooks = hook;
        key.currency0 = key.currency1;
        _expectInvalidPool();
    }

    function _expectInvalidPool() internal {
        vm.prank(address(manager));
        vm.expectRevert(SuperIMDHook.InvalidPool.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -100, 0), toBalanceDelta(-100, 100), "");
    }

    function test_rejectsUnexpectedDeltaSignAndZeroSpecifiedAmount() public {
        vm.startPrank(address(manager));
        vm.expectRevert(SuperIMDHook.InvalidSwapDelta.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -100, 0), toBalanceDelta(-100, -100), "");
        vm.expectRevert(SuperIMDHook.InvalidSwapDelta.selector);
        hook.afterSwap(address(this), key, SwapParams(true, 100, 0), toBalanceDelta(100, 100), "");
        vm.expectRevert(SuperIMDHook.InvalidSwapDelta.selector);
        hook.afterSwap(address(this), key, SwapParams(true, 0, 0), toBalanceDelta(0, 0), "");
        vm.stopPrank();
    }

    function test_disabledCallbacksFailClosedForEveryCaller() public {
        bytes[] memory calls = new bytes[](9);
        ModifyLiquidityParams memory lp;
        BalanceDelta zero = BalanceDelta.wrap(0);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, 0));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, 0, 0));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, SwapParams(true, -1, 0), ""));
        calls[7] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 0, 0, ""));
        calls[8] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 0, 0, ""));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory returned) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(returned, abi.encodeWithSelector(BaseHook.NotPoolManager.selector));
            vm.prank(address(manager));
            (ok, returned) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(returned, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
        }
    }

    function test_rejectsZeroAddresses() public {
        vm.expectRevert(BaseHook.ZeroAddress.selector);
        new SuperIMDHook(IPoolManager(address(0)), beneficiary, token);
        // Mining is local computation; expectRevert is set only immediately before CREATE2.
        bytes32 hash = keccak256(
            abi.encodePacked(type(SuperIMDHook).creationCode, abi.encode(manager, address(0), token))
        );
        (, bytes32 salt) = HookSaltMiner.mine(address(this), hash, 0, 200_000);
        vm.expectRevert(BaseHook.ZeroAddress.selector);
        new SuperIMDHook{salt: salt}(IPoolManager(address(manager)), address(0), token);
        hash = keccak256(
            abi.encodePacked(type(SuperIMDHook).creationCode, abi.encode(manager, beneficiary, address(0)))
        );
        (, salt) = HookSaltMiner.mine(address(this), hash, 0, 200_000);
        vm.expectRevert(BaseHook.ZeroAddress.selector);
        new SuperIMDHook{salt: salt}(IPoolManager(address(manager)), beneficiary, address(0));
    }

    function test_rejectsUnminedAddress() public {
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new SuperIMDHook(IPoolManager(address(manager)), beneficiary, token);
    }

    function test_regressionOriginalAllowsWrongSupply() public {
        OriginalToken original = new OriginalToken(1_000_000_000, beneficiary);
        assertEq(original.totalSupply(), 1_000_000_000); // Only 10^-9 whole SIMD at 18 decimals.
    }

    function test_regressionOriginalChargesUnrelatedPool() public {
        OriginalHook original = _original();
        key.hooks = original;
        key.currency1 = Currency.wrap(makeAddr("not SIMD"));
        vm.prank(address(manager));
        (, int128 fee) =
            original.afterSwap(address(this), key, SwapParams(true, -100, 0), toBalanceDelta(-100, 100), "");
        assertEq(fee, 2);
        assertEq(manager.takenAmount(), 2);
    }

    function test_regressionOriginalMinInt128Panics() public {
        OriginalHook original = _original();
        key.hooks = original;
        vm.prank(address(manager));
        vm.expectRevert(stdError.arithmeticError);
        original.afterSwap(
            address(this), key, SwapParams(true, 100, 0), toBalanceDelta(type(int128).min, 100), ""
        );
    }
}
