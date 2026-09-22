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

/**
 * @title CampaignAdmin
 * @notice Shared admin and creator management functions for both single and multi-round campaigns
 * @dev Lightweight contract to reduce BaseCampaign.sol size while maintaining shared logic
 */
contract CampaignAdmin is Ownable, ReentrancyGuard {
    
    Registry public immutable registry;
    
    uint256 public constant GRACE_PERIOD = 24 hours;
    uint256 public constant CREATOR_FINALIZE_GRACE_PERIOD = 2 weeks;
    uint256 public constant MAX_CAMPAIGN_DURATION = 270 days;
    
    uint8 private constant STATUS_PENDING = 1;
    uint8 private constant STATUS_ACTIVE = 2;
    uint8 private constant STATUS_SUCCESS = 3;
    uint8 private constant STATUS_FAILED = 4;
    uint8 private constant STATUS_CANCELLED = 5;
    
    mapping(address => uint256) public campaignInitialStart;
    mapping(address => uint256) public extensionCount;
    uint256 public maxExtensions = 1;
    
    bool public screeningEnabled = true;
    mapping(address => bool) public screeners;
    mapping(string => bool) public approvedCampaignIds;
    
    // Multi-creator funds recipient consensus
    struct FundsRecipientProposal {
        address proposedRecipient;
        mapping(address => bool) approvals;
        uint256 approvalCount;
        bool executed;
    }
    
    mapping(address => FundsRecipientProposal) public fundsRecipientProposals;
    
    event CampaignTimesUpdated(address indexed token, uint256 newStartTime, uint256 newEndTime);
    event CampaignExtended(address indexed token, uint256 newEndTime);
    event FloorUpdated(address indexed token, uint256 oldFloor, uint256 newFloor);
    event CeilingUpdated(address indexed token, uint256 oldCeiling, uint256 newCeiling);
    event FundsRecipientUpdated(address indexed token, address indexed oldRecipient, address indexed newRecipient);
    event MaxExtensionsUpdated(uint256 oldMax, uint256 newMax);
    event ScreenerUpdated(address indexed screener, bool isScreener);
    event CampaignIdApprovalSet(string campaignId, bool approved, address indexed screener);
    event ScreeningToggled(bool enabled);
    event CampaignExtensionLimitReached(address indexed token, uint256 maxExtensions);
    event CampaignCreatorAdded(address indexed token, address indexed creator, address indexed addedBy);
    event CampaignCreatorRemoved(address indexed token, address indexed creator, address indexed removedBy);
    event FundsRecipientProposalCreated(address indexed token, address indexed proposer, address proposedRecipient);
    event FundsRecipientProposalApproved(address indexed token, address indexed approver, address proposedRecipient);
    event FundsRecipientProposalExecuted(address indexed token, address oldRecipient, address newRecipient);
    
    constructor(address _owner, address _registry) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    function updateCampaignTimes(address token, uint256 newStartTime, uint256 newEndTime) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        uint8 status = registry.getCampaignStatus(token);
        require(status == STATUS_PENDING, "Campaign already started");
        require(block.timestamp < campaign.startTime, "Campaign already started");
        require(newStartTime >= block.timestamp, "Start time must be in future");
        require(newEndTime > newStartTime, "End time must be after start");

        registry.updateCampaignTimes(token, newStartTime, newEndTime);
        emit CampaignTimesUpdated(token, newStartTime, newEndTime);
    }

    function extendCampaign(address token, uint256 newEndTime) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        uint8 status = registry.getCampaignStatus(token);
        require(
            status == STATUS_PENDING || 
            status == STATUS_ACTIVE,
            "Campaign not active"
        );
        
        require(newEndTime > campaign.endTime, "New end time must be after current");
        
        uint256 initialStart = campaignInitialStart[token];
        if (initialStart == 0) {
            initialStart = campaign.startTime;
            campaignInitialStart[token] = initialStart;
        }
        
        require(
            newEndTime <= initialStart + MAX_CAMPAIGN_DURATION,
            "Exceeds max campaign duration"
        );
        
        require(extensionCount[token] < maxExtensions, "Max extensions reached");
        
        extensionCount[token]++;
        registry.updateCampaignTimes(token, campaign.startTime, newEndTime);
        
        emit CampaignExtended(token, newEndTime);
        
        if (extensionCount[token] >= maxExtensions) {
            emit CampaignExtensionLimitReached(token, maxExtensions);
        }
    }

    function adjustFloor(address token, uint256 newFloor) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        uint8 status = registry.getCampaignStatus(token);
        require(status == STATUS_PENDING, "Campaign already started");
        require(newFloor > 0, "Floor must be > 0");
        
        registry.updateCampaignFloor(token, newFloor);
        
        if (campaign.overageType == 0) {
            registry.updateCampaignCeiling(token, newFloor);
        } else {
            require(newFloor < campaign.ceiling, "Floor must be < ceiling");
        }
        
        emit FloorUpdated(token, campaign.floor, newFloor);
    }

    function adjustCeiling(address token, uint256 newCeiling) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        uint8 status = registry.getCampaignStatus(token);
        require(status == STATUS_PENDING, "Campaign already started");
        require(campaign.overageType == 2, "Only for CEILING overage type");
        require(newCeiling > campaign.floor, "Ceiling must be > floor");
        
        registry.updateCampaignCeiling(token, newCeiling);
        emit CeilingUpdated(token, campaign.ceiling, newCeiling);
    }

    /**
     * @notice Propose a new funds recipient address
     * @dev Proposer automatically approves. If all creators approve, executes immediately.
     * @param token Campaign token address
     * @param newRecipient New funds recipient address
     */
    function proposeFundsRecipientChange(address token, address newRecipient) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        require(newRecipient != address(0), "Invalid recipient");
        
        FundsRecipientProposal storage proposal = fundsRecipientProposals[token];
        require(!proposal.executed, "Proposal already executed");
        
        // Reset proposal if different recipient
        if (proposal.proposedRecipient != newRecipient) {
            proposal.proposedRecipient = newRecipient;
            proposal.approvalCount = 0;
            address[] memory allCreators = registry.getCampaignCreators(token);
            for (uint256 i = 0; i < allCreators.length; i++) {
                proposal.approvals[allCreators[i]] = false;
            }
        }
        
        // Proposer automatically approves
        if (!proposal.approvals[msg.sender]) {
            proposal.approvals[msg.sender] = true;
            proposal.approvalCount++;
            emit FundsRecipientProposalApproved(token, msg.sender, newRecipient);
        }
        
        emit FundsRecipientProposalCreated(token, msg.sender, newRecipient);
        
        // Check if all creators approved
        address[] memory creators = registry.getCampaignCreators(token);
        if (proposal.approvalCount == creators.length) {
            _executeFundsRecipientChange(token);
        }
    }

    /**
     * @notice Approve a pending funds recipient change proposal
     * @dev If all creators approve, executes immediately.
     * @param token Campaign token address
     */
    function approveFundsRecipientChange(address token) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        
        FundsRecipientProposal storage proposal = fundsRecipientProposals[token];
        require(proposal.proposedRecipient != address(0), "No active proposal");
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.approvals[msg.sender], "Already approved");
        
        proposal.approvals[msg.sender] = true;
        proposal.approvalCount++;
        
        emit FundsRecipientProposalApproved(token, msg.sender, proposal.proposedRecipient);
        
        // Check if all creators approved
        address[] memory creators = registry.getCampaignCreators(token);
        if (proposal.approvalCount == creators.length) {
            _executeFundsRecipientChange(token);
        }
    }

    /**
     * @notice Internal function to execute funds recipient change
     * @dev Called automatically when all creators approve
     * @param token Campaign token address
     */
    function _executeFundsRecipientChange(address token) internal {
        FundsRecipientProposal storage proposal = fundsRecipientProposals[token];
        
        address oldRecipient = registry.getCampaign(token).fundsRecipient;
        registry.updateFundsRecipient(token, proposal.proposedRecipient);
        
        proposal.executed = true;
        
        emit FundsRecipientUpdated(token, oldRecipient, proposal.proposedRecipient);
        emit FundsRecipientProposalExecuted(token, oldRecipient, proposal.proposedRecipient);
    }

    /**
     * @notice Get proposal details for a campaign
     * @param token Campaign token address
     * @return proposedRecipient The proposed new recipient address
     * @return approvalCount Number of creators who have approved
     * @return executed Whether the proposal has been executed
     */
    function getProposalDetails(address token) external view returns (
        address proposedRecipient,
        uint256 approvalCount,
        bool executed
    ) {
        FundsRecipientProposal storage proposal = fundsRecipientProposals[token];
        return (proposal.proposedRecipient, proposal.approvalCount, proposal.executed);
    }

    /**
     * @notice Check if a creator has approved the proposal
     * @param token Campaign token address
     * @param creator Creator address to check
     * @return approved Whether the creator has approved
     */
    function hasApproved(address token, address creator) external view returns (bool) {
        return fundsRecipientProposals[token].approvals[creator];
    }

    function addCampaignCreators(address token, address[] calldata creators) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        require(creators.length > 0, "No creators to add");
        
        registry.addCampaignCreators(token, creators, msg.sender);
        
        for (uint256 i = 0; i < creators.length; i++) {
            emit CampaignCreatorAdded(token, creators[i], msg.sender);
        }
    }

    function removeCampaignCreator(address token, address creator) external nonReentrant {
        require(registry.isCampaignCreator(token, msg.sender), "Only creator");
        require(creator != msg.sender, "Cannot remove yourself");
        require(registry.isCampaignCreator(token, creator), "Address is not a creator");
        
        registry.removeCampaignCreator(token, creator, msg.sender);
        emit CampaignCreatorRemoved(token, creator, msg.sender);
    }

    function setMaxExtensions(uint256 _maxExtensions) external onlyOwner {
        require(_maxExtensions > 0, "Max extensions must be > 0");
        uint256 oldMax = maxExtensions;
        maxExtensions = _maxExtensions;
        emit MaxExtensionsUpdated(oldMax, _maxExtensions);
    }

    function setScreeningEnabled(bool enabled) external onlyOwner {
        screeningEnabled = enabled;
        emit ScreeningToggled(enabled);
    }

    function setScreener(address screener, bool enabled) external onlyOwner {
        require(screener != address(0), "Invalid screener");
        screeners[screener] = enabled;
        emit ScreenerUpdated(screener, enabled);
    }

    function batchSetScreeners(address[] calldata _screeners, bool enabled) external onlyOwner {
        for (uint256 i = 0; i < _screeners.length; i++) {
            require(_screeners[i] != address(0), "Invalid screener");
            screeners[_screeners[i]] = enabled;
            emit ScreenerUpdated(_screeners[i], enabled);
        }
    }

    /**
     * @notice Approve a campaign for deployment
     * @param campaignId Campaign draft ID from Firestore
     * @param approved Approval status
     */
    function setCampaignIdApproval(string memory campaignId, bool approved) external {
        require(screeners[msg.sender] || msg.sender == owner(), "Not authorized");
        require(bytes(campaignId).length > 0, "Invalid campaign ID");
        approvedCampaignIds[campaignId] = approved;
        emit CampaignIdApprovalSet(campaignId, approved, msg.sender);
    }

    /**
     * @notice Batch approve multiple campaigns
     * @param campaignIds Array of campaign draft IDs
     * @param approved Approval status
     */
    function batchSetCampaignIdApproval(string[] calldata campaignIds, bool approved) external {
        require(screeners[msg.sender] || msg.sender == owner(), "Not authorized");
        for (uint256 i = 0; i < campaignIds.length; i++) {
            require(bytes(campaignIds[i]).length > 0, "Invalid campaign ID");
            approvedCampaignIds[campaignIds[i]] = approved;
            emit CampaignIdApprovalSet(campaignIds[i], approved, msg.sender);
        }
    }

    function isScreener(address account) external view returns (bool) {
        return screeners[account];
    }

    /**
     * @notice Check if campaign is approved
     * @param campaignId Campaign draft ID
     * @return approved Whether campaign is approved
     */
    function isCampaignIdApproved(string memory campaignId) external view returns (bool) {
        return approvedCampaignIds[campaignId];
    }

    function getCampaignExtensionInfo(address token) external view returns (
        uint256 currentExtensions,
        uint256 maxAllowed,
        bool canExtend
    ) {
        currentExtensions = extensionCount[token];
        maxAllowed = maxExtensions;
        canExtend = currentExtensions < maxAllowed;
    }

    function getCampaignDurationInfo(address token) external view returns (
        uint256 initialStart,
        uint256 maxEndTime,
        uint256 currentDuration
    ) {
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        initialStart = campaignInitialStart[token];
        if (initialStart == 0) {
            initialStart = campaign.startTime;
        }
        maxEndTime = initialStart + MAX_CAMPAIGN_DURATION;
        if (block.timestamp >= campaign.startTime) {
            currentDuration = campaign.endTime - campaign.startTime;
        } else {
            currentDuration = 0;
        }
    }

    function getGracePeriodStatus(address token) external view returns (
        bool inGracePeriod,
        uint256 gracePeriodEnds,
        bool canExtend,
        bool isRefundable
    ) {
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        
        if (block.timestamp > campaign.endTime && campaign.totalRaised < campaign.floor) {
            gracePeriodEnds = campaign.endTime + GRACE_PERIOD;
            inGracePeriod = block.timestamp <= gracePeriodEnds;
            canExtend = inGracePeriod && extensionCount[token] < maxExtensions;
            isRefundable = !inGracePeriod;
        }
        
        uint8 status = registry.getCampaignStatus(token);
        if (status == STATUS_FAILED || status == STATUS_CANCELLED) {
            isRefundable = true;
        }
    }
}
