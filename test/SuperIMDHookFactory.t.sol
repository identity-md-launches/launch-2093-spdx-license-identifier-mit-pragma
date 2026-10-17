// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SuperIMDHook} from "../src/SIMDhook.sol";
import {SuperIMDHookFactory} from "../src/SuperIMDHookFactory.sol";
import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";
import {MineHookSalt} from "../script/MineHookSalt.s.sol";
import {AccountingMock} from "./helpers/HookFixtures.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract ApplicationDeploymentProbe {
    function deploy(address owner) external returns (SuperIMD token, SuperIMDHookFactory factory) {
        token = new SuperIMD(1_000_000_000 ether, owner);
        factory = new SuperIMDHookFactory(owner, owner, address(token));
    }
}

contract HookFactoryTest is Test {
    SuperIMD token;
    SuperIMDHookFactory factory;
    IPoolManager manager;
    address owner;
    address beneficiary;

    event PoolManagerConfigured(address indexed previousManager, address indexed manager);
    event HookDeployed(address indexed hook, address indexed manager, bytes32 salt);

    function setUp() public {
        owner = makeAddr("launch owner");
        beneficiary = makeAddr("fee beneficiary");
        token = new SuperIMD(1_000_000_000 ether, owner);
        factory = new SuperIMDHookFactory(owner, beneficiary, address(token));
        manager = IPoolManager(address(new AccountingMock()));
    }

    function _configure() internal {
        vm.prank(owner);
        factory.setPoolManager(manager);
    }

    function _salt() internal view returns (address predicted, bytes32 salt) {
        return HookSaltMiner.mine(address(factory), factory.hookInitCodeHash(), 0, 200_000);
    }

    function test_factoryDeploymentKeepsExplicitOwnerAndBeneficiary() public {
        ApplicationDeploymentProbe probe = new ApplicationDeploymentProbe();
        (SuperIMD deployedToken, SuperIMDHookFactory deployedFactory) = probe.deploy(owner);
        assertEq(deployedToken.balanceOf(owner), 1_000_000_000 ether);
        assertEq(deployedToken.balanceOf(address(probe)), 0);
        assertEq(deployedFactory.owner(), owner);
        assertEq(deployedFactory.feeRecipient(), owner);
        assertEq(deployedFactory.projectToken(), address(deployedToken));
        assertEq(address(deployedFactory.poolManager()), address(0));
        assertEq(address(deployedFactory.hook()), address(0));
        _checkRuntime(address(deployedToken));
        _checkRuntime(address(deployedFactory));
    }

    function test_constructorDoesNotRequireExternalContracts() public {
        address futureToken = makeAddr("token not yet deployed");
        SuperIMDHookFactory futureFactory = new SuperIMDHookFactory(owner, beneficiary, futureToken);
        assertEq(futureFactory.projectToken(), futureToken);
        assertEq(futureToken.code.length, 0);
        vm.prank(owner);
        futureFactory.setPoolManager(manager);
        (, bytes32 salt) =
            HookSaltMiner.mine(address(futureFactory), futureFactory.hookInitCodeHash(), 0, 200_000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SuperIMDHookFactory.NoCode.selector, futureToken));
        futureFactory.deployHook(salt);
    }

    function test_rejectsZeroConstructorArguments() public {
        vm.expectRevert(SuperIMDHookFactory.ZeroAddress.selector);
        new SuperIMDHookFactory(address(0), beneficiary, address(token));
        vm.expectRevert(SuperIMDHookFactory.ZeroAddress.selector);
        new SuperIMDHookFactory(owner, address(0), address(token));
        vm.expectRevert(SuperIMDHookFactory.ZeroAddress.selector);
        new SuperIMDHookFactory(owner, beneficiary, address(0));
    }

    function test_notConfiguredFailsClearly() public {
        vm.expectRevert(SuperIMDHookFactory.NotConfigured.selector);
        factory.hookInitCodeHash();
        vm.expectRevert(SuperIMDHookFactory.NotConfigured.selector);
        factory.predictHookAddress(bytes32(0));
        vm.prank(owner);
        vm.expectRevert(SuperIMDHookFactory.NotConfigured.selector);
        factory.deployHook(bytes32(0));
    }

    function test_onlyOwnerCanConfigureAndDeploy() public {
        vm.expectRevert(SuperIMDHookFactory.NotOwner.selector);
        factory.setPoolManager(manager);
        _configure();
        (, bytes32 salt) = _salt();
        vm.expectRevert(SuperIMDHookFactory.NotOwner.selector);
        factory.deployHook(salt);
        assertEq(address(factory.hook()), address(0));
    }

    function test_configurationRejectsZeroAndNoCode() public {
        vm.startPrank(owner);
        vm.expectRevert(SuperIMDHookFactory.ZeroAddress.selector);
        factory.setPoolManager(IPoolManager(address(0)));
        vm.expectRevert(abi.encodeWithSelector(SuperIMDHookFactory.NoCode.selector, beneficiary));
        factory.setPoolManager(IPoolManager(beneficiary));
        vm.stopPrank();
    }

    function test_managerCanBeCorrectedBeforeDeploymentAndEmitsEvents() public {
        vm.expectEmit(true, true, false, true, address(factory));
        emit PoolManagerConfigured(address(0), address(manager));
        _configure();
        bytes32 firstHash = factory.hookInitCodeHash();
        IPoolManager replacement = IPoolManager(address(new AccountingMock()));
        vm.expectEmit(true, true, false, true, address(factory));
        emit PoolManagerConfigured(address(manager), address(replacement));
        vm.prank(owner);
        factory.setPoolManager(replacement);
        assertNotEq(factory.hookInitCodeHash(), firstHash);
        assertEq(address(factory.poolManager()), address(replacement));
    }

    function test_deploymentMatchesPredictionAndFreezesConfiguration() public {
        _configure();
        (address predicted, bytes32 salt) = _salt();
        assertEq(predicted, factory.predictHookAddress(salt));
        vm.expectEmit(true, true, false, true, address(factory));
        emit HookDeployed(predicted, address(manager), salt);
        vm.prank(owner);
        SuperIMDHook deployed = factory.deployHook(salt);
        assertEq(address(deployed), predicted);
        assertEq(address(factory.hook()), predicted);
        assertEq(deployed.feeRecipient(), beneficiary);
        assertEq(deployed.projectToken(), address(token));
        assertEq(address(deployed.poolManager()), address(manager));
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0x44);
        vm.startPrank(owner);
        vm.expectRevert(SuperIMDHookFactory.AlreadyDeployed.selector);
        factory.deployHook(salt);
        vm.expectRevert(SuperIMDHookFactory.AlreadyDeployed.selector);
        factory.setPoolManager(manager);
        vm.stopPrank();
        _checkRuntime(predicted);
        assertLe(type(SuperIMD).creationCode.length + 64, 49_152);
        assertLe(type(SuperIMDHookFactory).creationCode.length + 96, 49_152);
        assertLe(type(SuperIMDHook).creationCode.length + 96, 49_152);
    }

    function test_rejectsWrongSalt() public {
        _configure();
        bytes32 salt;
        address predicted = factory.predictHookAddress(salt);
        if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == 0x44) {
            salt = bytes32(uint256(1));
            predicted = factory.predictHookAddress(salt);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SuperIMDHookFactory.InvalidHookAddress.selector, predicted));
        factory.deployHook(salt);
    }

    function test_rechecksManagerCodeAtDeployment() public {
        _configure();
        (, bytes32 salt) = _salt();
        vm.etch(address(manager), "");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SuperIMDHookFactory.NoCode.selector, address(manager)));
        factory.deployHook(salt);
    }

    function test_offlineScriptMatchesFactoryAndFailsIfSearchExhausted() public {
        _configure();
        MineHookSalt script = new MineHookSalt();
        (address predicted, bytes32 salt) =
            script.run(address(factory), factory.hookInitCodeHash(), 0, 200_000);
        assertEq(predicted, factory.predictHookAddress(salt));
        bytes32 initCodeHash = factory.hookInitCodeHash();
        vm.expectRevert(HookSaltMiner.SaltNotFound.selector);
        script.run(address(factory), initCodeHash, 0, 0);
    }

    function _checkRuntime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
