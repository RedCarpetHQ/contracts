// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Registry.sol";
import "./interfaces/IMinimumERC20.sol";

/**
 * @title BurnRedemption
 * @notice Allows surveyors to create burn-to-redeem events for physical goods
 * @dev Token holders burn tokens to claim tiers (e.g., burn 100 for t-shirt, 300 for signed t-shirt)
 * 
 * Flow:
 * 1. Surveyor creates redemption event with tiers and time window
 * 2. Token holders burn tokens to claim a tier
 * 3. Claim is recorded on-chain, user provides shipping info off-chain (Firestore)
 * 4. Surveyor reads claims and fulfills orders
 */
contract BurnRedemption is Ownable, ReentrancyGuard {
    Registry public registry;
    
    // Redemption tier
    struct Tier {
        string name;           // e.g., "Generic T-Shirt", "Signed T-Shirt"
        uint256 burnAmount;    // Amount of tokens to burn
        uint256 maxClaims;     // Maximum claims for this tier (0 = unlimited)
        uint256 claimCount;    // Current claim count
    }
    
    // Redemption event
    struct RedemptionEvent {
        address token;
        address surveyor;
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        bool active;
        uint256 tierCount;
        string eventId;        // Off-chain event ID for linking to Firestore
    }
    
    // Claim record
    struct Claim {
        address claimer;
        uint256 eventId;
        uint256 tierId;
        uint256 burnAmount;
        uint256 claimedAt;
    }
    
    // Storage
    mapping(uint256 => RedemptionEvent) public events;
    mapping(uint256 => mapping(uint256 => Tier)) public eventTiers; // eventId => tierId => Tier
    mapping(uint256 => Claim[]) public eventClaims; // eventId => claims
    mapping(uint256 => mapping(address => uint256[])) public userClaims; // eventId => user => claimIndices
    uint256 public eventCount;
    
    // Events
    event RedemptionEventCreated(
        uint256 indexed eventId,
        address indexed token,
        address indexed surveyor,
        string title,
        uint256 startTime,
        uint256 endTime,
        uint256 tierCount,
        string offchainEventId
    );
    event TierAdded(
        uint256 indexed eventId,
        uint256 indexed tierId,
        string name,
        uint256 burnAmount,
        uint256 maxClaims
    );
    event RedemptionClaimed(
        uint256 indexed eventId,
        uint256 indexed tierId,
        address indexed claimer,
        uint256 burnAmount,
        uint256 claimIndex
    );
    event RedemptionEventUpdated(uint256 indexed eventId, bool active);
    
    constructor(address _owner, address _registry) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    /**
     * @notice Authorize a surveyor for a specific token
     * @dev DEPRECATED: Use Registry.setSurveyor() instead
     * @dev This function now forwards to Registry for centralized access control
     */
    function authorizeSurveyor(address token, address surveyor, bool authorized) external {
        // Forward to Registry for centralized management
        registry.setSurveyor(token, surveyor, authorized);
    }
    
    /**
     * @notice Check if address is authorized surveyor
     * @dev Uses centralized Registry access control
     */
    function isSurveyor(address token, address account) public view returns (bool) {
        return registry.isAuthorizedSurveyor(token, account) || account == owner();
    }
    
    modifier onlySurveyor(address token) {
        require(isSurveyor(token, msg.sender), "Not authorized surveyor");
        _;
    }
    
    /**
     * @notice Create a new redemption event
     * @param token Campaign token address
     * @param title Event title
     * @param description Event description
     * @param startTime Event start timestamp
     * @param endTime Event end timestamp
     * @param tierNames Array of tier names
     * @param tierBurnAmounts Array of burn amounts per tier
     * @param tierMaxClaims Array of max claims per tier (0 = unlimited)
     * @param offchainEventId Off-chain event ID for Firestore linking
     */
    function createRedemptionEvent(
        address token,
        string calldata title,
        string calldata description,
        uint256 startTime,
        uint256 endTime,
        string[] calldata tierNames,
        uint256[] calldata tierBurnAmounts,
        uint256[] calldata tierMaxClaims,
        string calldata offchainEventId
    ) external onlySurveyor(token) nonReentrant returns (uint256 eventId) {
        require(token != address(0), "Invalid token");
        require(bytes(title).length > 0, "Title required");
        require(startTime < endTime, "Invalid time range");
        require(tierNames.length > 0, "At least one tier required");
        require(
            tierNames.length == tierBurnAmounts.length && 
            tierNames.length == tierMaxClaims.length,
            "Tier arrays length mismatch"
        );
        
        eventId = eventCount++;
        
        events[eventId] = RedemptionEvent({
            token: token,
            surveyor: msg.sender,
            title: title,
            description: description,
            startTime: startTime,
            endTime: endTime,
            active: true,
            tierCount: tierNames.length,
            eventId: offchainEventId
        });
        
        // Add tiers
        for (uint256 i = 0; i < tierNames.length; i++) {
            require(tierBurnAmounts[i] > 0, "Burn amount must be > 0");
            eventTiers[eventId][i] = Tier({
                name: tierNames[i],
                burnAmount: tierBurnAmounts[i],
                maxClaims: tierMaxClaims[i],
                claimCount: 0
            });
            emit TierAdded(eventId, i, tierNames[i], tierBurnAmounts[i], tierMaxClaims[i]);
        }
        
        emit RedemptionEventCreated(
            eventId,
            token,
            msg.sender,
            title,
            startTime,
            endTime,
            tierNames.length,
            offchainEventId
        );
    }
    
    /**
     * @notice Claim a redemption tier by burning tokens
     * @param eventId Redemption event ID
     * @param tierId Tier ID to claim
     */
    function claimRedemption(uint256 eventId, uint256 tierId) external nonReentrant {
        RedemptionEvent storage evt = events[eventId];
        require(evt.token != address(0), "Event does not exist");
        require(evt.active, "Event not active");
        require(block.timestamp >= evt.startTime, "Event not started");
        require(block.timestamp <= evt.endTime, "Event ended");
        require(tierId < evt.tierCount, "Invalid tier");
        
        Tier storage tier = eventTiers[eventId][tierId];
        require(
            tier.maxClaims == 0 || tier.claimCount < tier.maxClaims,
            "Tier sold out"
        );
        
        // Check user has enough tokens
        uint256 burnAmount = tier.burnAmount;
        require(
            IMinimumERC20(evt.token).balanceOf(msg.sender) >= burnAmount,
            "Insufficient token balance"
        );
        
        // Check allowance
        require(
            IMinimumERC20(evt.token).allowance(msg.sender, address(this)) >= burnAmount,
            "Approve tokens first"
        );
        
        // Burn tokens
        IMinimumERC20(evt.token).burnFrom(msg.sender, burnAmount);
        
        // Record claim
        tier.claimCount++;
        uint256 claimIndex = eventClaims[eventId].length;
        
        eventClaims[eventId].push(Claim({
            claimer: msg.sender,
            eventId: eventId,
            tierId: tierId,
            burnAmount: burnAmount,
            claimedAt: block.timestamp
        }));
        
        userClaims[eventId][msg.sender].push(claimIndex);
        
        emit RedemptionClaimed(eventId, tierId, msg.sender, burnAmount, claimIndex);
    }
    
    /**
     * @notice Toggle event active status
     */
    function setEventActive(uint256 eventId, bool active) external {
        RedemptionEvent storage evt = events[eventId];
        require(evt.token != address(0), "Event does not exist");
        require(isSurveyor(evt.token, msg.sender), "Not authorized");
        
        evt.active = active;
        emit RedemptionEventUpdated(eventId, active);
    }
    
    // View functions
    
    /**
     * @notice Get event details
     */
    function getEvent(uint256 eventId) external view returns (
        address token,
        address surveyor,
        string memory title,
        string memory description,
        uint256 startTime,
        uint256 endTime,
        bool active,
        uint256 tierCount,
        string memory offchainEventId
    ) {
        RedemptionEvent storage evt = events[eventId];
        return (
            evt.token,
            evt.surveyor,
            evt.title,
            evt.description,
            evt.startTime,
            evt.endTime,
            evt.active,
            evt.tierCount,
            evt.eventId
        );
    }
    
    /**
     * @notice Get tier details
     */
    function getTier(uint256 eventId, uint256 tierId) external view returns (
        string memory name,
        uint256 burnAmount,
        uint256 maxClaims,
        uint256 claimCount,
        uint256 remaining
    ) {
        Tier storage tier = eventTiers[eventId][tierId];
        remaining = tier.maxClaims == 0 ? type(uint256).max : tier.maxClaims - tier.claimCount;
        return (tier.name, tier.burnAmount, tier.maxClaims, tier.claimCount, remaining);
    }
    
    /**
     * @notice Get all tiers for an event
     */
    function getEventTiers(uint256 eventId) external view returns (
        string[] memory names,
        uint256[] memory burnAmounts,
        uint256[] memory maxClaimsArr,
        uint256[] memory claimCounts
    ) {
        uint256 count = events[eventId].tierCount;
        names = new string[](count);
        burnAmounts = new uint256[](count);
        maxClaimsArr = new uint256[](count);
        claimCounts = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            Tier storage tier = eventTiers[eventId][i];
            names[i] = tier.name;
            burnAmounts[i] = tier.burnAmount;
            maxClaimsArr[i] = tier.maxClaims;
            claimCounts[i] = tier.claimCount;
        }
    }
    
    /**
     * @notice Get claims for an event
     */
    function getEventClaims(uint256 eventId) external view returns (Claim[] memory) {
        return eventClaims[eventId];
    }
    
    /**
     * @notice Get claim count for an event
     */
    function getEventClaimCount(uint256 eventId) external view returns (uint256) {
        return eventClaims[eventId].length;
    }
    
    /**
     * @notice Get user's claims for an event
     */
    function getUserClaims(uint256 eventId, address user) external view returns (uint256[] memory claimIndices) {
        return userClaims[eventId][user];
    }
    
    /**
     * @notice Check if user has claimed a specific tier
     */
    function hasClaimedTier(uint256 eventId, uint256 tierId, address user) external view returns (bool) {
        uint256[] storage indices = userClaims[eventId][user];
        for (uint256 i = 0; i < indices.length; i++) {
            if (eventClaims[eventId][indices[i]].tierId == tierId) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @notice Get events for a token
     */
    function getTokenEvents(address token) external view returns (uint256[] memory eventIds) {
        // Count matching events
        uint256 count = 0;
        for (uint256 i = 0; i < eventCount; i++) {
            if (events[i].token == token) count++;
        }
        
        // Populate array
        eventIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < eventCount; i++) {
            if (events[i].token == token) {
                eventIds[index++] = i;
            }
        }
    }
    
    /**
     * @notice Get active events for a token
     */
    function getActiveTokenEvents(address token) external view returns (uint256[] memory eventIds) {
        // Count matching events
        uint256 count = 0;
        for (uint256 i = 0; i < eventCount; i++) {
            if (events[i].token == token && 
                events[i].active && 
                block.timestamp >= events[i].startTime &&
                block.timestamp <= events[i].endTime) {
                count++;
            }
        }
        
        // Populate array
        eventIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < eventCount; i++) {
            if (events[i].token == token && 
                events[i].active && 
                block.timestamp >= events[i].startTime &&
                block.timestamp <= events[i].endTime) {
                eventIds[index++] = i;
            }
        }
    }
}
