// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Pure bounded search; use off chain, never as part of a deployment transaction.
library HookSaltMiner {
    error SaltNotFound();

    function mine(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (address predicted, bytes32 salt)
    {
        uint256 end = start + attempts;
        for (uint256 nonce = start; nonce < end; ++nonce) {
            salt = bytes32(nonce);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
            );
            if (
                (uint160(predicted) & Hooks.ALL_HOOK_MASK)
                    == (Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
            ) {
                return (predicted, salt);
            }
        }
        revert SaltNotFound();
    }
}
