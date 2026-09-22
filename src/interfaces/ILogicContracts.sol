// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title IInterestLogic
 * @notice Interface for InterestLogic external contract
 */
interface IInterestLogic {
    function calculateInterest(
        uint256 totalBorrows,
        uint256 borrowRatePerSecond,
        uint256 elapsed,
        uint256 currentBorrowIndex
    ) external pure returns (uint256 interestAccumulated, uint256 newBorrowIndex);
    
    function getInterestSplit(uint8 riskTier) external pure returns (
        uint256 protocolPct,
        uint256 insurancePct,
        uint256 lenderPct
    );
    
    function distributeInterest(
        uint256 interestAccumulated,
        uint8 riskTier
    ) external pure returns (
        uint256 toProtocol,
        uint256 toInsurance,
        uint256 toLenders
    );
    
    function calculateAPY(uint256 ratePerSecond) external pure returns (uint256 apy);
}

/**
 * @title ILendingLogic
 * @notice Interface for LendingLogic external contract
 */
interface ILendingLogic {
    function calculateBorrowBalance(
        uint256 principal,
        uint256 userIndex,
        uint256 currentIndex
    ) external pure returns (uint256);
    
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralFactor
    ) external pure returns (uint256);
    
    function calculateMaxBorrow(
        uint256 collateralValue,
        uint256 currentDebt,
        uint256 collateralFactor
    ) external pure returns (uint256);
    
    function calculateLiquidation(
        uint256 repayAmount,
        uint256 liquidationBonus,
        uint256 collateralPrice,
        uint256 borrowerCollateral
    ) external pure returns (uint256 seizeAmount, uint256 cappedRepay);
    
    function calculateUtilization(
        uint256 totalBorrows,
        uint256 totalLiquidity
    ) external pure returns (uint256);
}

/**
 * @title IStabilityLogic
 * @notice Interface for StabilityLogic external contract
 */
interface IStabilityLogic {
    function calculatePendingGains(
        uint256 userDeposit,
        uint256 userSnapshotS,
        uint256 currentS
    ) external pure returns (uint256 pendingGain);
    
    function calculateCompoundedDeposit(
        uint256 initialDeposit,
        uint256 userSnapshotP,
        uint256 userSnapshotEpoch,
        uint256 userSnapshotScale,
        uint256 currentP,
        uint256 currentEpoch,
        uint256 currentScale
    ) external pure returns (uint256 compoundedDeposit);
    
    function updateS(
        uint256 currentS,
        uint256 collateralGained,
        uint256 totalStabilityDeposits
    ) external pure returns (uint256 newS);
    
    function calculateAllocation(
        uint256 amount,
        uint256 lendingRatio,
        uint256 maxBps
    ) external pure returns (uint256 toLending, uint256 toStability);
}

