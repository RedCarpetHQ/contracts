// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestUSDC
 * @notice Test USDC token for testing purposes
 * @dev Allows owner to mint tokens for testing
 */
contract TestUSDC is ERC20, Ownable {
    uint8 private _decimals;

    constructor(address _owner) ERC20("Test USDC", "USDC") {
        _transferOwnership(_owner);
        _decimals = 6; // USDC has 6 decimals
        // Mint initial supply to deployer
        _mint(_owner, 1_000_000_000_000 * 10 ** _decimals); // 1 trillion USDC
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens (only owner)
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
