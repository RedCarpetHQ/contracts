// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "../interfaces/IMultiRoundLogic.sol";

/**
 * @title MultiRoundLogic
 * @notice Stateless helper contract for multi-round campaign operations
 * @dev Used by Campaign contract to support multi-round functionality
 * 
 * DESIGN PRINCIPLES:
 * - Stateless: No storage, only pure/view functions
 * - Reusable: Can be used by any campaign contract
 * - Gas-efficient: Deployed once, called by all campaigns
 * - Security-focused: Comprehensive validation logic
 * 
 * MULTI-ROUND FEATURES:
 * - Up to 5 sequential rounds per campaign
 * - Incremental fund release after each successful round
 * - Controlled market launch (creator triggers finalization)
 * - Per-round refunds for failed/cancelled rounds
 * - Flexible failure handling
 * 
 * SECURITY MEASURES:
 * - Max rounds limit (5)
 * - Max campaign duration (18 months)
 * - Round gaps enforced (7-90 days)
 * - Failed round cooldown (14 days)
 * - Minimum floor requirement (50% of previous)
 * - Public finalization after grace period (30 days)
 * - Forced finalization after fund collection (90 days)
 */
contract MultiRoundLogic is IMultiRoundLogic {
    
    // Admin
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    // Campaign limits
    uint256 public constant MAX_ROUNDS = 5;
    uint256 public constant MAX_CAMPAIGN_DURATION = 548 days; // 18 months
    // Configurable: test default 5 min for fast iteration; production: 2 days
    uint256 public MIN_ROUND_GAP = 5 minutes; // production: 2 days
    uint256 public constant MAX_ROUND_GAP = 90 days;
    
    // Finalization timing
    // Configurable: test default 1 hour for fast iteration; production: 30 days
    uint256 public CREATOR_FINALIZE_GRACE = 1 hours; // production: 30 days
    uint256 public constant FINALIZE_DEADLINE_AFTER_COLLECTION = 90 days;
    
    // Round failure handling
    // Configurable: test default 5 min for fast iteration; production: 14 days
    uint256 public FAILED_ROUND_COOLDOWN = 5 minutes; // production: 14 days
    uint256 public constant MIN_FLOOR_PERCENTAGE = 50; // 50% of previous successful round
    
    // Status constants (must match Registry and Campaign)
    uint8 private constant STATUS_PENDING = 1;
    uint8 private constant STATUS_ACTIVE = 2;
    uint8 private constant STATUS_SUCCESS = 3;
    uint8 private constant STATUS_FAILED = 4;
    uint8 private constant STATUS_CANCELLED = 5;
    
    // Overage types (must match Registry and Campaign)
    uint8 private constant OVERAGE_NONE = 0;
    uint8 private constant OVERAGE_UNLIMITED = 1;
    uint8 private constant OVERAGE_CEILING = 2;

    constructor(address _owner) {
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        owner = newOwner;
    }

    /**
     * @notice Set timing parameters (production configuration)
     * @dev Test defaults are short for fast iteration; multisig sets production values post-deployment
     * @param _minRoundGap Minimum gap between rounds (test: 5 min, prod: 2 days)
     * @param _creatorFinalizeGrace Creator finalization grace (test: 1 hour, prod: 30 days)
     * @param _failedRoundCooldown Cooldown after failed round (test: 5 min, prod: 14 days)
     */
    function setTimingParameters(
        uint256 _minRoundGap,
        uint256 _creatorFinalizeGrace,
        uint256 _failedRoundCooldown
    ) external onlyOwner {
        require(_minRoundGap >= 1 minutes && _minRoundGap <= 30 days, "Invalid min round gap");
        require(_creatorFinalizeGrace >= 1 hours && _creatorFinalizeGrace <= 365 days, "Invalid grace");
        require(_failedRoundCooldown >= 1 minutes && _failedRoundCooldown <= 90 days, "Invalid cooldown");

        MIN_ROUND_GAP = _minRoundGap;
        CREATOR_FINALIZE_GRACE = _creatorFinalizeGrace;
        FAILED_ROUND_COOLDOWN = _failedRoundCooldown;

        emit TimingParametersUpdated(_minRoundGap, _creatorFinalizeGrace, _failedRoundCooldown);
    }

    event TimingParametersUpdated(uint256 minRoundGap, uint256 creatorFinalizeGrace, uint256 failedRoundCooldown);

    /**
     * @notice Get all multi-round constants
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
    ) {
        return (
            MAX_ROUNDS,
            MAX_CAMPAIGN_DURATION,
            MIN_ROUND_GAP,
            MAX_ROUND_GAP,
            CREATOR_FINALIZE_GRACE,
            FINALIZE_DEADLINE_AFTER_COLLECTION,
            FAILED_ROUND_COOLDOWN,
            MIN_FLOOR_PERCENTAGE
        );
    }
    
    /**
     * @notice Validate round creation parameters
     * @dev Comprehensive validation for creating a new round
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
    ) external view returns (bool isValid, string memory errorMessage) {
        // 1. Check round limits
        if (multiRoundState.totalRoundsCreated >= MAX_ROUNDS) {
            return (false, "Maximum rounds reached");
        }
        
        // 2. Check campaign duration
        uint256 campaignAge = block.timestamp - multiRoundState.createdAt;
        if (campaignAge >= MAX_CAMPAIGN_DURATION) {
            return (false, "Campaign duration exceeded");
        }
        
        // 3. Check time gaps (only if not first round)
        if (multiRoundState.totalRoundsCreated > 0) {
            uint256 timeSinceLastRound = block.timestamp - multiRoundState.lastRoundEndTime;
            
            if (timeSinceLastRound < MIN_ROUND_GAP) {
                return (false, "Must wait between rounds");
            }
            
            if (timeSinceLastRound > MAX_ROUND_GAP) {
                return (false, "Gap too long, must finalize");
            }
        }
        
        // 4. Check failed round cooldown
        if (multiRoundState.lastFailedRoundTime > 0) {
            if (block.timestamp < multiRoundState.lastFailedRoundTime + FAILED_ROUND_COOLDOWN) {
                return (false, "Cooldown after failed round");
            }
        }
        
        // 5. Require at least one successful round (if not first round)
        if (multiRoundState.totalRoundsCreated > 0 && !hasSuccessfulRound) {
            return (false, "Must have at least one successful round");
        }
        
        // 6. Validate floor relative to previous successful round
        if (multiRoundState.totalRoundsCreated > 0 && lastSuccessfulFloor > 0) {
            uint256 minFloor = (lastSuccessfulFloor * MIN_FLOOR_PERCENTAGE) / 100;
            if (floor < minFloor) {
                return (false, "Floor too low compared to previous round");
            }
        }
        
        // 7. Validate basic parameters
        if (floor == 0) {
            return (false, "Floor must be > 0");
        }
        
        if (overageType > OVERAGE_CEILING) {
            return (false, "Invalid overage type");
        }
        
        // 8. Validate ceiling based on overage type
        if (overageType == OVERAGE_CEILING && ceiling <= floor) {
            return (false, "Ceiling must be > floor");
        }
        
        // 9. Validate time parameters
        if (startTime < block.timestamp) {
            return (false, "Start time must be in future");
        }
        
        if (endTime <= startTime) {
            return (false, "End time must be after start");
        }
        
        // 10. Check total campaign duration
        if (endTime - multiRoundState.createdAt > MAX_CAMPAIGN_DURATION) {
            return (false, "End time exceeds max campaign duration");
        }
        
        return (true, "");
    }
    
    /**
     * @notice Check if creator can finalize campaign
     */
    function canCreatorFinalize(
        MultiRoundState memory multiRoundState,
        bool hasSuccessfulRound,
        bool currentRoundEnded
    ) external view returns (bool) {
        // Must have at least one successful round
        if (!hasSuccessfulRound) {
            return false;
        }
        
        // Current round must be ended (if exists)
        if (multiRoundState.currentRoundId > 0 && !currentRoundEnded) {
            return false;
        }
        
        // Can finalize if minimum gap passed since last round
        if (block.timestamp >= multiRoundState.lastRoundEndTime + MIN_ROUND_GAP) {
            return true;
        }
        
        // Or if max rounds reached
        if (multiRoundState.totalRoundsCreated >= MAX_ROUNDS) {
            return true;
        }
        
        // Or if max duration reached
        if (block.timestamp >= multiRoundState.createdAt + MAX_CAMPAIGN_DURATION) {
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Check if public can finalize campaign
     */
    function canPublicFinalize(
        MultiRoundState memory multiRoundState,
        bool hasSuccessfulRound,
        bool currentRoundEnded
    ) external view returns (bool) {
        // Must have at least one successful round
        if (!hasSuccessfulRound) {
            return false;
        }
        
        // Current round must be ended (if exists)
        if (multiRoundState.currentRoundId > 0 && !currentRoundEnded) {
            return false;
        }
        
        // Check grace periods
        bool gracePeriodExpired = block.timestamp >= 
            multiRoundState.lastRoundEndTime + CREATOR_FINALIZE_GRACE;
        
        bool collectionDeadlineExpired = false;
        if (multiRoundState.lastFundCollectionTime > 0) {
            collectionDeadlineExpired = block.timestamp >= 
                multiRoundState.lastFundCollectionTime + FINALIZE_DEADLINE_AFTER_COLLECTION;
        }
        
        bool maxDurationReached = block.timestamp >= 
            multiRoundState.createdAt + MAX_CAMPAIGN_DURATION;
        
        return gracePeriodExpired || collectionDeadlineExpired || maxDurationReached;
    }
    
    /**
     * @notice Calculate remaining capacity for token purchase
     */
    function calculateRemainingCapacity(
        Round memory round
    ) external pure returns (uint256 remaining) {
        if (round.overageType == OVERAGE_NONE || round.overageType == OVERAGE_CEILING) {
            // Capped at ceiling
            if (round.totalRaised >= round.ceiling) {
                return 0;
            }
            return round.ceiling - round.totalRaised;
        } else {
            // OVERAGE_UNLIMITED: no cap
            return type(uint256).max;
        }
    }
    
    /**
     * @notice Determine if round should end based on raised amount
     */
    function shouldEndRound(
        Round memory round
    ) external view returns (bool shouldEnd, bool isSuccess) {
        // Check if ceiling reached (for CEILING or NONE overage types)
        if (round.overageType == OVERAGE_CEILING && round.totalRaised >= round.ceiling) {
            return (true, true); // End and success
        }
        
        if (round.overageType == OVERAGE_NONE && round.totalRaised >= round.floor) {
            return (true, true); // End and success
        }
        
        // Check if time expired
        if (block.timestamp > round.endTime) {
            // Determine success based on floor
            if (round.totalRaised >= round.floor) {
                return (true, true); // End and success
            } else {
                return (true, false); // End and failed
            }
        }
        
        return (false, false); // Don't end yet
    }
    
    /**
     * @notice Validate ceiling based on overage type
     */
    function validateCeiling(
        uint256 floor,
        uint256 ceiling,
        uint8 overageType
    ) external pure returns (uint256 validatedCeiling) {
        if (overageType == OVERAGE_NONE) {
            // No overage: ceiling equals floor
            return floor;
        } else if (overageType == OVERAGE_CEILING) {
            // Ceiling overage: ceiling must be > floor
            require(ceiling > floor, "Ceiling must be > floor");
            return ceiling;
        } else {
            // Unlimited overage: ceiling is 0 (no cap)
            return 0;
        }
    }
}
