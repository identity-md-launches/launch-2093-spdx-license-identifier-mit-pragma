// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Drives SuperIMD with several signing actors. Every call either succeeds with the modelled
///      effect or fails with the expected error and no state change; nothing reverts out of the handler.
contract TokenHandler is Test {
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 constant ACTORS = 5;

    SuperIMD public token;
    uint256[ACTORS] internal keys;
    address[ACTORS] public actors;

    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;
    mapping(address => uint256) public modelNonce;

    uint256 public successfulMoves;
    uint256 public rejectedMoves;
    uint256 public permitsUsed;
    uint256 public permitsRejected;

    constructor() {
        for (uint256 i; i < ACTORS; ++i) {
            keys[i] = uint256(keccak256(abi.encode("simd actor", i))) % (2 ** 200) + 1;
            actors[i] = vm.addr(keys[i]);
        }
    }

    /// @dev The model starts from the constructor's outcome: the whole supply held by the first actor.
    function bind(SuperIMD token_) external {
        require(address(token) == address(0), "bound");
        token = token_;
        modelBalance[actors[0]] = token_.totalSupply();
    }

    function actorCount() external pure returns (uint256) {
        return ACTORS;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTORS];
    }

    function _snapshot(address a, address b) internal view returns (uint256, uint256, uint256) {
        return (token.balanceOf(a), token.balanceOf(b), token.totalSupply());
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount, bool toZero) external {
        address from = _actor(fromSeed);
        address to = toZero && toSeed % 8 == 0 ? address(0) : _actor(toSeed);
        uint256 balance = modelBalance[from];
        // Includes amounts just above the balance so failure paths are exercised.
        amount = bound(amount, 0, balance + 2);
        (uint256 fromBefore, uint256 toBefore, uint256 supplyBefore) = _snapshot(from, to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(to != address(0), "transfer to zero accepted");
            assertLe(amount, balance, "transfer above balance accepted");
            modelBalance[from] -= amount;
            modelBalance[to] += amount;
            ++successfulMoves;
        } catch (bytes memory reason) {
            if (to == address(0)) {
                assertEq(
                    reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
                );
            } else {
                assertGt(amount, balance, "valid transfer rejected");
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount
                    )
                );
            }
            (uint256 fromAfter, uint256 toAfter, uint256 supplyAfter) = _snapshot(from, to);
            assertEq(fromAfter, fromBefore);
            assertEq(toAfter, toBefore);
            assertEq(supplyAfter, supplyBefore);
            ++rejectedMoves;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = infinite ? type(uint256).max : bound(amount, 0, token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        modelAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowance = modelAllowance[owner][spender];
        uint256 balance = modelBalance[owner];
        uint256 cap = allowance == type(uint256).max ? balance : allowance;
        amount = bound(amount, 0, (cap > balance ? cap : balance) + 2);
        (uint256 ownerBefore, uint256 toBefore,) = _snapshot(owner, to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            assertTrue(ok);
            assertLe(amount, allowance, "spent above allowance");
            assertLe(amount, balance, "spent above balance");
            if (allowance != type(uint256).max) modelAllowance[owner][spender] = allowance - amount;
            modelBalance[owner] -= amount;
            modelBalance[to] += amount;
            ++successfulMoves;
        } catch (bytes memory reason) {
            // Allowance is checked before balance by OpenZeppelin's _spendAllowance.
            if (amount > allowance) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount
                    )
                );
            } else {
                assertGt(amount, balance, "valid transferFrom rejected");
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount
                    )
                );
            }
            (uint256 ownerAfter, uint256 toAfter,) = _snapshot(owner, to);
            assertEq(ownerAfter, ownerBefore);
            assertEq(toAfter, toBefore);
            assertEq(token.allowance(owner, spender), allowance);
            ++rejectedMoves;
        }
    }

    struct PermitCase {
        address owner;
        address spender;
        uint256 value;
        uint256 submitted;
        uint256 deadline;
        uint256 nonce;
        uint256 signer;
        uint8 mode;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @param mode 0 valid, 1 tampered value, 2 stale nonce, 3 expired, 4 wrong signer, 5 replay of a used permit.
    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 ttl, uint8 mode) external {
        PermitCase memory c;
        uint256 ownerIndex = ownerSeed % ACTORS;
        c.owner = actors[ownerIndex];
        c.spender = _actor(spenderSeed);
        c.value = value;
        c.mode = uint8(bound(mode, 0, 5));
        c.deadline = c.mode == 3 ? block.timestamp - 1 : block.timestamp + bound(ttl, 0, 365 days);
        c.nonce = modelNonce[c.owner];
        if (c.mode == 2 || c.mode == 5) {
            if (c.nonce == 0) c.mode = 1;
            else c.nonce -= 1;
        }
        c.signer = c.mode == 4 ? keys[(ownerIndex + 1) % ACTORS] : keys[ownerIndex];
        c.submitted = c.mode == 1 ? (value == 0 ? 1 : value - 1) : value;
        _sign(c);
        // The relayer is arbitrary: permit authorisation never depends on msg.sender.
        _submit(c, _actor(spenderSeed % ACTORS + 1));
    }

    function _sign(PermitCase memory c) internal view {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, c.owner, c.spender, c.value, c.nonce, c.deadline))
            )
        );
        (c.v, c.r, c.s) = vm.sign(c.signer, digest);
    }

    function _submit(PermitCase memory c, address relayer) internal {
        uint256 allowanceBefore = token.allowance(c.owner, c.spender);
        vm.prank(relayer);
        try token.permit(c.owner, c.spender, c.submitted, c.deadline, c.v, c.r, c.s) {
            assertEq(c.mode, 0, "invalid permit accepted");
            modelAllowance[c.owner][c.spender] = c.value;
            ++modelNonce[c.owner];
            ++permitsUsed;
        } catch (bytes memory reason) {
            assertTrue(c.mode != 0, "valid permit rejected");
            if (c.mode == 3) {
                assertEq(
                    reason, abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, c.deadline)
                );
            } else {
                assertEq(bytes4(reason), ERC20Permit.ERC2612InvalidSigner.selector);
            }
            assertEq(token.allowance(c.owner, c.spender), allowanceBefore);
            assertEq(token.nonces(c.owner), modelNonce[c.owner]);
            ++permitsRejected;
        }
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 30 days));
    }
}

