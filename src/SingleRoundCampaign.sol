// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./BaseCampaign.sol";

/**
 * @title SingleRoundCampaign
 * @notice Manages single-round movie fundraising campaigns with ERC20 token sales
 * @dev Extends BaseCampaign with single-round specific functionality
 * @dev UUPS Upgradeable - can be upgraded by owner
 */
contract SingleRoundCampaign is BaseCampaign, UUPSUpgradeable {
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the SingleRoundCampaign contract
     * @param _owner Initial owner address
     * @param _registry Registry contract address
     * @param _campaignAdmin CampaignAdmin contract address
     */
    function initialize(
        address _owner,
        address _registry,
        address _campaignAdmin
    ) public initializer {
        __BaseCampaign_init(_owner, _registry, _campaignAdmin);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Authorize upgrade (UUPS requirement)
     * @dev Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice Create a new single-round campaign and deploy its token
     * @param campaignId Campaign draft ID from Firestore (used for approval)
     * @param name Token name
     * @param symbol Token symbol
     * @param paymentToken Payment token to use (must be USDC)
     * @param floor Minimum amount needed for campaign success
     * @param ceiling Maximum amount if overage is CEILING type
     * @param overageType 0=NONE, 1=UNLIMITED, 2=CEILING
     * @param fundsRecipient Wallet to receive funds
     * @param startTime Campaign start timestamp
     * @param endTime Campaign end timestamp
     * @param additionalCreators Array of additional creator addresses
     */
    function createCampaign(
        string memory campaignId,
        string memory name,
        string memory symbol,
        address paymentToken,
        uint256 floor,
        uint256 ceiling,
        uint8 overageType,
        address fundsRecipient,
        uint256 startTime,
        uint256 endTime,
        address[] calldata additionalCreators
    ) external nonReentrant returns (address token) {
        if (campaignAdmin().screeningEnabled()) {
            require(campaignAdmin().isCampaignIdApproved(campaignId), "Campaign not approved");
        }
        
        require(paymentToken == registry().usdc(), "Only USDC accepted");
        require(floor > 0, "Floor must be > 0");
        require(overageType <= OVERAGE_CEILING, "Invalid overage type");
        
        // Validate ceiling based on overage type
        if (overageType == OVERAGE_NONE) {
            ceiling = floor;
        } else if (overageType == OVERAGE_CEILING) {
            require(ceiling > floor, "Ceiling must be > floor");
        } else {
            ceiling = 0;
        }
        
        require(startTime >= block.timestamp, "Start time must be in future");
        require(endTime > startTime, "End time must be after start");
        
        address recipient = fundsRecipient == address(0) ? msg.sender : fundsRecipient;

        // Create token
        address _tokenImpl = _getTokenImplementation();
        require(_tokenImpl != address(0), "Token implementation not set in Registry");
        token = Clones.clone(_tokenImpl);
        MinimumERC20(token).initialize(name, symbol, address(this));
        
        // Grant SNAPSHOT_ROLE to protocol contracts
        address _dividendDistributor = _getDividendDistributor();
        if (_dividendDistributor != address(0)) {
            MinimumERC20(token).grantRole(
                MinimumERC20(token).SNAPSHOT_ROLE(),
                _dividendDistributor
            );
        }
        
        address _optimisticPriceOracle = _getOptimisticPriceOracle();
        if (_optimisticPriceOracle != address(0)) {
            MinimumERC20(token).grantRole(
                MinimumERC20(token).SNAPSHOT_ROLE(),
                _optimisticPriceOracle
            );
        }
        
        address _surveySnapshot = _getSurveySnapshot();
        if (_surveySnapshot != address(0)) {
            MinimumERC20(token).grantRole(
                MinimumERC20(token).SNAPSHOT_ROLE(),
                _surveySnapshot
            );
        }

        // Register campaign in registry (isMultiRound = false by default)
        registry().registerCampaign(
            token, 
            msg.sender, 
            paymentToken, 
            floor, 
            ceiling, 
            overageType, 
            recipient, 
            startTime, 
            endTime
        );
        
        // Add additional creators if provided
        if (additionalCreators.length > 0) {
            registry().addCampaignCreators(token, additionalCreators, msg.sender);
        }

        emit CampaignCreated(token, msg.sender, campaignId, paymentToken, name, symbol, floor, ceiling, overageType, recipient, startTime, endTime);
    }

    /**
     * @notice Purchase tokens during active campaign
     * @param token Campaign token address
     * @param amount Amount of tokens to purchase
     * @param uiFeeReceiver Integrator address to receive UI fee (address(0) for no fee)
     */
    function purchaseTokens(address token, uint256 amount, address uiFeeReceiver) external nonReentrant {
        require(!registry().isMultiRoundCampaign(token), "Use MultiRoundCampaign contract");
        _purchaseTokensInternal(token, 0, amount, msg.sender, uiFeeReceiver);
    }

    /**
     * @notice Cancel campaign (any creator can cancel)
     * @param token Campaign token address
     */
    function cancelCampaign(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        _cancelInternal(token, 0, msg.sender);
    }

    /**
     * @notice Refund tokens for failed or cancelled campaign
     * @param token Campaign token address
     * @param tokenAmount Amount of tokens to refund
     */
    function refund(address token, uint256 tokenAmount) external nonReentrant {
        _refundInternal(token, 0, tokenAmount, msg.sender);
    }

    /**
     * @notice Creator finalizes campaign
     * @param token Campaign token address
     */
    function creatorFinalizeCampaign(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        Registry.CampaignData memory campaign = registry().getCampaign(token);
        require(campaign.token != address(0), "Campaign does not exist");
        uint8 status = registry().getCampaignStatus(token);
        require(
            status == STATUS_PENDING || status == STATUS_ACTIVE,
            "Campaign already finalized"
        );
        
        bool canFinalize = _canFinalize(campaign);
        require(canFinalize, "Finalization conditions not met");
        
        _endCampaign(token);
    }

    /**
     * @notice Public finalize campaign (after creator grace period)
     * @param token Campaign token address
     */
    function publicFinalizeCampaign(address token) external nonReentrant {
        Registry.CampaignData memory campaign = registry().getCampaign(token);
        require(campaign.token != address(0), "Campaign does not exist");
        uint8 status = registry().getCampaignStatus(token);
        require(
            status == STATUS_PENDING || status == STATUS_ACTIVE,
            "Campaign already finalized"
        );
        
        bool canFinalize = _canFinalize(campaign);
        require(canFinalize, "Finalization conditions not met");
        
        uint256 finalizableAt = _getFinalizableTimestamp(campaign);
        require(
            block.timestamp >= finalizableAt + CREATOR_FINALIZE_GRACE_PERIOD,
            "Creator grace period not expired"
        );
        
        _endCampaign(token);
    }
    
    /**
     * @notice Check if campaign can be finalized
     */
    function _canFinalize(Registry.CampaignData memory campaign) internal view returns (bool) {
        // Ceiling reached
        if ((campaign.overageType == OVERAGE_CEILING || campaign.overageType == OVERAGE_NONE) 
            && campaign.totalRaised >= campaign.ceiling) {
            return true;
        }
        
        // Deadline not passed yet
        if (block.timestamp <= campaign.endTime) {
            return false;
        }
        
        // Floor met after deadline
        if (campaign.totalRaised >= campaign.floor) {
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Get timestamp when campaign became finalizable
     */
    function _getFinalizableTimestamp(Registry.CampaignData memory campaign) internal view returns (uint256) {
        if ((campaign.overageType == OVERAGE_CEILING || campaign.overageType == OVERAGE_NONE) 
            && campaign.totalRaised >= campaign.ceiling) {
            return campaign.endTime < block.timestamp ? campaign.endTime : block.timestamp;
        }
        
        return campaign.endTime;
    }

    /**
     * @notice Internal function to end campaign
     */
    function _endCampaign(address token) internal {
        Registry.CampaignData memory campaign = registry().getCampaign(token);

        uint256 finalSupply = MinimumERC20(token).totalSupply();
        MinimumERC20(token).lockSupply();
        registry().enableMarket(token);
        emit SupplyLocked(token, finalSupply);
        
        // Collect funds
        if (campaign.totalRaised > 0 && !fundsWithdrawn(token)) {
            _collectFunds(token, 0, campaign.fundsRecipient, campaign.totalRaised);
        }
        
        // Auto-create vault
        ILendingManager _lendingManager = _getLendingManager();
        require(address(_lendingManager) != address(0), "LendingManager not set");
        
        address stableVault = _lendingManager.createVaultsOnCampaignSuccess(token);
        
        (bool exists, , uint256 activationTime, ) = _lendingManager.getVaultStatus(token);
        require(exists, "Vault creation failed");
        
        emit TokenVaultScheduled(token, stableVault, activationTime);

        MinimumERC20(token).renounceOwnership();

        emit CampaignEnded(token, true, campaign.totalRaised, MinimumERC20(token).totalSupply());
    }

    /**
     * @notice Get finalization status for a campaign
     */
    function getFinalizationStatus(address token) external view returns (
        bool canCreatorFinalize,
        bool canPublicFinalize,
        uint256 creatorGraceEnds,
        uint8 finalizationReason
    ) {
        Registry.CampaignData memory campaign = registry().getCampaign(token);
        uint8 status = registry().getCampaignStatus(token);
        
        if (status != STATUS_PENDING && status != STATUS_ACTIVE) {
            return (false, false, 0, 0);
        }
        
        bool conditionsMet = _canFinalize(campaign);
        if (!conditionsMet) {
            return (false, false, 0, 0);
        }
        
        // Determine reason
        if ((campaign.overageType == OVERAGE_CEILING || campaign.overageType == OVERAGE_NONE) 
            && campaign.totalRaised >= campaign.ceiling) {
            finalizationReason = 1;
        } else if (campaign.totalRaised >= campaign.floor && campaign.totalRaised <= campaign.ceiling) {
            finalizationReason = 2;
        } else {
            finalizationReason = 3;
        }
        
        canCreatorFinalize = true;
        
        uint256 finalizableAt = _getFinalizableTimestamp(campaign);
        creatorGraceEnds = finalizableAt + CREATOR_FINALIZE_GRACE_PERIOD;
        canPublicFinalize = block.timestamp >= creatorGraceEnds;
    }
}
