// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title ICampaign
 * @notice Interface for campaign contracts (SingleRoundCampaign / MultiRoundCampaign)
 * @dev Both SingleRoundCampaign and MultiRoundCampaign inherit BaseCampaign which implements
 *      the view functions below. Finalization functions differ per campaign type.
 */
interface ICampaign {
    /// @notice Get user's total purchase amount for a campaign
    function purchases(address token, address buyer) external view returns (uint256);
    
    /// @notice Get campaign status
    function getCampaignStatus(address token) external view returns (uint8);
    
    /// @notice Check if user can refund tokens
    function canRefund(address token, address user) external view returns (bool);
    
    /// @notice Get user's purchase amount
    function getUserPurchase(address token, address user) external view returns (uint256);
    
    /// @notice Public finalize a single-round campaign (after creator grace period)
    function publicFinalizeCampaign(address token) external;
}

/**
 * @title IMultiRoundCampaign
 * @notice Interface for MultiRoundCampaign finalization
 */
interface IMultiRoundCampaign {
    /// @notice Public finalize a multi-round campaign (after creator grace period)
    function publicFinalizeMultiRound(address token) external;
    
    /// @notice Get user's purchase amount (inherited from BaseCampaign)
    function getUserPurchase(address token, address user) external view returns (uint256);
}
