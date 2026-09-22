// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title ITierLogic
 * @notice Interface for fee discount tier calculation logic
 * @dev Separates tier logic from Registry (which only stores addresses)
 */
interface ITierLogic {
    /**
     * @notice Get trader's fee discount based on their 30-day volume
     * @param trader Address of the trader
     * @return feeDiscountBps Fee discount in basis points (0 if no tier qualified)
     */
    function getFeeDiscount(address trader) external view returns (uint256 feeDiscountBps);
    
    /**
     * @notice Get trader's current tier based on 30-day volume
     * @param trader Address of the trader
     * @return tier Current tier (0=NONE, 1=BRONZE, 2=SILVER, 3=GOLD)
     */
    function getTier(address trader) external view returns (uint8 tier);
    
    /**
     * @notice Track trader's buying volume (called by Market on each trade)
     * @param trader Address of the trader (buyer)
     * @param volume Trade volume in USDC (6 decimals)
     */
    function trackVolume(address trader, uint256 volume) external;
    
    /**
     * @notice Get trader's current 30-day rolling volume
     * @param trader Address of the trader
     * @return volume Total volume in last 30 days
     */
    function getVolume(address trader) external view returns (uint256 volume);
}
