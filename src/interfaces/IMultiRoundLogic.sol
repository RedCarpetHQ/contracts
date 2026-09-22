// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title IMultiRoundLogic
 * @notice Interface for multi-round campaign logic
 * @dev Stateless helper contract for multi-round campaign operations
 */
interface IMultiRoundLogic {
    
    // Round state structure
    struct Round {
        uint256 roundId;
        uint256 floor;
        uint256 ceiling;
        uint8 overageType;
        uint40 startTime;
        uint40 endTime;
        uint256 totalRaised;
        uint256 tokensMinted;
        uint8 status;
        bool fundsCollected;
        uint16 uniqueBuyers;
    }
    
    // Campaign multi-round state
    struct MultiRoundState {
        uint256 totalRoundsCreated;
        uint256 currentRoundId;
        uint256 totalRaisedAllRounds;
        uint256 totalTokensMinted;
        bool isFinalized;
        uint256 createdAt;
        uint256 lastRoundEndTime;
        uint256 lastFundCollectionTime;
        uint256 lastFailedRoundTime;
    }
    
    /**
     * @notice Validate round creation parameters
     * @param multiRoundState Current multi-round state
     * @param lastSuccessfulFloor Floor of last successful round
     * @param hasSuccessfulRound Whether campaign has any successful round
     * @param floor New round floor
     * @param ceiling New round ceiling
     * @param overageType New round overage type
     * @param startTime New round start time
     * @param endTime New round end time
     * @return isValid Whether parameters are valid
     * @return errorMessage Error message if invalid
     */
    function validateRoundCreation(
        MultiRoundState memory multiRoundState,
        uint256 lastSuccessfulFloor,
        bool hasSuccessfulRound,
        uint256 floor,
        uint256 ceiling,
        uint8 overageType,
        uint256 startTime,
        uint256 endTime
    ) external view returns (bool isValid, string memory errorMessage);
    
    /**
     * @notice Check if campaign can be finalized by creator
     * @param multiRoundState Current multi-round state
     * @param hasSuccessfulRound Whether campaign has any successful round
     * @param currentRoundEnded Whether current round has ended
     * @return canFinalize Whether creator can finalize
     */
    function canCreatorFinalize(
        MultiRoundState memory multiRoundState,
        bool hasSuccessfulRound,
        bool currentRoundEnded
    ) external view returns (bool canFinalize);
    
    /**
     * @notice Check if campaign can be finalized by public
     * @param multiRoundState Current multi-round state
     * @param hasSuccessfulRound Whether campaign has any successful round
     * @param currentRoundEnded Whether current round has ended
     * @return canFinalize Whether public can finalize
     */
    function canPublicFinalize(
        MultiRoundState memory multiRoundState,
        bool hasSuccessfulRound,
        bool currentRoundEnded
    ) external view returns (bool canFinalize);
    
    /**
     * @notice Calculate remaining capacity for token purchase in round
     * @param round Current round data
     * @return remaining Remaining capacity
     */
    function calculateRemainingCapacity(
        Round memory round
    ) external pure returns (uint256 remaining);
    
    /**
     * @notice Determine if round should end based on raised amount
     * @param round Current round data
     * @return shouldEnd Whether round should end
     * @return isSuccess Whether round succeeded
     */
    function shouldEndRound(
        Round memory round
    ) external view returns (bool shouldEnd, bool isSuccess);
    
    /**
     * @notice Validate ceiling based on overage type
     * @param floor Round floor
     * @param ceiling Round ceiling
     * @param overageType Overage type
     * @return validatedCeiling Validated ceiling value
     */
    function validateCeiling(
        uint256 floor,
        uint256 ceiling,
        uint8 overageType
    ) external pure returns (uint256 validatedCeiling);
    
    /**
     * @notice Get constants for multi-round campaigns
     * @return maxRounds Maximum rounds allowed
     * @return maxDuration Maximum campaign duration
     * @return minRoundGap Minimum gap between rounds
     * @return maxRoundGap Maximum gap between rounds
     * @return creatorGracePeriod Creator finalization grace period
     * @return collectionDeadline Deadline after fund collection
     * @return failedRoundCooldown Cooldown after failed round
     * @return minFloorPercentage Minimum floor percentage of previous round
     */
    function getConstants() external view returns (
        uint256 maxRounds,
        uint256 maxDuration,
        uint256 minRoundGap,
        uint256 maxRoundGap,
        uint256 creatorGracePeriod,
        uint256 collectionDeadline,
        uint256 failedRoundCooldown,
        uint256 minFloorPercentage
    );
}
