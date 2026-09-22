// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

interface IVaultFactory {
    function deployVault(
        address vaultOwner,
        address token,
        string memory name,
        string memory symbol,
        address registry
    ) external returns (address vault);
    
    function lendingManager() external view returns (address);
    function setLendingManager(address _lendingManager) external;
}
