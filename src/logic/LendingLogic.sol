// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title LendingLogic
 * @notice External contract for lending calculations in UnifiedVault
 * @dev Deployed once, referenced by all vaults via Registry
 *      Reduces vault bytecode and enables logic upgrades
 */
contract LendingLogic {
    uint256 public constant ONE = 1e18;
    
    /**
     * @notice Calculate borrow balance with accrued interest
     * @param principal Original borrow principal
     * @param userIndex User's borrow index at time of borrow
     * @param currentIndex Current global borrow index
     * @return Current borrow balance including interest
     */
    function calculateBorrowBalance(
        uint256 principal,
        uint256 userIndex,
        uint256 currentIndex
    ) external pure returns (uint256) {
        if (principal == 0) return 0;
        return (principal * currentIndex) / userIndex;
    }
    
    /**
     * @notice Calculate health factor for a position
     * @param collateralValue Value of collateral in USDC (scaled 1e18)
     * @param debtValue Value of debt in USDC (scaled 1e18)
     * @param collateralFactor Collateral factor (scaled 1e18, e.g., 0.5e18 = 50%)
     * @return Health factor (scaled 1e18, >= 1e18 is healthy)
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralFactor
    ) external pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        if (collateralValue == 0) return 0;
        
        uint256 adjustedCollateral = (collateralValue * collateralFactor) / ONE;
        return (adjustedCollateral * ONE) / debtValue;
    }
    
    /**
     * @notice Calculate maximum borrowable amount
     * @param collateralValue Value of collateral in USDC
     * @param currentDebt Current debt
     * @param collateralFactor Collateral factor
     * @return Maximum additional borrowable amount
     */
    function calculateMaxBorrow(
        uint256 collateralValue,
        uint256 currentDebt,
        uint256 collateralFactor
    ) external pure returns (uint256) {
        uint256 maxDebt = (collateralValue * collateralFactor) / ONE;
        if (maxDebt <= currentDebt) return 0;
        return maxDebt - currentDebt;
    }
    
    /**
     * @notice Calculate liquidation amounts
     * @param repayAmount Amount being repaid
     * @param liquidationBonus Bonus for liquidator (scaled 1e18)
     * @param collateralPrice Price of collateral (scaled 1e18)
     * @param borrowerCollateral Borrower's collateral balance
     * @return seizeAmount Amount of collateral to seize
     * @return cappedRepay Actual repay amount (may be capped)
     */
    function calculateLiquidation(
        uint256 repayAmount,
        uint256 liquidationBonus,
        uint256 collateralPrice,
        uint256 borrowerCollateral
    ) external pure returns (uint256 seizeAmount, uint256 cappedRepay) {
        // Calculate collateral value to seize (with bonus)
        uint256 seizeValue = (repayAmount * (ONE + liquidationBonus)) / ONE;
        seizeAmount = (seizeValue * ONE) / collateralPrice;
        
        // Cap at borrower's collateral
        if (seizeAmount > borrowerCollateral) {
            seizeAmount = borrowerCollateral;
            // Recalculate repay based on capped seize
            uint256 actualSeizeValue = (seizeAmount * collateralPrice) / ONE;
            cappedRepay = (actualSeizeValue * ONE) / (ONE + liquidationBonus);
        } else {
            cappedRepay = repayAmount;
        }
    }
    
    /**
     * @notice Calculate utilization rate
     * @param totalBorrows Total borrowed amount
     * @param totalLiquidity Total liquidity (borrows + available)
     * @return Utilization rate (scaled 1e18)
     */
    function calculateUtilization(
        uint256 totalBorrows,
        uint256 totalLiquidity
    ) external pure returns (uint256) {
        if (totalLiquidity == 0) return 0;
        return (totalBorrows * ONE) / totalLiquidity;
    }
}