contract SuperIMDInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    SuperIMD token;
    TokenHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new TokenHandler();
        token = new SuperIMD(SUPPLY, handler.actors(0));
        handler.bind(token);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.permit.selector;
        selectors[4] = TokenHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous handler: each path, success and failure, is reachable.
    function test_handlerReachesEveryPath() public {
        handler.transfer(0, 1, 100 ether, false);
        handler.transfer(2, 1, 1, false); // actor 2 holds nothing: rejected
        handler.transfer(0, 0, 1, true); // to the zero address: rejected
        handler.approve(1, 2, 60 ether, false);
        handler.transferFrom(2, 1, 3, 60 ether);
        handler.transferFrom(2, 1, 3, 1); // allowance exhausted: rejected
        for (uint8 mode; mode < 6; ++mode) {
            handler.permit(0, 4, 7 ether, 1 days, mode);
        }
        assertEq(handler.successfulMoves(), 2);
        assertEq(handler.rejectedMoves(), 3);
        assertEq(handler.permitsUsed(), 1);
        assertEq(handler.permitsRejected(), 5);
        assertEq(token.allowance(handler.actors(0), handler.actors(4)), 7 ether);
        assertEq(token.balanceOf(handler.actors(3)), 60 ether);
        invariant_supplyIsFixedAndFullyHeldByActors();
        invariant_balancesAllowancesAndNoncesMatchModel();
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixedAndFullyHeldByActors() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesAllowancesAndNoncesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.modelBalance(a));
            assertEq(token.nonces(a), handler.modelNonce(a));
            for (uint256 j; j < n; ++j) {
                address b = handler.actors(j);
                assertEq(token.allowance(a, b), handler.modelAllowance(a, b));
            }
        }
        assertEq(handler.permitsUsed(), _sumNonces());
    }

    function _sumNonces() internal view returns (uint256 total) {
        for (uint256 i; i < handler.actorCount(); ++i) {
            total += token.nonces(handler.actors(i));
        }
    }
}
