// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title InterestLogic
 * @notice External contract for interest calculations in UnifiedVault
 * @dev Deployed once, referenced by all vaults via Registry
 *      Reduces vault bytecode and enables logic upgrades
 */
contract InterestLogic {
    uint256 public constant ONE = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Risk tiers
    uint8 public constant TIER_GREEN = 0;
    uint8 public constant TIER_YELLOW = 1;
    uint8 public constant TIER_RED = 2;
    
    /**
     * @notice Calculate interest accumulated over a period
     * @param totalBorrows Total borrowed amount
     * @param borrowRatePerSecond Borrow rate per second (scaled 1e18)
     * @param elapsed Seconds elapsed since last accrual
     * @param currentBorrowIndex Current borrow index
     * @return interestAccumulated Interest accumulated
     * @return newBorrowIndex New borrow index
     */
    function calculateInterest(
        uint256 totalBorrows,
        uint256 borrowRatePerSecond,
        uint256 elapsed,
        uint256 currentBorrowIndex
    ) external pure returns (uint256 interestAccumulated, uint256 newBorrowIndex) {
        if (totalBorrows == 0 || elapsed == 0) {
            return (0, currentBorrowIndex);
        }
        
        uint256 interestFactor = borrowRatePerSecond * elapsed;
        interestAccumulated = (totalBorrows * interestFactor) / ONE;
        
        // Update borrow index
        uint256 indexDelta = (currentBorrowIndex * interestFactor) / ONE;
        newBorrowIndex = currentBorrowIndex + indexDelta;
    }
    
    /**
     * @notice Get interest split percentages based on risk tier
     * @param riskTier Current risk tier (0=GREEN, 1=YELLOW, 2=RED)
     * @return protocolPct Protocol percentage (scaled to 100)
     * @return insurancePct Insurance percentage (scaled to 100)
     * @return lenderPct Lender percentage (scaled to 100)
     */
    function getInterestSplit(uint8 riskTier) external pure returns (
        uint256 protocolPct,
        uint256 insurancePct,
        uint256 lenderPct
    ) {
        if (riskTier == TIER_GREEN) {
            return (4, 6, 90);
        } else if (riskTier == TIER_YELLOW) {
            return (6, 9, 85);
        } else {
            // RED or unknown
            return (10, 15, 75);
        }
    }
    
    /**
     * @notice Calculate interest distribution amounts
     * @param interestAccumulated Total interest to distribute
     * @param riskTier Current risk tier
     * @return toProtocol Amount for protocol
     * @return toInsurance Amount for insurance fund
     * @return toLenders Amount for lenders
     */
    function distributeInterest(
        uint256 interestAccumulated,
        uint8 riskTier
    ) external pure returns (
        uint256 toProtocol,
        uint256 toInsurance,
        uint256 toLenders
    ) {
        (uint256 protocolPct, uint256 insurancePct, ) = _getInterestSplit(riskTier);
        
        toProtocol = (interestAccumulated * protocolPct) / 100;
        toInsurance = (interestAccumulated * insurancePct) / 100;
        toLenders = interestAccumulated - toProtocol - toInsurance; // Remainder to avoid rounding
    }
    
    /**
     * @notice Internal interest split calculation
     * @dev Used by distributeInterest to avoid external call in pure function
     */
    function _getInterestSplit(uint8 riskTier) internal pure returns (
        uint256 protocolPct,
        uint256 insurancePct,
        uint256 lenderPct
    ) {
        if (riskTier == TIER_GREEN) {
            return (4, 6, 90);
        } else if (riskTier == TIER_YELLOW) {
            return (6, 9, 85);
        } else {
            // RED or unknown
            return (10, 15, 75);
        }
    }
    
    /**
     * @notice Calculate APY from per-second rate
     * @param ratePerSecond Rate per second (scaled 1e18)
     * @return apy Annual percentage yield (scaled 1e18)
     */
    function calculateAPY(uint256 ratePerSecond) external pure returns (uint256 apy) {
        return ratePerSecond * SECONDS_PER_YEAR;
    }
}
