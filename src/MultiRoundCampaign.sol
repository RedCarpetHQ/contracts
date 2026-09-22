// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./BaseCampaign.sol";
import "./interfaces/IMultiRoundLogic.sol";

/**
 * @title MultiRoundCampaign
 * @notice Extends BaseCampaign to support multi-round fundraising campaigns
 * @dev Reuses all BaseCampaign internal helpers while adding multi-round specific functionality
 * @dev UUPS Upgradeable - can be upgraded by owner
 */
contract MultiRoundCampaign is BaseCampaign, UUPSUpgradeable {
    using Clones for address;
    using SafeERC20 for IERC20;
    
    /// @custom:storage-location erc7201:redcarpet.storage.MultiRoundCampaign
    struct MultiRoundCampaignStorage {
        mapping(address => bool) isMultiRound;
        mapping(address => IMultiRoundLogic.MultiRoundState) multiRoundState;
        mapping(address => mapping(uint256 => IMultiRoundLogic.Round)) rounds;
        mapping(address => mapping(uint256 => mapping(address => uint256))) roundPurchases;
        mapping(address => mapping(uint256 => mapping(address => bool))) hasPurchasedInRound;
        mapping(address => mapping(uint256 => uint256)) refundPool;
    }

    // keccak256(abi.encode(uint256(keccak256("redcarpet.storage.MultiRoundCampaign")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MultiRoundCampaignStorageLocation = 0xabf08a16a75855560bb683a2330cd7b06779069bd6aa1862ba20d8a336d9bd00;

    function _getMultiRoundCampaignStorage() private pure returns (MultiRoundCampaignStorage storage $) {
        assembly {
            $.slot := MultiRoundCampaignStorageLocation
        }
    }

    // Public getters for storage variables
    function isMultiRound(address token) public view returns (bool) {
        return _getMultiRoundCampaignStorage().isMultiRound[token];
    }

    function multiRoundState(address token) public view returns (IMultiRoundLogic.MultiRoundState memory) {
        return _getMultiRoundCampaignStorage().multiRoundState[token];
    }

    function rounds(address token, uint256 roundId) public view returns (IMultiRoundLogic.Round memory) {
        return _getMultiRoundCampaignStorage().rounds[token][roundId];
    }

    function roundPurchases(address token, uint256 roundId, address buyer) public view returns (uint256) {
        return _getMultiRoundCampaignStorage().roundPurchases[token][roundId][buyer];
    }

    function hasPurchasedInRound(address token, uint256 roundId, address buyer) public view returns (bool) {
        return _getMultiRoundCampaignStorage().hasPurchasedInRound[token][roundId][buyer];
    }

    function refundPool(address token, uint256 roundId) public view returns (uint256) {
        return _getMultiRoundCampaignStorage().refundPool[token][roundId];
    }
    
    event MultiRoundCampaignCreated(address indexed token, address indexed creator, uint256 timestamp);
    event RoundCreated(address indexed token, uint256 indexed roundId, uint256 floor, uint256 ceiling, uint8 overageType, uint256 startTime, uint256 endTime);
    event RoundStarted(address indexed token, uint256 indexed roundId, uint256 timestamp);
    event RoundEnded(address indexed token, uint256 indexed roundId, uint8 status, uint256 totalRaised, uint256 tokensMinted);
    event RoundStatusChanged(address indexed token, uint256 indexed roundId, uint8 oldStatus, uint8 newStatus);
    event RoundFundsCollected(address indexed token, uint256 indexed roundId, address indexed recipient, uint256 amount);
    event RoundCancelled(address indexed token, uint256 indexed roundId, address indexed canceller);
    event AllRoundsCancelled(address indexed token, address indexed canceller);
    event RoundRefunded(address indexed token, uint256 indexed roundId, address indexed user, uint256 tokenAmount, uint256 refundAmount);
    event MultiRoundFinalized(address indexed token, uint256 totalRounds, uint256 totalRaised, uint256 finalSupply, address finalizer);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the MultiRoundCampaign contract
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
    
    function createMultiRoundCampaign(
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

        // Register campaign in registry
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
        
        // Mark as multi-round in Registry
        registry().setMultiRoundFlag(token);
        
        // Add additional creators if provided
        if (additionalCreators.length > 0) {
            registry().addCampaignCreators(token, additionalCreators, msg.sender);
        }
        
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        $.isMultiRound[token] = true;
        
        $.multiRoundState[token] = IMultiRoundLogic.MultiRoundState({
            totalRoundsCreated: 1,
            currentRoundId: 1,
            totalRaisedAllRounds: 0,
            totalTokensMinted: 0,
            isFinalized: false,
            createdAt: block.timestamp,
            lastRoundEndTime: endTime,
            lastFundCollectionTime: 0,
            lastFailedRoundTime: 0
        });
        
        $.rounds[token][1] = IMultiRoundLogic.Round({
            roundId: 1,
            floor: floor,
            ceiling: ceiling,
            overageType: overageType,
            startTime: uint40(startTime),
            endTime: uint40(endTime),
            totalRaised: 0,
            tokensMinted: 0,
            status: STATUS_PENDING,
            fundsCollected: false,
            uniqueBuyers: 0
        });
        
        emit CampaignCreated(token, msg.sender, campaignId, paymentToken, name, symbol, floor, ceiling, overageType, recipient, startTime, endTime);
        emit MultiRoundCampaignCreated(token, msg.sender, block.timestamp);
        emit RoundCreated(token, 1, floor, ceiling, overageType, startTime, endTime);
    }
    
    function createNextRound(address token, uint256 floor, uint256 ceiling, uint8 overageType, uint256 startTime, uint256 endTime) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        
        // SECURITY: Validate campaign state before creating new round
        require(!$.multiRoundState[token].isFinalized, "Campaign finalized");
        require(!MinimumERC20(token).isSupplyLocked(), "Supply locked");
        
        IMultiRoundLogic logic = _getMultiRoundLogic();
        
        uint256 lastSuccessfulFloor;
        bool hasSuccessful;
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        for (uint256 i = 1; i <= totalRounds; ) {
            if ($.rounds[token][i].status == STATUS_SUCCESS) {
                lastSuccessfulFloor = $.rounds[token][i].floor;
                hasSuccessful = true;
            }
            unchecked { ++i; }
        }
        
        (bool isValid, string memory errorMessage) = logic.validateRoundCreation($.multiRoundState[token], lastSuccessfulFloor, hasSuccessful, floor, ceiling, overageType, startTime, endTime);
        require(isValid, errorMessage);
        
        uint256 newRoundId = totalRounds + 1;
        uint256 validatedCeiling = logic.validateCeiling(floor, ceiling, overageType);
        
        IMultiRoundLogic.Round storage round = $.rounds[token][newRoundId];
        round.roundId = newRoundId;
        round.floor = floor;
        round.ceiling = validatedCeiling;
        round.overageType = overageType;
        round.startTime = uint40(startTime);
        round.endTime = uint40(endTime);
        round.status = STATUS_PENDING;
        
        $.multiRoundState[token].totalRoundsCreated = newRoundId;
        $.multiRoundState[token].currentRoundId = newRoundId;
        $.multiRoundState[token].lastRoundEndTime = endTime;
        
        emit RoundCreated(token, newRoundId, floor, validatedCeiling, overageType, startTime, endTime);
    }
    
    function purchaseTokensMultiRound(address token, uint256 amount, address uiFeeReceiver) external nonReentrant {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        _purchaseTokensInternal(token, $.multiRoundState[token].currentRoundId, amount, msg.sender, uiFeeReceiver);
    }
    
    // ========== Virtual Hook Overrides ==========

    /**
     * @notice Override: validate purchase using round-level data (not campaign-level)
     * @dev Checks round existence, time window, and round status
     */
    function _validatePurchase(address token, uint256 roundId) internal override view {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        require($.isMultiRound[token], "Not multi-round");
        require(!$.multiRoundState[token].isFinalized, "Campaign finalized");
        
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        require(round.roundId > 0, "Round does not exist");
        require(block.timestamp >= round.startTime, "Round not started");
        require(block.timestamp <= round.endTime, "Round ended");
        require(
            round.status == STATUS_PENDING || round.status == STATUS_ACTIVE,
            "Round not active"
        );
    }

    /**
     * @notice Override: get remaining capacity from round-level data
     * @dev Delegates to MultiRoundLogic.calculateRemainingCapacity
     */
    function _getRemainingCapacity(address token, uint256 roundId) internal override view returns (uint256) {
        IMultiRoundLogic.Round memory round = _getMultiRoundCampaignStorage().rounds[token][roundId];
        return _getMultiRoundLogic().calculateRemainingCapacity(round);
    }

    /**
     * @notice Override: post-purchase tracking for both base and round level
     * @dev Does NOT call super._postPurchase to avoid campaign-level ceiling check.
     *      Instead, duplicates the base tracking (4 lines) and adds round-level tracking.
     */
    function _postPurchase(address token, uint256 roundId, uint256 amount, address buyer) internal override {
        // --- Base-level tracking (duplicated from BaseCampaign to avoid super's ceiling check) ---
        BaseCampaignStorage storage $base = _getBaseCampaignStorage();
        if ($base.purchases[token][buyer] == 0) {
            $base.uniqueBuyerCount[token]++;
        }
        $base.purchases[token][buyer] += amount;
        
        // Update Registry totalRaised (global sum across all rounds)
        Registry.CampaignData memory campaign = $base.registry.getCampaign(token);
        $base.registry.updateCampaignRaise(token, campaign.totalRaised + amount);
        
        emit TokensPurchased(token, buyer, amount, amount);
        
        // --- Round-level tracking ---
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        
        round.totalRaised += amount;
        round.tokensMinted += amount;
        
        $.roundPurchases[token][roundId][buyer] += amount;
        
        if (!$.hasPurchasedInRound[token][roundId][buyer]) {
            round.uniqueBuyers++;
            $.hasPurchasedInRound[token][roundId][buyer] = true;
        }
        
        $.multiRoundState[token].totalRaisedAllRounds += amount;
        $.multiRoundState[token].totalTokensMinted += amount;
        
        // Round-level ceiling check
        if (round.overageType == OVERAGE_CEILING && round.totalRaised >= round.ceiling) {
            emit CampaignConcludedAtCeiling(token, round.totalRaised);
        }
    }
    
    /**
     * @notice Override: validate refund using round-level status
     * @dev Allows refunds from individual failed/cancelled rounds even if the campaign is still active
     */
    function _validateRefund(address token, uint256 roundId) internal override view {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        require(
            round.status == STATUS_FAILED || round.status == STATUS_CANCELLED,
            "Round not refundable"
        );
    }

    /**
     * @notice Override: validate cancellation using round-level status
     * @dev Checks the specific round's status, not the campaign-level status
     */
    function _validateCancel(address token, uint256 roundId) internal override view {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        require(
            round.status == STATUS_PENDING || round.status == STATUS_ACTIVE,
            "Round cannot be cancelled"
        );
    }

    /**
     * @notice Override: execute cancellation at round level (NOT campaign level)
     * @dev Sets the round status to CANCELLED and populates the refund pool.
     *      Does NOT call registry.setCampaignCancelled — only cancelAllRounds does that.
     */
    function _executeCancel(address token, uint256 roundId, address canceller) internal override {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        round.status = STATUS_CANCELLED;
        $.refundPool[token][roundId] = round.totalRaised;
        emit RoundCancelled(token, roundId, canceller);
    }
    
    function refundRound(address token, uint256 roundId) external nonReentrant {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        _refundInternal(token, roundId, $.roundPurchases[token][roundId][msg.sender], msg.sender);
    }
    
    function collectRoundFunds(address token, uint256 roundId) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        require(round.status == STATUS_SUCCESS, "Round not successful");
        require(!round.fundsCollected, "Funds already collected");
        
        round.fundsCollected = true;
        
        address recipient = registry().getCampaign(token).fundsRecipient;
        address paymentToken = registry().getCampaign(token).paymentToken;
        IERC20(paymentToken).safeTransfer(recipient, round.totalRaised);
        
        emit RoundFundsCollected(token, roundId, recipient, round.totalRaised);
    }
    
    function collectAllFunds(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        address recipient = registry().getCampaign(token).fundsRecipient;
        address paymentToken = registry().getCampaign(token).paymentToken;
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        
        for (uint256 i = 1; i <= totalRounds; ) {
            IMultiRoundLogic.Round storage round = $.rounds[token][i];
            if (round.status == STATUS_SUCCESS && !round.fundsCollected) {
                round.fundsCollected = true;
                IERC20(paymentToken).safeTransfer(recipient, round.totalRaised);
                emit RoundFundsCollected(token, i, recipient, round.totalRaised);
            }
            unchecked { ++i; }
        }
    }
    
    function cancelRound(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        _cancelInternal(token, $.multiRoundState[token].currentRoundId, msg.sender);
    }
    
    /**
     * @notice Cancel all active/pending rounds and the entire campaign
     * @dev First cancels each round at round level, then sets campaign-level cancelled in Registry.
     *      This is the ONLY multi-round path that sets registry.setCampaignCancelled.
     */
    function cancelAllRounds(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        
        // Cancel each active/pending round at round level
        for (uint256 i = 1; i <= totalRounds; ) {
            IMultiRoundLogic.Round storage round = $.rounds[token][i];
            if (!round.fundsCollected && (round.status == STATUS_PENDING || round.status == STATUS_ACTIVE)) {
                // Uses overridden _executeCancel → sets round.status = CANCELLED
                _cancelInternal(token, i, msg.sender);
            }
            unchecked { ++i; }
        }
        
        // Set campaign-level cancelled flag in Registry
        registry().setCampaignCancelled(token);
        emit AllRoundsCancelled(token, msg.sender);
    }
    
    function endRound(address token, uint256 roundId) external nonReentrant {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic.Round storage round = $.rounds[token][roundId];
        require(round.status == STATUS_PENDING || round.status == STATUS_ACTIVE, "Round already ended");
        
        (bool shouldEnd, bool isSuccess) = _getMultiRoundLogic().shouldEndRound(round);
        require(shouldEnd, "Round cannot end yet");
        
        uint8 newStatus = isSuccess ? STATUS_SUCCESS : STATUS_FAILED;
        if (!isSuccess) {
            $.refundPool[token][roundId] = round.totalRaised;
            $.multiRoundState[token].lastFailedRoundTime = block.timestamp;
        }
        
        emit RoundStatusChanged(token, roundId, round.status, newStatus);
        round.status = newStatus;
        emit RoundEnded(token, roundId, newStatus, round.totalRaised, round.tokensMinted);
    }
    
    function creatorFinalizeMultiRound(address token) external nonReentrant {
        require(registry().isCampaignCreator(token, msg.sender), "Only creator");
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic logic = _getMultiRoundLogic();
        require(logic.canCreatorFinalize($.multiRoundState[token], _hasSuccessfulRound(token), _isCurrentRoundEnded(token)), "Cannot finalize yet");
        _finalizeMultiRound(token, msg.sender);
    }
    
    function publicFinalizeMultiRound(address token) external nonReentrant {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        IMultiRoundLogic logic = _getMultiRoundLogic();
        require(logic.canPublicFinalize($.multiRoundState[token], _hasSuccessfulRound(token), _isCurrentRoundEnded(token)), "Cannot finalize yet");
        _finalizeMultiRound(token, msg.sender);
    }
    
    function _finalizeMultiRound(address token, address finalizer) internal {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        
        // Mark as finalized FIRST to prevent re-entry via createNextRound
        $.multiRoundState[token].isFinalized = true;
        
        MinimumERC20 tokenContract = MinimumERC20(token);
        uint256 finalSupply = tokenContract.totalSupply();
        tokenContract.lockSupply();
        registry().enableMarket(token);
        emit SupplyLocked(token, finalSupply);
        
        address recipient = registry().getCampaign(token).fundsRecipient;
        address paymentToken = registry().getCampaign(token).paymentToken;
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        uint256 totalRaised;
        
        for (uint256 i = 1; i <= totalRounds; ) {
            IMultiRoundLogic.Round storage round = $.rounds[token][i];
            if (round.status == STATUS_SUCCESS) {
                totalRaised += round.totalRaised;
                if (!round.fundsCollected) {
                    round.fundsCollected = true;
                    IERC20(paymentToken).safeTransfer(recipient, round.totalRaised);
                    emit RoundFundsCollected(token, i, recipient, round.totalRaised);
                }
            }
            unchecked { ++i; }
        }
        
        // Create lending vault (with null check — SingleRound has this, was missing here)
        ILendingManager lendingManager = _getLendingManager();
        require(address(lendingManager) != address(0), "LendingManager not set");
        address stableVault = lendingManager.createVaultsOnCampaignSuccess(token);
        (bool exists, , uint256 activationTime, ) = lendingManager.getVaultStatus(token);
        require(exists, "Vault creation failed");
        emit TokenVaultScheduled(token, stableVault, activationTime);
        
        tokenContract.renounceOwnership();
        emit MultiRoundFinalized(token, totalRounds, totalRaised, finalSupply, finalizer);
    }
    
    function _hasSuccessfulRound(address token) internal view returns (bool) {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        for (uint256 i = 1; i <= totalRounds; ) {
            if ($.rounds[token][i].status == STATUS_SUCCESS) return true;
            unchecked { ++i; }
        }
        return false;
    }
    
    function _isCurrentRoundEnded(address token) internal view returns (bool) {
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        uint256 currentRoundId = $.multiRoundState[token].currentRoundId;
        if (currentRoundId == 0) return true;
        
        IMultiRoundLogic.Round storage round = $.rounds[token][currentRoundId];
        return block.timestamp > round.endTime || 
               round.status == STATUS_SUCCESS || 
               round.status == STATUS_FAILED || 
               round.status == STATUS_CANCELLED;
    }
    
    /**
     * @notice Override screener cancel for multi-round: cancels all rounds then campaign
     * @dev Screener emergency action — cancels all active/pending rounds AND sets campaign-level cancelled
     */
    function screenerCancelCampaign(address token) external override nonReentrant {
        BaseCampaignStorage storage $base = _getBaseCampaignStorage();
        require(campaignAdmin().screeners(msg.sender), "Only screener");
        Registry.CampaignData memory campaign = $base.registry.getCampaign(token);
        require(campaign.token != address(0), "Campaign does not exist");
        
        MultiRoundCampaignStorage storage $ = _getMultiRoundCampaignStorage();
        uint256 totalRounds = $.multiRoundState[token].totalRoundsCreated;
        
        // Cancel each active/pending round at round level
        for (uint256 i = 1; i <= totalRounds; ) {
            IMultiRoundLogic.Round storage round = $.rounds[token][i];
            if (!round.fundsCollected && (round.status == STATUS_PENDING || round.status == STATUS_ACTIVE)) {
                round.status = STATUS_CANCELLED;
                $.refundPool[token][i] = round.totalRaised;
                emit RoundCancelled(token, i, msg.sender);
            }
            unchecked { ++i; }
        }
        
        // Set campaign-level cancelled
        $base.registry.setCampaignCancelled(token);
        emit CampaignCancelledByScreener(token, msg.sender);
    }

    // View functions - use public getters from namespaced storage
    function getRound(address token, uint256 roundId) external view returns (IMultiRoundLogic.Round memory) {
        return rounds(token, roundId);
    }
    
    function getMultiRoundState(address token) external view returns (IMultiRoundLogic.MultiRoundState memory) {
        return multiRoundState(token);
    }
    
    function getRoundPurchase(address token, uint256 roundId, address user) external view returns (uint256) {
        return roundPurchases(token, roundId, user);
    }
    
    function getTotalRounds(address token) external view returns (uint256) {
        return multiRoundState(token).totalRoundsCreated;
    }
    
    function getCurrentRoundId(address token) external view returns (uint256) {
        return multiRoundState(token).currentRoundId;
    }
    
    // Removed getAllRounds - frontend can call getRound(token, i) in a loop
    // This saves ~500 bytes and avoids expensive memory array allocation
    
    function getRoundStatusSummary(address token) external view returns (
        uint256 pending,
        uint256 active,
        uint256 successful,
        uint256 failed,
        uint256 cancelled
    ) {
        if (!isMultiRound(token)) return (0, 0, 0, 0, 0);
        
        uint256 totalRounds = multiRoundState(token).totalRoundsCreated;
        for (uint256 i = 1; i <= totalRounds; i++) {
            uint8 status = rounds(token, i).status;
            if (status == STATUS_PENDING) pending++;
            else if (status == STATUS_ACTIVE) active++;
            else if (status == STATUS_SUCCESS) successful++;
            else if (status == STATUS_FAILED) failed++;
            else if (status == STATUS_CANCELLED) cancelled++;
        }
    }
}
