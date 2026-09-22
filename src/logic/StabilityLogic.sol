// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title StabilityLogic
 * @notice External contract for stability pool calculations in UnifiedVault
 * @dev Deployed once, referenced by all vaults via Registry
 *      Implements Liquity-style P/S system for collateral distribution
 *      Reduces vault bytecode and enables logic upgrades
 */
contract StabilityLogic {
    uint256 public constant ONE = 1e18;
    uint256 public constant SCALE_FACTOR = 1e9;
    
    /**
     * @notice Calculate user's pending collateral gains
     * @param userDeposit User's stability pool deposit
     * @param userSnapshotS User's last S snapshot
     * @param currentS Current S value
     * @return pendingGain Pending collateral gain
     */
    function calculatePendingGains(
        uint256 userDeposit,
        uint256 userSnapshotS,
        uint256 currentS
    ) external pure returns (uint256 pendingGain) {
        if (userDeposit == 0) return 0;
        if (currentS <= userSnapshotS) return 0;
        
        uint256 sDelta = currentS - userSnapshotS;
        pendingGain = (userDeposit * sDelta) / ONE;
    }
    
    /**
     * @notice Calculate user's compounded deposit after liquidations
     * @param initialDeposit User's initial deposit
     * @param userSnapshotP User's P snapshot at deposit time
     * @param userSnapshotEpoch User's epoch snapshot
     * @param userSnapshotScale User's scale snapshot
     * @param currentP Current P value
     * @param currentEpoch Current epoch
     * @param currentScale Current scale
     * @return compoundedDeposit Remaining deposit after losses
     */
    function calculateCompoundedDeposit(
        uint256 initialDeposit,
        uint256 userSnapshotP,
        uint256 userSnapshotEpoch,
        uint256 userSnapshotScale,
        uint256 currentP,
        uint256 currentEpoch,
        uint256 currentScale
    ) external pure returns (uint256 compoundedDeposit) {
        if (initialDeposit == 0) return 0;
        
        // If epoch changed, deposit is fully absorbed
        if (currentEpoch > userSnapshotEpoch) return 0;
        
        // Calculate scale difference
        uint256 scaleDiff = currentScale - userSnapshotScale;
        
        if (scaleDiff == 0) {
            // Same scale: simple P ratio
            compoundedDeposit = (initialDeposit * currentP) / userSnapshotP;
        } else if (scaleDiff == 1) {
            // One scale change
            compoundedDeposit = (initialDeposit * currentP) / (userSnapshotP * SCALE_FACTOR);
        } else {
            // Multiple scale changes: deposit is negligible
            compoundedDeposit = 0;
        }
    }
    
    /**
     * @notice Update S value after liquidation
     * @param currentS Current S value
     * @param collateralGained Collateral gained from liquidation
     * @param totalStabilityDeposits Total deposits in stability pool
     * @return newS Updated S value
     */
    function updateS(
        uint256 currentS,
        uint256 collateralGained,
        uint256 totalStabilityDeposits
    ) external pure returns (uint256 newS) {
        if (totalStabilityDeposits == 0) return currentS;
        
        uint256 collateralGainPerUnit = (collateralGained * ONE) / totalStabilityDeposits;
        newS = currentS + collateralGainPerUnit;
    }
    
    /**
     * @notice Calculate allocation split for deposits
     * @param amount Total amount to allocate
     * @param lendingRatio Lending ratio in basis points (e.g., 8000 = 80%)
     * @param maxBps Maximum basis points (10000)
     * @return toLending Amount for lending pool
     * @return toStability Amount for stability pool
     */
    function calculateAllocation(
        uint256 amount,
        uint256 lendingRatio,
        uint256 maxBps
    ) external pure returns (uint256 toLending, uint256 toStability) {
        toLending = (amount * lendingRatio) / maxBps;
        toStability = amount - toLending;
    }
}
