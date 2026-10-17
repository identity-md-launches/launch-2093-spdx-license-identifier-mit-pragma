// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SuperIMDTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 private constant HOLDER_TEST_KEY = 0x123456;
    SuperIMD token;
    address holder;
    address spender;
    address receiver;

    function setUp() public {
        holder = vm.addr(HOLDER_TEST_KEY);
        spender = makeAddr("spender");
        receiver = makeAddr("receiver");
        token = new SuperIMD(SUPPLY, holder);
    }

    function test_metadataAndExactSupply() public view {
        assertEq(token.name(), "Super IMD");
        assertEq(token.symbol(), "SIMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFuzz_rejectsEveryOtherSupply(uint256 amount) public {
        vm.assume(amount != SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(SuperIMD.IncorrectInitialSupply.selector, amount));
        new SuperIMD(amount, holder);
    }

    function test_rejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new SuperIMD(SUPPLY, address(0));
    }

    function testFuzz_transferHasNoFeeAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        assertTrue(token.transfer(receiver, amount));
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(receiver), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromHasNoFeeAndSpendsAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(holder, receiver, amount);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(receiver), amount);
        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceRemainsUnchanged() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(holder, receiver, 1 ether);
        assertEq(token.allowance(holder, spender), type(uint256).max);
    }

    function test_transferFailureDoesNotChangeBalances() public {
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        token.transfer(receiver, SUPPLY + 1);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        token.transferFrom(holder, receiver, 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_noPublicMintBurnOrAdmin() public {
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", receiver, 1));
        (bool burnOk,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(mintOk);
        assertFalse(burnOk);
        assertFalse(ownerOk);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _sign(SuperIMD target, uint256 nonce, uint256 deadline, uint256 amount)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", target.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(HOLDER_TEST_KEY, digest);
    }

    function test_permitRelayedThenSpentAndReplayRejected() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, 0, deadline, 15 ether);
        vm.prank(receiver);
        token.permit(holder, spender, 15 ether, deadline, v, r, s);
        assertEq(token.nonces(holder), 1);
        vm.prank(spender);
        token.transferFrom(holder, receiver, 15 ether);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 15 ether, deadline, v, r, s);
        assertEq(token.nonces(holder), 1);
        assertEq(token.balanceOf(receiver), 15 ether);
    }

    function test_permitValidAtDeadlineButNotAfter() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, 0, deadline, 12);
        vm.warp(deadline);
        token.permit(holder, spender, 12, deadline, v, r, s);
        (v, r, s) = _sign(token, 1, deadline, 13);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(holder, spender, 13, deadline, v, r, s);
        assertEq(token.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 12);
    }

    function test_permitRejectsAlteredValueAndWrongNonce() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, 0, deadline, 12);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 13, deadline, v, r, s);
        (v, r, s) = _sign(token, 1, deadline, 12);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 12, deadline, v, r, s);
        assertEq(token.nonces(holder), 0);
        assertEq(token.allowance(holder, spender), 0);
    }

    function test_permitRejectsCrossContractAndCrossChainReplay() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, 0, deadline, 12);
        SuperIMD other = new SuperIMD(SUPPLY, holder);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(holder, spender, 12, deadline, v, r, s);
        bytes32 originalDomain = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertNotEq(token.DOMAIN_SEPARATOR(), originalDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 12, deadline, v, r, s);
        assertEq(token.nonces(holder), 0);
    }

    function test_permitRejectsZeroSpenderAndMalformedSignature() public {
        uint256 deadline = block.timestamp + 100;
        spender = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, 0, deadline, 12);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(holder, spender, 12, deadline, v, r, s);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(holder, receiver, 12, deadline, 0, bytes32(0), bytes32(0));
        assertEq(token.nonces(holder), 0);
    }
}
