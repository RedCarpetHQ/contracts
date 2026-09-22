// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title ILendingInterfaces
 * @notice Core interfaces for the lending system
 */

// IRiskOracle interface moved to IRiskOracleViews.sol to avoid duplication

interface IRateModel {
    /// @notice Return borrow rate per second, scaled 1e18
    /// @param utilization utilization scaled 1e18 (0 to 1e18)
    /// @param riskTier risk tier (0=GREEN, 1=YELLOW, 2=RED)
    function getBorrowRatePerSecond(uint256 utilization, uint8 riskTier) external view returns (uint256);
}

interface IPriceOracle {
    /// @notice Return price of `asset` denominated in the borrow asset (e.g. USDC),
    ///         scaled 1e18 for consistency (even though USDC uses 6 decimals)
    function getPrice(address asset) external view returns (uint256 priceWad, bool reliable);
    
    /// @notice Update price for an asset (called by Market on trades)
    function updatePrice(address asset, uint256 priceWad, uint256 volumeWad) external;
    
    /// @notice Initialize price at campaign success (called by LendingManager)
    /// @param asset Token address
    /// @param initialVolume Campaign total raised in USDC (6 decimals)
    function initializePrice(address asset, uint256 initialVolume) external;
}

interface ILendingManager {
    /// @notice Create UnifiedVault on campaign success with immediate activation
    function createVaultsOnCampaignSuccess(address token) external returns (address vault);
    
    /// @notice Get vault status including activation time
    function getVaultStatus(address token) external view returns (
        bool exists,
        bool active,
        uint256 activationTime,
        uint256 timeRemaining
    );
}

interface ISafetyModule {
    /// @notice Cover vault shortfall using insurance fund and/or slashing
    /// @param shortfall USDC amount needed
    /// @return covered Actual amount covered
    function coverShortfall(uint256 shortfall) external returns (uint256 covered);
}

// Note: IRiskOracle interface is now defined in IRiskOracleViews.sol
