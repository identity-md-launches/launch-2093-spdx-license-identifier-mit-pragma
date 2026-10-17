// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookSaltMiner} from "../src/libraries/HookSaltMiner.sol";

/// @notice Offline utility. No environment, filesystem, RPC, key or broadcast access.
contract MineHookSalt {
    function run(address factory, bytes32 initCodeHash, uint256 start, uint256 attempts)
        external
        pure
        returns (address predicted, bytes32 salt)
    {
        return HookSaltMiner.mine(factory, initCodeHash, start, attempts);
    }
}
