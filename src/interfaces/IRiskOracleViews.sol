// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

interface IUnifiedVaultView {
    function getUtilization() external view returns (uint256);
    function getBadDebt() external view returns (uint256);
}

interface IPriceOracleView {
    function getPriceStaleness(address token) external view returns (uint256);
    function getPrice(address token) external view returns (uint256 price, bool reliable);
    function getVolume24h(address token) external view returns (uint256);
}

interface IOptimisticOracleView {
    function hasActiveDispute(address token) external view returns (bool);
}

interface IRiskOracleView {
    function getRiskTier(address token) external view returns (uint8);
    function updateRiskTier(address token) external returns (uint8);
    function TIER_GREEN() external view returns (uint8);
    function TIER_YELLOW() external view returns (uint8);
    function TIER_RED() external view returns (uint8);
    function getRecommendedSupplyCap(address token) external view returns (uint256);
    function getRecommendedBorrowCap(address token) external view returns (uint256);
    function isBorrowingAllowed(address token) external view returns (bool);
    function getMinLendingLiquidity(address token) external view returns (uint256);
}

// Full interface for RiskOracle contract (consolidates all previous definitions)
interface IRiskOracle {
    // View functions
    function getRiskTier(address token) external view returns (uint8);
    function updateRiskTier(address token) external returns (uint8);
    function getRecommendedSupplyCap(address token) external view returns (uint256);
    function getRecommendedBorrowCap(address token) external view returns (uint256);
    function isBorrowingAllowed(address token) external view returns (bool);
    function isBootstrapping(address token) external view returns (bool);
    function getMarketCap(address token) external view returns (uint256);
    function getMinLendingLiquidity(address token) external view returns (uint256);
    
    // Tier constants
    function TIER_GREEN() external view returns (uint8);
    function TIER_YELLOW() external view returns (uint8);
    function TIER_RED() external view returns (uint8);
    
    // Circuit breaker
    function circuitBreakerTriggered(address token) external view returns (bool);
    function checkCircuitBreaker(address token) external;
    function resetCircuitBreaker(address token) external;
    
    // Trade recording (called by Market)
    function recordTrade(address token, address maker, address taker, uint256 price) external;
}
