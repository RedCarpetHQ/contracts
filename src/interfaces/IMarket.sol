// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title IMarketView
 * @notice View interface for Market contract
 */
interface IMarketView {
    function getTokenOffers(address token) external view returns (uint256[] memory);
    function offers(uint256 offerId) external view returns (
        uint256, address, address, uint8, address, uint256, uint256, uint256, uint256, uint8, uint256, bool
    );
    function getTokenOffersLength(address token) external view returns (uint256);
    function getMarketDepth(address token) external view returns (uint256 buyDepth, uint256 sellDepth);
}

/**
 * @title IMarketFill
 * @notice Interface for Market fill operations
 */
interface IMarketFill {
    function fillBuyOffer(uint256 offerId, uint256 tokenAmount) external;
    function fillSellOffer(uint256 offerId, uint256 tokenAmount) external;
}
