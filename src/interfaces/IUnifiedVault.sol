// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

interface IUnifiedVault {
    // ERC4626 functions
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function collectProtocolIncome() external returns (uint256);
    
    // Producer Exit function
    function sweepInsuranceFund(address recipient) external returns (uint256);
    
    // FeeDistributor function - deposit directly to insurance fund
    function depositToInsuranceFund(uint256 amount) external;
    
    // ERC4626 view functions
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    
    // Pool balance view function
    function getPoolBalances() external view returns (
        uint256 lending,
        uint256 stability,
        uint256 insurance,
        uint256 borrows
    );
    
    // Price oracle interface (for casting in FeeDistributor)
    function getPrice(address token) external view returns (uint256 price, bool reliable);
    
    // Lending view functions
    function totalBorrows() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getBorrowRate() external view returns (uint256);
    function getUserPosition(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 healthFactor,
        uint256 maxBorrow,
        uint256 liquidationPrice
    );
}
