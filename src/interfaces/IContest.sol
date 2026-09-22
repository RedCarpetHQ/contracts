// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

interface IContest {
    // Existing functions (unchanged)
    function getCurrentEpoch(address token) external view returns (uint32);
    function depositFees(address token, uint32 epoch, uint256 amount) external;
    function addBuyVolume(address token, address trader, uint128 volume) external;

    // V3 REDESIGN: New view function for estimated prize pool
    function getEstimatedPrizePool(
        address token,
        uint32 epoch
    ) external view returns (
        uint128 totalPrize,
        uint128 bounty,
        uint128 fees,
        uint128 accumulatedRollover,
        bool hasQualifiers,
        bool isFinalized
    );

    // V3 REDESIGN: Sweep dead epochs with gas rebate
    function sweepDeadEpochs(address token, uint32[] calldata deadEpochs) external;

    // Existing core functions
    function finalizeEpoch(address token, uint32 epoch) external;
    function claim(address token, uint32 epoch, address to) external;
    function claimBatch(address token, uint32[] calldata epochsToClaim, address to) external;

    // View helpers
    function getClaimableAmount(address token, uint32 epoch, address user) external view returns (uint256 amount, bool isFirstClaimer);
    function getEpochData(address token, uint32 epoch) external view returns (
        uint128 totalUsdcVolume,
        uint128 eligibleTotal,
        uint128 usdcPrize,
        uint128 rolloverPrize,
        bool finalized,
        uint256 qualifiedCount
    );
}
