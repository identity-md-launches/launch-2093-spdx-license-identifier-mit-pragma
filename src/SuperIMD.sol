// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Super IMD
/// @notice One billion SIMD, with 18 decimals, minted once to the explicit recipient.
///         Transfers have no fee. Fees apply only in pools using SuperIMDHook.
///         Website: https://www.si-md.xyz/ | X: https://x.com/SuperIMD_eth
contract SuperIMD is ERC20, ERC20Permit {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    error IncorrectInitialSupply(uint256 supplied);

    /// @param initialSupply Base units; must equal INITIAL_SUPPLY (10**27).
    /// @param recipient Receives the entire supply; cannot be zero.
    constructor(uint256 initialSupply, address recipient)
        ERC20("Super IMD", "SIMD")
        ERC20Permit("Super IMD")
    {
        if (initialSupply != INITIAL_SUPPLY) {
            revert IncorrectInitialSupply(initialSupply);
        }
        _mint(recipient, initialSupply);
    }
}
