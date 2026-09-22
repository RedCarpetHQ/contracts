// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "../Registry.sol";

/**
 * @title VolumeTracker
 * @notice Centralized volume tracking for Market trades
 * @dev Used by both Contest (7-day) and TierLogic (30-day) calculations
 * 
 * ARCHITECTURE:
 * - Market calls trackVolume() on each trade
 * - TierLogic queries getRollingVolume(trader, 30) for tier calculation
 * - Contest queries getRollingVolume(trader, 7) for epoch qualification
 * 
 * BENEFITS:
 * - Single source of truth for all volume data
 * - TierLogic becomes pure logic (no storage)
 * - Volume persists when TierLogic is replaced
 * - Reusable for any future volume-based features
 */
contract VolumeTracker {
    
    // Registry address (for Market authorization)
    address public immutable registry;
    
    // Daily volume buckets: trader => dayIndex => volume
    // dayIndex = block.timestamp / 1 days (resets daily at midnight UTC)
    mapping(address => mapping(uint256 => uint128)) public dailyVolume;
    
    event VolumeTracked(address indexed trader, uint256 volume, uint256 dayIndex, uint256 timestamp);
    
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = _registry;
    }
    
    /**
     * @notice Track trader's daily volume (called by Market on each trade)
     * @param trader Address of the trader (buyer)
     * @param volume Trade volume in USDC (6 decimals)
     */
    function trackVolume(address trader, uint256 volume) external {
        // Only Market can track volume
        address market = Registry(registry).market();
        require(msg.sender == market, "Only Market");
        require(trader != address(0), "Invalid trader");
        require(volume > 0, "Invalid volume");
        
        uint256 currentDay = block.timestamp / 1 days;
        
        // Add volume to today's bucket (safe cast - volume is from USDC trades)
        dailyVolume[trader][currentDay] += uint128(volume);
        
        emit VolumeTracked(trader, volume, currentDay, block.timestamp);
    }
    
    /**
     * @notice Get trader's volume for specific day
     * @param trader Address of the trader
     * @param dayIndex Day index (block.timestamp / 1 days)
     * @return volume Volume for that day
     */
    function getDailyVolume(address trader, uint256 dayIndex) external view returns (uint128) {
        return dailyVolume[trader][dayIndex];
    }
    
    /**
     * @notice Get trader's rolling N-day volume
     * @dev Used by TierLogic (30 days) and Contest (7 days)
     * @param trader Address of the trader
     * @param numDays Number of days to look back (7 for Contest, 30 for TierLogic)
     * @return totalVolume Total volume over N days (including today)
     */
    function getRollingVolume(address trader, uint256 numDays) external view returns (uint256 totalVolume) {
        require(numDays > 0 && numDays <= 365, "Invalid numDays");
        
        uint256 currentDay = block.timestamp / 1 days;
        
        // Sum volume from last N days (including today)
        unchecked {
            for (uint256 i = 0; i < numDays; i++) {
                if (i > currentDay) break; // Stop if we would underflow
                uint256 dayIndex = currentDay - i;
                totalVolume += dailyVolume[trader][dayIndex];
            }
        }
        
        return totalVolume;
    }
    
    /**
     * @notice Get trader's volume for multiple days (batch query)
     * @param trader Address of the trader
     * @param startDay Starting day index
     * @param endDay Ending day index (inclusive)
     * @return volumes Array of daily volumes
     */
    function getBatchVolume(address trader, uint256 startDay, uint256 endDay) 
        external 
        view 
        returns (uint128[] memory volumes) 
    {
        require(endDay >= startDay, "Invalid range");
        require(endDay - startDay <= 365, "Range too large");
        
        uint256 length = endDay - startDay + 1;
        volumes = new uint128[](length);
        
        for (uint256 i = 0; i < length; i++) {
            volumes[i] = dailyVolume[trader][startDay + i];
        }
        
        return volumes;
    }
}
