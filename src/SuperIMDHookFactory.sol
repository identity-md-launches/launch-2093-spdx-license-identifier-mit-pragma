// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SuperIMDHook} from "./SIMDhook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Launchable factory for one hook at an off-chain-mined CREATE2 address.
/// @dev No constructor calls or code checks. The owner configures the unprovided chain dependency
///      after launch. Deploying the hook permanently freezes that choice.
contract SuperIMDHookFactory {
    uint160 public constant HOOK_FLAGS = Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address public immutable owner;
    address public immutable feeRecipient;
    address public immutable projectToken;
    IPoolManager public poolManager;
    SuperIMDHook public hook;

    error ZeroAddress();
    error NotOwner();
    error NotConfigured();
    error AlreadyDeployed();
    error NoCode(address target);
    error InvalidHookAddress(address predicted);

    event PoolManagerConfigured(address indexed previousManager, address indexed manager);
    event HookDeployed(address indexed hook, address indexed manager, bytes32 salt);

    constructor(address owner_, address feeRecipient_, address projectToken_) {
        if (owner_ == address(0) || feeRecipient_ == address(0) || projectToken_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        feeRecipient = feeRecipient_;
        projectToken = projectToken_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setPoolManager(IPoolManager manager) external onlyOwner {
        if (address(hook) != address(0)) revert AlreadyDeployed();
        if (address(manager) == address(0)) revert ZeroAddress();
        if (address(manager).code.length == 0) revert NoCode(address(manager));
        emit PoolManagerConfigured(address(poolManager), address(manager));
        poolManager = manager;
    }

    function hookInitCodeHash() public view returns (bytes32) {
        if (address(poolManager) == address(0)) revert NotConfigured();
        return keccak256(
            bytes.concat(type(SuperIMDHook).creationCode, abi.encode(poolManager, feeRecipient, projectToken))
        );
    }

    function predictHookAddress(bytes32 salt) public view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash())))
            )
        );
    }

    /// @param salt Mined for this factory, init-code hash and exactly the low 14 bits 0x0044.
    function deployHook(bytes32 salt) external onlyOwner returns (SuperIMDHook deployed) {
        if (address(hook) != address(0)) revert AlreadyDeployed();
        address predicted = predictHookAddress(salt);
        if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) != HOOK_FLAGS) revert InvalidHookAddress(predicted);
        if (address(poolManager).code.length == 0) revert NoCode(address(poolManager));
        if (projectToken.code.length == 0) revert NoCode(projectToken);
        deployed = new SuperIMDHook{salt: salt}(poolManager, feeRecipient, projectToken);
        hook = deployed;
        emit HookDeployed(address(deployed), address(poolManager), salt);
    }
}
