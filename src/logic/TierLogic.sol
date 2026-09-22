// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "../interfaces/ITierLogic.sol";
import "../interfaces/IVolumeTracker.sol";
import "../Registry.sol";

/**
 * @title TierLogic
 * @notice Fee discount tier calculation logic with hardcoded thresholds
 * @dev PURE LOGIC CONTRACT - No storage, queries VolumeTracker for volume data
 * 
 * TIER STRUCTURE (HARDCODED):
 * - BRONZE: 100k USDC 30d volume → 50 bps (0.5%) discount → 2.0% fee (from 2.5%)
 * - SILVER: 500k USDC 30d volume → 100 bps (1.0%) discount → 1.5% fee
 * - GOLD: 2M USDC 30d volume → 150 bps (1.5%) discount → 1.0% fee
 * 
 * ARCHITECTURE:
 * - Registry stores TierLogic address
 * - Market queries TierLogic via Registry for fee discount
 * - TierLogic queries VolumeTracker via Registry for volume data
 * - To update tiers: Deploy new TierLogic, update Registry address
 * - Volume data persists in VolumeTracker (not lost when TierLogic is replaced)
 */
contract TierLogic is ITierLogic {
    
    // Tier constants
    uint8 public constant TIER_NONE = 0;
    uint8 public constant TIER_BRONZE = 1;
    uint8 public constant TIER_SILVER = 2;
    uint8 public constant TIER_GOLD = 3;
    
    // Hardcoded tier thresholds (can be changed by deploying new TierLogic)
    uint256 public constant BRONZE_VOLUME = 100_000e6;    // 100k USDC
    uint256 public constant BRONZE_DISCOUNT = 50;         // 0.5% discount
    
    uint256 public constant SILVER_VOLUME = 500_000e6;    // 500k USDC
    uint256 public constant SILVER_DISCOUNT = 100;        // 1.0% discount
    
    uint256 public constant GOLD_VOLUME = 2_000_000e6;    // 2M USDC
    uint256 public constant GOLD_DISCOUNT = 150;          // 1.5% discount
    
    // Registry address (to query for VolumeTracker)
    address public immutable registry;
    
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = _registry;
    }
    
    /**
     * @notice Get trader's fee discount based on their 30-day volume
     * @param trader Address of the trader
     * @return feeDiscountBps Fee discount in basis points (0 if no tier qualified)
     */
    function getFeeDiscount(address trader) external view returns (uint256 feeDiscountBps) {
        // Get VolumeTracker from Registry
        address volumeTracker = Registry(registry).volumeTracker();
        if (volumeTracker == address(0)) return 0; // VolumeTracker not set
        
        // Get 30-day rolling volume
        uint256 totalVolume = IVolumeTracker(volumeTracker).getRollingVolume(trader, 30);
        
        // Check tiers from highest to lowest (GOLD > SILVER > BRONZE)
        if (totalVolume >= GOLD_VOLUME) {
            return GOLD_DISCOUNT;
        }
        if (totalVolume >= SILVER_VOLUME) {
            return SILVER_DISCOUNT;
        }
        if (totalVolume >= BRONZE_VOLUME) {
            return BRONZE_DISCOUNT;
        }
        
        return 0; // No discount
    }
    
    /**
     * @notice Get trader's current tier based on 30-day volume
     * @param trader Address of the trader
     * @return tier Current tier (0=NONE, 1=BRONZE, 2=SILVER, 3=GOLD)
     */
    function getTier(address trader) external view returns (uint8 tier) {
        // Get VolumeTracker from Registry
        address volumeTracker = Registry(registry).volumeTracker();
        if (volumeTracker == address(0)) return TIER_NONE; // VolumeTracker not set
        
        // Get 30-day rolling volume
        uint256 totalVolume = IVolumeTracker(volumeTracker).getRollingVolume(trader, 30);
        
        if (totalVolume >= GOLD_VOLUME) {
            return TIER_GOLD;
        }
        if (totalVolume >= SILVER_VOLUME) {
            return TIER_SILVER;
        }
        if (totalVolume >= BRONZE_VOLUME) {
            return TIER_BRONZE;
        }
        
        return TIER_NONE;
    }
    
    /**
     * @notice Track volume - DEPRECATED
     * @dev Volume tracking moved to VolumeTracker contract
     * @dev Market should call VolumeTracker.trackVolume() directly
     */
    function trackVolume(address, uint256) external pure {
        revert("Use VolumeTracker.trackVolume()");
    }
    
    /**
     * @notice Get trader's current 30-day rolling volume
     * @param trader Address of the trader
     * @return volume Total volume in last 30 days
     */
    function getVolume(address trader) external view returns (uint256 volume) {
        // Get VolumeTracker from Registry
        address volumeTracker = Registry(registry).volumeTracker();
        if (volumeTracker == address(0)) return 0; // VolumeTracker not set
        
        // Get 30-day rolling volume from VolumeTracker
        return IVolumeTracker(volumeTracker).getRollingVolume(trader, 30);
    }
}
