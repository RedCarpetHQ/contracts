// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title IVault
 * @notice Interface for UnifiedVault
 */
interface IVault {
    // View functions
    function totalAssets() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getBorrowRate() external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function collateralBalances(address account) external view returns (uint256);
    function getHealthFactor(address account) external view returns (uint256);
    
    function getUserPosition(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 health,
        uint256 stabilityDeposit,
        uint256 pendingCollateralGain
    );
    
    function getPoolBalances() external view returns (
        uint256 lending,
        uint256 stability,
        uint256 insurance,
        uint256 borrows
    );
    
    // Lending functions
    function depositCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;
    function repayFor(address borrower, uint256 amount) external;
    
    // Liquidation functions
    function liquidate(address borrower, uint256 repayAmount) external returns (uint256 seizeAmount);
    function liquidateViaStabilityPool(address borrower, uint256 repayAmount) external returns (uint256 seizeAmount);
    
    // Stability pool functions
    function claimCollateralGains() external;
    
    // Admin functions
    function triggerAccrueInterest() external;
    function collectProtocolIncome() external returns (uint256 collected);
    function setActive(bool _isActive) external;
    function pause() external;
    function unpause() external;
}

/**
 * @title IFeeDistributor
 * @notice Interface for FeeDistributor
 */
interface IFeeDistributor {
    function distributeFees(address token, uint256 amount) external;
    function claimProducerReward(address token) external returns (uint256 claimed);
    function flushToContest(address token, uint32 epoch) external;
    function getTokenFees(address token) external view returns (
        uint256 totalFeesReceived,
        uint256 toFeeSafe,
        uint256 toContest,
        uint256 toVault,
        uint256 toProducer
    );
}

/**
 * @title IMarket
 * @notice Interface for Market contract
 */
interface IMarket {
    struct Offer {
        uint256 offerId;
        address token;
        address paymentToken;
        uint8 offerType;
        address creator;
        uint256 tokenAmount;
        uint256 pricePerToken;
        uint256 filledAmount;
        uint256 escrowedAmount;
        uint8 status;
        uint256 createdAt;
        bool isBuyback;
    }
    
    function offers(uint256 offerId) external view returns (
        uint256, address, address, uint8, address, uint256, uint256, uint256, uint256, uint8, uint256, bool
    );
    function tokenOffers(address token, uint256 index) external view returns (uint256);
    function getTokenOffersLength(address token) external view returns (uint256);
    function fillBuyOffer(uint256 offerId, uint256 tokenAmount) external;
    function getMarketDepth(address token) external view returns (uint256 buyDepth, uint256 sellDepth);
}

/**
 * @title IRegistry
 * @notice Minimal interface for Registry
 */
interface IRegistry {
    function usdc() external view returns (address);
    function feeWallet() external view returns (address);
    function feeSafe() external view returns (address);
    function feeDistributor() external view returns (address);
    function contest() external view returns (address);
    function market() external view returns (address);
    function campaign() external view returns (address);
    function hybridPriceOracle() external view returns (address);
    function riskOracle() external view returns (address);
    function rateModel() external view returns (address);
    function lendingManager() external view returns (address);
    function keeper() external view returns (address);
    function getUnifiedVault(address token) external view returns (address);
    function isTokenGraduated(address token) external view returns (bool);
    function authorizedContracts(address) external view returns (bool);
}
