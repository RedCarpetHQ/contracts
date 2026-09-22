// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./MinimumERC20.sol";
import "./Registry.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./interfaces/IMultiRoundLogic.sol";
import "./CampaignAdmin.sol";
import "./CampaignFeeManager.sol";
import "./logic/CampaignFeeLib.sol";

/**
 * @title BaseCampaign
 * @notice Abstract base contract for campaign functionality shared between single-round and multi-round campaigns
 * @dev Contains shared constants, helpers, and internal functions
 * @dev Upgradeable version - uses storage instead of immutable for registry and campaignAdmin
 */
abstract contract BaseCampaign is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Clones for address;

    // Campaign status constants (must match Registry.sol)
    uint8 internal constant STATUS_PENDING = 1;
    uint8 internal constant STATUS_ACTIVE = 2;
    uint8 internal constant STATUS_SUCCESS = 3;
    uint8 internal constant STATUS_FAILED = 4;
    uint8 internal constant STATUS_CANCELLED = 5;
    
    // Overage type constants (must match Registry.sol)
    uint8 internal constant OVERAGE_NONE = 0;
    uint8 internal constant OVERAGE_UNLIMITED = 1;
    uint8 internal constant OVERAGE_CEILING = 2;
    
    uint256 public constant GRACE_PERIOD = 24 hours;
    uint256 public constant CREATOR_FINALIZE_GRACE_PERIOD = 2 weeks;

    /// @custom:storage-location erc7201:redcarpet.storage.BaseCampaign
    struct BaseCampaignStorage {
        Registry registry;
        mapping(address => bool) fundsWithdrawn;
        mapping(address => mapping(address => uint256)) purchases;
        mapping(address => uint256) uniqueBuyerCount;
    }

    // WARNING: This is NOT the actual ERC-7201 hash of "redcarpet.storage.BaseCampaign".
    // It is a placeholder that was deployed to production proxies and MUST NOT be changed,
    // or all existing storage will be lost on upgrade.
    // Actual ERC-7201 hash would be: 0xaa77eec3219edd57f027ace241ddc98f6bf257549f30be9da7bd26448cd9f500
    bytes32 private constant BaseCampaignStorageLocation = 0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a00;

    function _getBaseCampaignStorage() internal pure returns (BaseCampaignStorage storage $) {
        assembly {
            $.slot := BaseCampaignStorageLocation
        }
    }

    // Public getters for storage variables
    function registry() public view returns (Registry) {
        return _getBaseCampaignStorage().registry;
    }

    function campaignAdmin() public view returns (CampaignAdmin) {
        return CampaignAdmin(_getBaseCampaignStorage().registry.campaignAdmin());
    }

    function fundsWithdrawn(address token) public view returns (bool) {
        return _getBaseCampaignStorage().fundsWithdrawn[token];
    }

    function purchases(address token, address buyer) public view returns (uint256) {
        return _getBaseCampaignStorage().purchases[token][buyer];
    }

    function uniqueBuyerCount(address token) public view returns (uint256) {
        return _getBaseCampaignStorage().uniqueBuyerCount[token];
    }

    // Shared events
    event CampaignCreated(
        address indexed token,
        address indexed creator,
        string campaignId,
        address paymentToken,
        string name,
        string symbol,
        uint256 floor,
        uint256 ceiling,
        uint8 overageType,
        address fundsRecipient,
        uint256 startTime,
        uint256 endTime
    );
    event TokensPurchased(address indexed token, address indexed buyer, uint256 amount, uint256 cost);
    event CampaignCancelled(address indexed token);
    event CampaignCancelledByScreener(address indexed token, address indexed screener);
    event CampaignEnded(address indexed token, bool success, uint256 totalRaised, uint256 totalSupply);
    event CampaignConcludedAtCeiling(address indexed token, uint256 totalRaised);
    event SupplyLocked(address indexed token, uint256 finalSupply);
    event Refunded(address indexed token, address indexed buyer, uint256 tokenAmount, uint256 refundAmount);
    event FundsTransferred(address indexed token, address indexed recipient, uint256 amount);
    event TokenVaultScheduled(address indexed token, address indexed vault, uint256 activationTime);
    event UiFeeCollected(address indexed token, address indexed integrator, uint256 amount);

    /**
     * @notice Initialize BaseCampaign contract (replaces constructor for upgradeable pattern)
     * @param _owner Initial owner address
     * @param _registry Registry contract address
     * @param _campaignAdmin CampaignAdmin contract address (DEPRECATED - kept for backward compatibility)
     */
    function __BaseCampaign_init(
        address _owner,
        address _registry,
        address _campaignAdmin
    ) internal onlyInitializing {
        __Ownable_init();
        __ReentrancyGuard_init();
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        // _campaignAdmin parameter is deprecated but kept for backward compatibility
        // CampaignAdmin is now fetched from Registry
        
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        $.registry = Registry(_registry);
    }
    
    // setCampaignAdmin() removed - CampaignAdmin is now fetched from Registry
    // To update CampaignAdmin, call Registry.setCampaignAdmin() instead
    // UI fee registration is now on CampaignFeeManager (set via Registry)

    function _getCampaignFeeManager() internal view returns (CampaignFeeManager) {
        address addr = _getBaseCampaignStorage().registry.campaignFeeManager();
        return addr != address(0) ? CampaignFeeManager(addr) : CampaignFeeManager(address(0));
    }

    // --- Registry Address Helpers ---
    
    function _getTokenImplementation() internal view returns (address) {
        return _getBaseCampaignStorage().registry.tokenImplementation();
    }
    
    function _getLendingManager() internal view returns (ILendingManager) {
        address addr = _getBaseCampaignStorage().registry.lendingManager();
        return addr != address(0) ? ILendingManager(addr) : ILendingManager(address(0));
    }
    
    function _getDividendDistributor() internal view returns (address) {
        return _getBaseCampaignStorage().registry.dividendDistributor();
    }
    
    function _getOptimisticPriceOracle() internal view returns (address) {
        return _getBaseCampaignStorage().registry.optimisticPriceOracle();
    }
    
    function _getSurveySnapshot() internal view returns (address) {
        return _getBaseCampaignStorage().registry.surveySnapshot();
    }
    
    function _getBurnRedemption() internal view returns (address) {
        return _getBaseCampaignStorage().registry.burnRedemption();
    }
    
    function _getMultiRoundLogic() internal view returns (IMultiRoundLogic) {
        address addr = _getBaseCampaignStorage().registry.multiRoundLogic();
        return addr != address(0) ? IMultiRoundLogic(addr) : IMultiRoundLogic(address(0));
    }

    /**
     * @notice Internal helper for token purchase — template method pattern
     * @dev Calls virtual hooks: _validatePurchase → _getRemainingCapacity → execute → _postPurchase
     *      Default hook implementations use Registry campaign-level data (correct for single-round).
     *      MultiRoundCampaign overrides hooks to use round-level data.
     * @param token Campaign token address
     * @param roundId Round ID (0 for single-round)
     * @param amount Amount of tokens to purchase
     * @param buyer Address of the buyer
     * @param uiFeeReceiver Optional integrator address to receive UI fee (address(0) if none)
     */
    function _purchaseTokensInternal(address token, uint256 roundId, uint256 amount, address buyer, address uiFeeReceiver) internal virtual {
        require(amount > 0, "Amount must be > 0");
        
        // Step 1: Validate (virtual)
        _validatePurchase(token, roundId);
        
        // Step 2: Calculate remaining capacity (virtual)
        uint256 remaining = _getRemainingCapacity(token, roundId);
        if (amount > remaining) {
            amount = remaining;
        }
        require(amount > 0, "No capacity remaining");
        
        // Step 3: Execute transfer + mint (shared, non-virtual)
        address paymentToken = _getBaseCampaignStorage().registry.getCampaign(token).paymentToken;
        IERC20(paymentToken).safeTransferFrom(buyer, address(this), amount);
        MinimumERC20(token).mint(buyer, amount);

        // Step 3b: Collect UI fee for integrator via CampaignFeeManager + CampaignFeeLib
        if (uiFeeReceiver != address(0)) {
            CampaignFeeManager feeManager = _getCampaignFeeManager();
            if (address(feeManager) != address(0)) {
                uint256 factor = feeManager.uiFeeFactor(uiFeeReceiver);
                uint256 uiFee = CampaignFeeLib.collectUiFee(paymentToken, buyer, uiFeeReceiver, factor, amount);
                if (uiFee > 0) {
                    emit UiFeeCollected(token, uiFeeReceiver, uiFee);
                }
            }
        }
        
        // Step 4: Update tracking (virtual)
        _postPurchase(token, roundId, amount, buyer);
    }

    /**
     * @notice Validate purchase preconditions — virtual hook
     * @dev Default: checks campaign-level time window and status from Registry.
     *      MultiRoundCampaign overrides to check round-level time window and round status.
     */
    function _validatePurchase(address token, uint256 roundId) internal virtual view {
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        Registry.CampaignData memory campaign = $.registry.getCampaign(token);
        require(campaign.token != address(0), "Campaign does not exist");
        require(block.timestamp >= campaign.startTime, "Campaign not started");
        require(block.timestamp <= campaign.endTime, "Campaign ended");
        uint8 status = $.registry.getCampaignStatus(token);
        require(status == STATUS_PENDING || status == STATUS_ACTIVE, "Campaign not active");
    }

    /**
     * @notice Get remaining purchase capacity — virtual hook
     * @dev Default: uses campaign-level ceiling/totalRaised from Registry.
     *      MultiRoundCampaign overrides to use round-level ceiling/totalRaised.
     */
    function _getRemainingCapacity(address token, uint256 roundId) internal virtual view returns (uint256) {
        Registry.CampaignData memory campaign = _getBaseCampaignStorage().registry.getCampaign(token);
        if (campaign.overageType == OVERAGE_NONE || campaign.overageType == OVERAGE_CEILING) {
            if (campaign.totalRaised >= campaign.ceiling) return 0;
            return campaign.ceiling - campaign.totalRaised;
        }
        return type(uint256).max;
    }

    /**
     * @notice Post-purchase tracking and events — virtual hook
     * @dev Default: updates base tracking (purchases, uniqueBuyerCount, Registry totalRaised).
     *      MultiRoundCampaign overrides to add round-level tracking.
     */
    function _postPurchase(address token, uint256 roundId, uint256 amount, address buyer) internal virtual {
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        if ($.purchases[token][buyer] == 0) {
            $.uniqueBuyerCount[token]++;
        }
        $.purchases[token][buyer] += amount;
        
        Registry.CampaignData memory campaign = $.registry.getCampaign(token);
        $.registry.updateCampaignRaise(token, campaign.totalRaised + amount);
        
        emit TokensPurchased(token, buyer, amount, amount);
        
        // Auto-conclude when ceiling reached (single-round only — MultiRound overrides)
        if (campaign.overageType == OVERAGE_CEILING && campaign.totalRaised + amount >= campaign.ceiling) {
            emit CampaignConcludedAtCeiling(token, campaign.totalRaised + amount);
        }
    }

    /**
     * @notice Internal helper for cancellation — template method pattern
     * @dev Calls virtual hooks: _validateCancel → _executeCancel
     *      Default: cancels at campaign level via Registry (correct for single-round).
     *      MultiRoundCampaign overrides to cancel at round level.
     * @param token Campaign token address
     * @param roundId Round ID (0 for single-round)
     * @param canceller Address of the canceller
     */
    function _cancelInternal(address token, uint256 roundId, address canceller) internal virtual {
        _validateCancel(token, roundId);
        _executeCancel(token, roundId, canceller);
    }

    /**
     * @notice Validate cancellation preconditions — virtual hook
     * @dev Default: checks campaign-level status is PENDING or ACTIVE.
     *      MultiRoundCampaign overrides to check round-level status.
     */
    function _validateCancel(address token, uint256 roundId) internal virtual view {
        uint8 status = _getBaseCampaignStorage().registry.getCampaignStatus(token);
        require(
            status == STATUS_PENDING || status == STATUS_ACTIVE,
            "Campaign cannot be cancelled"
        );
    }

    /**
     * @notice Execute cancellation — virtual hook
     * @dev Default: sets campaign cancelled flag in Registry (correct for single-round).
     *      MultiRoundCampaign overrides to set round status to CANCELLED instead.
     */
    function _executeCancel(address token, uint256 roundId, address canceller) internal virtual {
        _getBaseCampaignStorage().registry.setCampaignCancelled(token);
        emit CampaignCancelled(token);
    }

    /**
     * @notice Internal helper for refunds — template method pattern
     * @dev Calls virtual hook: _validateRefund → execute burn + transfer
     *      Default: checks campaign-level FAILED/CANCELLED status.
     *      MultiRoundCampaign overrides to check round-level status.
     * @param token Campaign token address
     * @param roundId Round ID (0 for single-round)
     * @param tokenAmount Amount of tokens to refund
     * @param holder Address of the token holder
     */
    function _refundInternal(address token, uint256 roundId, uint256 tokenAmount, address holder) internal virtual {
        require(tokenAmount > 0, "Amount must be > 0");
        
        // Step 1: Validate (virtual)
        _validateRefund(token, roundId);
        
        // Step 2: Execute burn + transfer (shared, non-virtual)
        address paymentToken = _getBaseCampaignStorage().registry.getCampaign(token).paymentToken;
        
        uint256 holderBalance = MinimumERC20(token).balanceOf(holder);
        require(holderBalance >= tokenAmount, "Insufficient token balance");
        
        uint256 allowance = MinimumERC20(token).allowance(holder, address(this));
        require(allowance >= tokenAmount, "Approve Campaign to burn tokens first");
        
        MinimumERC20(token).burnFrom(holder, tokenAmount);
        IERC20(paymentToken).safeTransfer(holder, tokenAmount);
        
        emit Refunded(token, holder, tokenAmount, tokenAmount);
    }

    /**
     * @notice Validate refund preconditions — virtual hook
     * @dev Default: checks campaign-level status is FAILED or CANCELLED.
     *      MultiRoundCampaign overrides to check round-level status.
     */
    function _validateRefund(address token, uint256 roundId) internal virtual view {
        require(_isRefundable(token), "Refunds not available");
    }

    /**
     * @notice Check if campaign is refundable at the campaign level
     * @dev Used by single-round. MultiRound checks round-level status instead.
     */
    function _isRefundable(address token) internal view returns (bool) {
        uint8 status = _getBaseCampaignStorage().registry.getCampaignStatus(token);
        return status == STATUS_FAILED || status == STATUS_CANCELLED;
    }

    /**
     * @notice Internal helper to collect funds (works for both single and multi-round)
     * @param token Campaign token address
     * @param roundId Round ID (0 for single-round)
     * @param recipient Address to receive funds
     * @param amount Amount to transfer
     */
    function _collectFunds(address token, uint256 roundId, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        require(!$.fundsWithdrawn[token], "Already collected");
        $.fundsWithdrawn[token] = true;
        
        address paymentToken = $.registry.getCampaign(token).paymentToken;
        IERC20(paymentToken).safeTransfer(recipient, amount);
        
        emit FundsTransferred(token, recipient, amount);
    }

    /**
     * @notice Get all creators for a campaign
     * @param token Campaign token address
     * @return creators Array of creator addresses
     */
    function getCampaignCreators(address token) external view returns (address[] memory) {
        return _getBaseCampaignStorage().registry.getCampaignCreators(token);
    }

    /**
     * @notice Emergency cancel campaign by screener
     * @param token Campaign token address
     */
    function screenerCancelCampaign(address token) external virtual nonReentrant {
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        require(campaignAdmin().screeners(msg.sender), "Only screener");
        Registry.CampaignData memory campaign = $.registry.getCampaign(token);
        require(campaign.token != address(0), "Campaign does not exist");
        uint8 status = $.registry.getCampaignStatus(token);
        require(
            status == STATUS_PENDING || status == STATUS_ACTIVE,
            "Campaign cannot be cancelled"
        );

        $.registry.setCampaignCancelled(token);
        emit CampaignCancelledByScreener(token, msg.sender);
    }

    // View functions
    function getCampaignStatus(address token) external view returns (uint8) {
        return _getBaseCampaignStorage().registry.getCampaignStatus(token);
    }

    function getCampaignProgress(address token)
        external
        view
        returns (uint256 raised, uint256 target, uint256 percentage)
    {
        return _getBaseCampaignStorage().registry.getCampaignProgress(token);
    }

    function getUserPurchase(address token, address user) external view returns (uint256) {
        return _getBaseCampaignStorage().purchases[token][user];
    }

    /**
     * @notice Get token campaign details
     * @param token Campaign token address
     */
    function getTokenCampaignDetails(address token) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 amountPurchased,
        uint256 floor,
        uint256 ceiling,
        uint256 numUniqueBuyers
    ) {
        BaseCampaignStorage storage $ = _getBaseCampaignStorage();
        Registry.CampaignData memory campaign = $.registry.getCampaign(token);
        startTime = campaign.startTime;
        endTime = campaign.endTime;
        amountPurchased = campaign.totalRaised;
        floor = campaign.floor;
        ceiling = campaign.ceiling;
        numUniqueBuyers = $.uniqueBuyerCount[token];
    }

    /**
     * @notice Check if user can refund tokens
     * @param token Campaign token address
     * @param user User address to check
     */
    function canRefund(address token, address user) external view returns (bool) {
        uint256 tokenBalance = MinimumERC20(token).balanceOf(user);
        return _isRefundable(token) && tokenBalance > 0;
    }
}
