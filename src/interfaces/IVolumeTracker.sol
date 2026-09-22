// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title IVolumeTracker
 * @notice Interface for centralized volume tracking
 */
interface IVolumeTracker {
    /**
     * @notice Track trader's daily volume (called by Market)
     * @param trader Address of the trader
     * @param volume Trade volume in USDC (6 decimals)
     */
    function trackVolume(address trader, uint256 volume) external;
    
    /**
     * @notice Get trader's volume for specific day
     * @param trader Address of the trader
     * @param dayIndex Day index (block.timestamp / 1 days)
     * @return volume Volume for that day
     */
    function getDailyVolume(address trader, uint256 dayIndex) external view returns (uint128);
    
    /**
     * @notice Get trader's rolling N-day volume
     * @param trader Address of the trader
     * @param numDays Number of days to look back
     * @return totalVolume Total volume over N days
     */
    function getRollingVolume(address trader, uint256 numDays) external view returns (uint256 totalVolume);
}
