// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Registry
 * @notice Upgradeable central registry for all protocol contracts and campaign data using UUPS pattern
 * @dev Single source of truth for protocol addresses, campaigns, tokens, and market state
 * 
 * UPGRADEABLE ARCHITECTURE:
 * - Uses OpenZeppelin's UUPS (Universal Upgradeable Proxy Standard)
 * - Unstructured storage pattern to avoid storage collisions
 * - Only owner can upgrade via _authorizeUpgrade
 * 
 * V3 CHANGES:
 * - Added FeeDistributor and feeSafe addresses
 * - Simplified LendingInfrastructure to only track UnifiedVault
 * - Added registerUnifiedVault() for V3 simplified registration
 * - Centralized access control for DividendDistributor, BurnRedemption, SurveySnapshot
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract Registry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // Campaign status (derived, not stored - for external compatibility)
    uint8 public constant STATUS_PENDING = 1;
    uint8 public constant STATUS_ACTIVE = 2;
    uint8 public constant STATUS_SUCCESS = 3;
    uint8 public constant STATUS_FAILED = 4;
    uint8 public constant STATUS_CANCELLED = 5;
    
    // Grace period for failed campaigns (must match BaseCampaign.sol)
    uint256 public constant GRACE_PERIOD = 24 hours;

    // Market status
    uint8 public constant MARKET_CLOSED = 0;
    uint8 public constant MARKET_OPEN = 1;

    // Overage type for campaigns
    uint8 public constant OVERAGE_NONE = 0;      // No overage allowed (floor only)
    uint8 public constant OVERAGE_UNLIMITED = 1; // Unlimited overage
    uint8 public constant OVERAGE_CEILING = 2;   // Capped at ceiling amount

    struct CampaignData {
        address creator;
        address token;
        address paymentToken;
        address fundsRecipient;     // Wallet to receive funds (default: creator)
        uint256 floor;              // Minimum amount needed (was minimumRaise)
        uint256 ceiling;            // Maximum amount if overage is CEILING (0 if unlimited)
        uint256 totalRaised;
        uint256 startTime;
        uint256 endTime;
        uint8 overageType;          // OVERAGE_NONE, OVERAGE_UNLIMITED, or OVERAGE_CEILING
        bool cancelled;             // Only stored flag - explicit creator action
        bool isMultiRound;          // Flag to identify multi-round campaigns
        uint256 createdAt;
    }

    struct MarketData {
        address token;
        uint8 status;
        uint256 enabledAt;
    }

    // Per-token lending infrastructure (complete isolation per campaign token)
    // V3: Simplified to only track UnifiedVault (consolidates 5 contracts into 1)
    struct LendingInfrastructure {
        address stableVault;      // V2: StableVaultV2 clone (deprecated in V3)
        address stabilityPool;    // V2: StabilityPool clone (deprecated in V3)
        address safetyModule;     // V2: SafetyModule clone (deprecated in V3)
        address vaultLedger;      // V2: VaultLedger clone (deprecated in V3)
        address unifiedVault;     // V3: UnifiedVault (ERC-4626, holds all logic)
        bool initialized;
    }

    // Storage
    mapping(address => CampaignData) public campaigns;
    mapping(address => LendingInfrastructure) public tokenLending;
    mapping(address => MarketData) public markets;
    mapping(address => address[]) public creatorCampaigns;
    address[] public allTokens;
    
    // Multi-creator support per campaign
    mapping(address => address[]) internal campaignCreators;        // token => array of creators
    mapping(address => mapping(address => bool)) public isCampaignCreator; // token => creator => bool

    // Authorized contracts
    mapping(address => bool) public authorizedContracts;
    
    // Centralized role management for DividendDistributor, BurnRedemption, SurveySnapshot
    mapping(address => mapping(address => bool)) public isDividendDistributor; // token => distributor => bool
    mapping(address => mapping(address => bool)) public isSurveyor;           // token => surveyor => bool
    
    // Protocol safe address for emergency fund recovery (set by owner)
    address public protocolSafe;
    
    // Keeper address for automated tasks (set by owner)
    address public keeper;
    
    // ===========================================
    // FEE DISCOUNT TIER LOGIC (Address Only)
    // ===========================================
    
    // TierLogic contract address (handles all tier calculations)
    // Registry only stores the address - logic is in separate contract
    address public tierLogic;
    
    // VolumeTracker contract address (stores daily volume data)
    // Used by TierLogic (30-day) and Contest (7-day) for volume calculations
    address public volumeTracker;
    
    // ===========================================
    // PROTOCOL CONTRACT ADDRESSES (Centralized)
    // ===========================================
    
    // Core tokens
    address public usdc;                    // USDC stablecoin address
    
    // Fee destinations
    address public feeWallet;               // Protocol fee wallet (Safe)
    
    // Core protocol contracts
    address public campaign;                // Campaign contract (single-round)
    address public campaignAdmin;           // CampaignAdmin contract (shared admin functions)
    address public multiRoundCampaign;      // MultiRoundCampaign contract (multi-round campaigns)
    address public market;                  // Market contract
    address public tokenImplementation;     // MinimumERC20 implementation for cloning
    
    // Oracle system
    address public hybridPriceOracle;       // HybridPriceOracle (VWAP)
    address public riskOracle;              // RiskOracle
    address public optimisticPriceOracle;   // OptimisticPriceOracle
    address public rateModel;               // JumpRateModel
    
    // Lending system
    address public lendingManager;          // LendingManager (deploys per-token infrastructure)
    address public marketIntegration;       // MarketIntegration
    
    // Distribution & rewards
    address public contest;                 // Contest contract
    address public dividendDistributor;     // DividendDistributor
    address public keeperRegistry;          // KeeperRegistry
    
    // V3: New contracts
    address public feeDistributor;          // FeeDistributor (central fee distribution)
    address public feeSafe;                 // Fee safe address (40% of fees)
    address public burnRedemption;          // BurnRedemption (burn-to-redeem events)
    address public surveySnapshot;          // SurveySnapshot (token holder snapshots)
    address public campaignFeeManager;      // CampaignFeeManager (UI/integrator fee registry)
    
    // V3: Logic contracts (deployed once, used by all vaults)
    address public interestLogic;           // InterestLogic (interest calculations)
    address public lendingLogic;            // LendingLogic (lending calculations)
    address public stabilityLogic;          // StabilityLogic (stability pool calculations)
    address public multiRoundLogic;         // MultiRoundLogic (multi-round campaign logic)
    // tierLogic is defined above in tier section

    // Timelock for critical operations
    uint256 public constant TIMELOCK_DELAY = 2 days;
    
    struct TimelockOperation {
        uint256 executeAfter;
        bool executed;
    }
    
    mapping(bytes32 => TimelockOperation) public timelockQueue;

    // Events
    event CampaignRegistered(
        address indexed token,
        address indexed creator,
        uint256 floor,
        uint256 ceiling,
        uint8 overageType,
        address fundsRecipient,
        uint256 startTime,
        uint256 endTime
    );
    event FundsRecipientUpdated(address indexed token, address indexed oldRecipient, address indexed newRecipient);
    event CampaignFloorUpdated(address indexed token, uint256 oldFloor, uint256 newFloor);
    event CampaignCeilingUpdated(address indexed token, uint256 oldCeiling, uint256 newCeiling);
    event CampaignStatusUpdated(address indexed token, uint8 oldStatus, uint8 newStatus);
    event CampaignRaiseUpdated(address indexed token, uint256 totalRaised);
    event CampaignTimesUpdated(address indexed token, uint256 newStartTime, uint256 newEndTime);
    event MarketStatusUpdated(address indexed token, uint8 status);
    event ContractAuthorized(address indexed contractAddress, bool authorized);
    event OperationQueued(bytes32 indexed operationId, uint256 executeAfter);
    event OperationExecuted(bytes32 indexed operationId);
    event OperationCancelled(bytes32 indexed operationId);
    event LendingInfrastructureRegistered(
        address indexed token,
        address stableVault,
        address stabilityPool,
        address safetyModule,
        address vaultLedger,
        address unifiedVault
    );
    // V3: Simplified event for UnifiedVault only
    event UnifiedVaultRegistered(address indexed token, address indexed unifiedVault);
    event ProtocolSafeSet(address indexed safe);
    event KeeperSet(address indexed keeper);
    event ProtocolAddressSet(string indexed name, address indexed addr);
    event CampaignCreatorAdded(address indexed token, address indexed creator, address indexed addedBy);
    event CampaignCreatorRemoved(address indexed token, address indexed creator, address indexed removedBy);
    event DividendDistributorSet(address indexed token, address indexed distributor, bool authorized);
    event SurveyorSet(address indexed token, address indexed surveyor, bool authorized);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Registry (replaces constructor for upgradeable pattern)
     * @param _owner Initial owner address
     */
    function initialize(address _owner) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_owner);
    }

    /**
     * @notice Authorize upgrade (UUPS requirement)
     * @dev Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    // --- Campaign Management ---

    function registerCampaign(
        address token,
        address creator,
        address paymentToken,
        uint256 floor,
        uint256 ceiling,
        uint8 overageType,
        address fundsRecipient,
        uint256 startTime,
        uint256 endTime
    ) external onlyAuthorized {
        require(campaigns[token].token == address(0), "Campaign already exists");
        require(token != address(0), "Invalid token");
        require(creator != address(0), "Invalid creator");

        campaigns[token] = CampaignData({
            creator: creator,
            token: token,
            paymentToken: paymentToken,
            fundsRecipient: fundsRecipient,
            floor: floor,
            ceiling: ceiling,
            totalRaised: 0,
            startTime: startTime,
            endTime: endTime,
            overageType: overageType,
            cancelled: false,
            isMultiRound: false,
            createdAt: block.timestamp
        });

        creatorCampaigns[creator].push(token);
        allTokens.push(token);
        
        // Initialize multi-creator support (primary creator is always first)
        campaignCreators[token].push(creator);
        isCampaignCreator[token][creator] = true;

        emit CampaignRegistered(token, creator, floor, ceiling, overageType, fundsRecipient, startTime, endTime);
    }
    
    /**
     * @notice Add additional creators to a campaign (called by Campaign contract)
     * @dev Does not add to whitelistedCreators - that's separate screener approval
     * @param token Campaign token address
     * @param creators Array of creator addresses to add
     * @param addedBy Address that initiated the add (for event)
     */
    function addCampaignCreators(address token, address[] calldata creators, address addedBy) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        
        for (uint256 i = 0; i < creators.length; i++) {
            address creator = creators[i];
            require(creator != address(0), "Invalid creator address");
            
            if (!isCampaignCreator[token][creator]) {
                campaignCreators[token].push(creator);
                isCampaignCreator[token][creator] = true;
                creatorCampaigns[creator].push(token);
                emit CampaignCreatorAdded(token, creator, addedBy);
            }
        }
    }
    
    /**
     * @notice Remove a creator from a campaign (called by Campaign contract)
     * @dev Cannot remove the last creator - minimum 1 required
     * @param token Campaign token address
     * @param creator Creator address to remove
     * @param removedBy Address that initiated the removal (for event)
     */
    function removeCampaignCreator(address token, address creator, address removedBy) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(isCampaignCreator[token][creator], "Not a creator");
        require(campaignCreators[token].length > 1, "Cannot remove last creator");
        
        isCampaignCreator[token][creator] = false;
        
        // Remove from array (swap and pop)
        address[] storage creators = campaignCreators[token];
        for (uint256 i = 0; i < creators.length; i++) {
            if (creators[i] == creator) {
                creators[i] = creators[creators.length - 1];
                creators.pop();
                break;
            }
        }
        
        // Remove token from creator's campaign list
        address[] storage creatorTokens = creatorCampaigns[creator];
        for (uint256 i = 0; i < creatorTokens.length; i++) {
            if (creatorTokens[i] == token) {
                creatorTokens[i] = creatorTokens[creatorTokens.length - 1];
                creatorTokens.pop();
                break;
            }
        }
        
        emit CampaignCreatorRemoved(token, creator, removedBy);
    }

    function setCampaignCancelled(address token) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(!campaigns[token].cancelled, "Already cancelled");
        campaigns[token].cancelled = true;
        emit CampaignStatusUpdated(token, STATUS_ACTIVE, STATUS_CANCELLED);
    }

    function updateCampaignRaise(address token, uint256 totalRaised) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        campaigns[token].totalRaised = totalRaised;
        emit CampaignRaiseUpdated(token, totalRaised);
    }

    /**
     * @notice Mark campaign as multi-round (called by MultiRoundCampaign contract)
     * @param token Campaign token address
     */
    function setMultiRoundFlag(address token) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(!campaigns[token].isMultiRound, "Already multi-round");
        campaigns[token].isMultiRound = true;
    }

    /**
     * @notice Check if campaign is multi-round
     * @param token Campaign token address
     * @return isMultiRound Whether campaign is multi-round
     */
    function isMultiRoundCampaign(address token) external view returns (bool) {
        return campaigns[token].isMultiRound;
    }

    function updateCampaignTimes(address token, uint256 newStartTime, uint256 newEndTime) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        campaigns[token].startTime = newStartTime;
        campaigns[token].endTime = newEndTime;
        emit CampaignTimesUpdated(token, newStartTime, newEndTime);
    }

    function updateCampaignFloor(address token, uint256 newFloor) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        uint256 oldFloor = campaigns[token].floor;
        campaigns[token].floor = newFloor;
        emit CampaignFloorUpdated(token, oldFloor, newFloor);
    }

    function updateCampaignCeiling(address token, uint256 newCeiling) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        uint256 oldCeiling = campaigns[token].ceiling;
        campaigns[token].ceiling = newCeiling;
        emit CampaignCeilingUpdated(token, oldCeiling, newCeiling);
    }

    function updateFundsRecipient(address token, address newRecipient) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(newRecipient != address(0), "Invalid recipient");
        address oldRecipient = campaigns[token].fundsRecipient;
        campaigns[token].fundsRecipient = newRecipient;
        emit FundsRecipientUpdated(token, oldRecipient, newRecipient);
    }

    // --- Market Management ---

    function enableMarket(address token) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        // Market can only be enabled - status is derived, so we just check it's not already open
        require(markets[token].status != MARKET_OPEN, "Market already open");
        markets[token] = MarketData({token: token, status: MARKET_OPEN, enabledAt: block.timestamp});
        emit MarketStatusUpdated(token, MARKET_OPEN);
    }

    function disableMarket(address token) external onlyAuthorized {
        // Disabling market requires timelock (owner only)
        if (msg.sender == owner()) {
            bytes32 opId = keccak256(abi.encode("disableMarket", token));
            TimelockOperation storage op = timelockQueue[opId];
            
            if (op.executeAfter == 0) {
                // Queue the operation
                op.executeAfter = block.timestamp + TIMELOCK_DELAY;
                emit OperationQueued(opId, op.executeAfter);
                return;
            } else {
                // Execute if timelock passed
                require(block.timestamp >= op.executeAfter, "Timelock not expired");
                require(!op.executed, "Already executed");
                op.executed = true;
                emit OperationExecuted(opId);
            }
        }
        
        markets[token].status = MARKET_CLOSED;
        emit MarketStatusUpdated(token, MARKET_CLOSED);
    }
    
    /**
     * @notice Cancel a queued timelock operation
     * @param operationId Operation ID to cancel
     */
    function cancelTimelockOperation(bytes32 operationId) external onlyOwner {
        TimelockOperation storage op = timelockQueue[operationId];
        require(op.executeAfter > 0, "Operation not queued");
        require(!op.executed, "Already executed");
        
        delete timelockQueue[operationId];
        emit OperationCancelled(operationId);
    }

    // --- Authorization ---

    function setAuthorizedContract(address contractAddress, bool authorized) external onlyOwner {
        authorizedContracts[contractAddress] = authorized;
        emit ContractAuthorized(contractAddress, authorized);
    }
    
    /**
     * @notice Set protocol safe address for emergency fund recovery
     * @dev This multisig can recover protocol-owned funds from VaultLedgers
     * @param _safe Protocol safe multisig address
     */
    function setProtocolSafe(address _safe) external onlyOwner {
        require(_safe != address(0), "Invalid safe");
        protocolSafe = _safe;
        emit ProtocolSafeSet(_safe);
    }
    
    /**
     * @notice Set keeper address for automated tasks
     * @dev This address can trigger keeper tasks like bad debt coverage
     * @param _keeper Keeper address
     */
    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "Invalid keeper");
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }
    
    // ===========================================
    // PROTOCOL ADDRESS SETTERS
    // ===========================================
    
    /**
     * @notice Set USDC stablecoin address
     * @param _usdc USDC contract address
     */
    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Invalid address");
        usdc = _usdc;
        emit ProtocolAddressSet("usdc", _usdc);
    }
    
    /**
     * @notice Set fee wallet address (Safe)
     * @param _feeWallet Fee wallet address
     */
    function setFeeWallet(address _feeWallet) external onlyOwner {
        require(_feeWallet != address(0), "Invalid address");
        feeWallet = _feeWallet;
        emit ProtocolAddressSet("feeWallet", _feeWallet);
    }
    
    /**
     * @notice Set Campaign contract address
     * @param _campaign Campaign contract address
     */
    function setCampaign(address _campaign) external onlyOwner {
        require(_campaign != address(0), "Invalid address");
        campaign = _campaign;
        emit ProtocolAddressSet("campaign", _campaign);
    }

    /**
     * @notice Set CampaignAdmin contract address
     * @param _campaignAdmin CampaignAdmin contract address
     */
    function setCampaignAdmin(address _campaignAdmin) external onlyOwner {
        require(_campaignAdmin != address(0), "Invalid address");
        campaignAdmin = _campaignAdmin;
        emit ProtocolAddressSet("campaignAdmin", _campaignAdmin);
    }

    /**
     * @notice Set MultiRoundCampaign contract address
     * @param _multiRoundCampaign MultiRoundCampaign contract address
     */
    function setMultiRoundCampaign(address _multiRoundCampaign) external onlyOwner {
        require(_multiRoundCampaign != address(0), "Invalid address");
        multiRoundCampaign = _multiRoundCampaign;
        emit ProtocolAddressSet("multiRoundCampaign", _multiRoundCampaign);
    }

    /**
     * @notice Set Market contract address
     * @param _market Market contract address
     */
    function setMarket(address _market) external onlyOwner {
        require(_market != address(0), "Invalid address");
        market = _market;
        emit ProtocolAddressSet("market", _market);
    }
    
    /**
     * @notice Set token implementation address for cloning
     * @param _tokenImplementation MinimumERC20 implementation address
     */
    function setTokenImplementation(address _tokenImplementation) external onlyOwner {
        require(_tokenImplementation != address(0), "Invalid address");
        tokenImplementation = _tokenImplementation;
        emit ProtocolAddressSet("tokenImplementation", _tokenImplementation);
    }
    
    /**
     * @notice Set HybridPriceOracle address
     * @param _hybridPriceOracle HybridPriceOracle contract address
     */
    function setHybridPriceOracle(address _hybridPriceOracle) external onlyOwner {
        require(_hybridPriceOracle != address(0), "Invalid address");
        hybridPriceOracle = _hybridPriceOracle;
        emit ProtocolAddressSet("hybridPriceOracle", _hybridPriceOracle);
    }
    
    /**
     * @notice Set RiskOracle address
     * @param _riskOracle RiskOracle contract address
     */
    function setRiskOracle(address _riskOracle) external onlyOwner {
        require(_riskOracle != address(0), "Invalid address");
        riskOracle = _riskOracle;
        emit ProtocolAddressSet("riskOracle", _riskOracle);
    }
    
    /**
     * @notice Set OptimisticPriceOracle address
     * @param _optimisticPriceOracle OptimisticPriceOracle contract address
     */
    function setOptimisticPriceOracle(address _optimisticPriceOracle) external onlyOwner {
        require(_optimisticPriceOracle != address(0), "Invalid address");
        optimisticPriceOracle = _optimisticPriceOracle;
        emit ProtocolAddressSet("optimisticPriceOracle", _optimisticPriceOracle);
    }
    
    /**
     * @notice Set JumpRateModel address
     * @param _rateModel JumpRateModel contract address
     */
    function setRateModel(address _rateModel) external onlyOwner {
        require(_rateModel != address(0), "Invalid address");
        rateModel = _rateModel;
        emit ProtocolAddressSet("rateModel", _rateModel);
    }
    
    /**
     * @notice Set LendingManager address
     * @param _lendingManager LendingManager contract address
     */
    function setLendingManager(address _lendingManager) external onlyOwner {
        require(_lendingManager != address(0), "Invalid address");
        lendingManager = _lendingManager;
        emit ProtocolAddressSet("lendingManager", _lendingManager);
    }
    
    /**
     * @notice Set MarketIntegration address
     * @param _marketIntegration MarketIntegration contract address
     */
    function setMarketIntegration(address _marketIntegration) external onlyOwner {
        require(_marketIntegration != address(0), "Invalid address");
        marketIntegration = _marketIntegration;
        emit ProtocolAddressSet("marketIntegration", _marketIntegration);
    }
    
    /**
     * @notice Set Contest address
     * @param _contest Contest contract address
     */
    function setContest(address _contest) external onlyOwner {
        require(_contest != address(0), "Invalid address");
        contest = _contest;
        emit ProtocolAddressSet("contest", _contest);
    }
    
    /**
     * @notice Set DividendDistributor address
     * @param _dividendDistributor DividendDistributor contract address
     */
    function setDividendDistributor(address _dividendDistributor) external onlyOwner {
        require(_dividendDistributor != address(0), "Invalid address");
        dividendDistributor = _dividendDistributor;
        emit ProtocolAddressSet("dividendDistributor", _dividendDistributor);
    }
    
    /**
     * @notice Set KeeperRegistry address
     * @param _keeperRegistry KeeperRegistry contract address
     */
    function setKeeperRegistry(address _keeperRegistry) external onlyOwner {
        require(_keeperRegistry != address(0), "Invalid address");
        keeperRegistry = _keeperRegistry;
        emit ProtocolAddressSet("keeperRegistry", _keeperRegistry);
    }
    
    /**
     * @notice Set FeeDistributor address (V3)
     * @param _feeDistributor FeeDistributor contract address
     */
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        require(_feeDistributor != address(0), "Invalid address");
        feeDistributor = _feeDistributor;
        emit ProtocolAddressSet("feeDistributor", _feeDistributor);
    }
    
    /**
     * @notice Set fee safe address (V3)
     * @param _feeSafe Fee safe address (receives 40% of fees)
     */
    function setFeeSafe(address _feeSafe) external onlyOwner {
        require(_feeSafe != address(0), "Invalid address");
        feeSafe = _feeSafe;
        emit ProtocolAddressSet("feeSafe", _feeSafe);
    }
    
    /**
     * @notice Set BurnRedemption address (V3)
     * @param _burnRedemption BurnRedemption contract address
     */
    function setBurnRedemption(address _burnRedemption) external onlyOwner {
        require(_burnRedemption != address(0), "Invalid address");
        burnRedemption = _burnRedemption;
        emit ProtocolAddressSet("burnRedemption", _burnRedemption);
    }
    
    /**
     * @notice Set SurveySnapshot address (V3)
     * @param _surveySnapshot SurveySnapshot contract address
     */
    function setSurveySnapshot(address _surveySnapshot) external onlyOwner {
        require(_surveySnapshot != address(0), "Invalid address");
        surveySnapshot = _surveySnapshot;
        emit ProtocolAddressSet("surveySnapshot", _surveySnapshot);
    }

    function setCampaignFeeManager(address _campaignFeeManager) external onlyOwner {
        require(_campaignFeeManager != address(0), "Invalid address");
        campaignFeeManager = _campaignFeeManager;
        emit ProtocolAddressSet("campaignFeeManager", _campaignFeeManager);
    }
    
    /**
     * @notice Set InterestLogic address (V3)
     * @param _interestLogic InterestLogic contract address
     */
    function setInterestLogic(address _interestLogic) external onlyOwner {
        require(_interestLogic != address(0), "Invalid address");
        interestLogic = _interestLogic;
        emit ProtocolAddressSet("interestLogic", _interestLogic);
    }
    
    /**
     * @notice Set LendingLogic address (V3)
     * @param _lendingLogic LendingLogic contract address
     */
    function setLendingLogic(address _lendingLogic) external onlyOwner {
        require(_lendingLogic != address(0), "Invalid address");
        lendingLogic = _lendingLogic;
        emit ProtocolAddressSet("lendingLogic", _lendingLogic);
    }
    
    /**
     * @notice Set StabilityLogic address (V3)
     * @param _stabilityLogic StabilityLogic contract address
     */
    function setStabilityLogic(address _stabilityLogic) external onlyOwner {
        require(_stabilityLogic != address(0), "Invalid address");
        stabilityLogic = _stabilityLogic;
        emit ProtocolAddressSet("stabilityLogic", _stabilityLogic);
    }
    
    /**
     * @notice Set MultiRoundLogic address
     * @param _multiRoundLogic MultiRoundLogic contract address
     */
    function setMultiRoundLogic(address _multiRoundLogic) external onlyOwner {
        require(_multiRoundLogic != address(0), "Invalid address");
        multiRoundLogic = _multiRoundLogic;
        emit ProtocolAddressSet("multiRoundLogic", _multiRoundLogic);
    }
    
    /**
     * @notice Set all logic contract addresses at once (V3)
     * @dev Convenience function for deployment
     */
    function setLogicAddresses(
        address _interestLogic,
        address _lendingLogic,
        address _stabilityLogic,
        address _multiRoundLogic
    ) external onlyOwner {
        if (_interestLogic != address(0)) {
            interestLogic = _interestLogic;
            emit ProtocolAddressSet("interestLogic", _interestLogic);
        }
        if (_lendingLogic != address(0)) {
            lendingLogic = _lendingLogic;
            emit ProtocolAddressSet("lendingLogic", _lendingLogic);
        }
        if (_stabilityLogic != address(0)) {
            stabilityLogic = _stabilityLogic;
            emit ProtocolAddressSet("stabilityLogic", _stabilityLogic);
        }
        if (_multiRoundLogic != address(0)) {
            multiRoundLogic = _multiRoundLogic;
            emit ProtocolAddressSet("multiRoundLogic", _multiRoundLogic);
        }
    }
    
    /**
     * @notice Batch set multiple protocol addresses at once
     * @dev Useful for initial deployment configuration
     */
    function setProtocolAddresses(
        address _usdc,
        address _feeWallet,
        address _campaign,
        address _market,
        address _lendingManager,
        address _contest
    ) external onlyOwner {
        if (_usdc != address(0)) {
            usdc = _usdc;
            emit ProtocolAddressSet("usdc", _usdc);
        }
        if (_feeWallet != address(0)) {
            feeWallet = _feeWallet;
            emit ProtocolAddressSet("feeWallet", _feeWallet);
        }
        if (_campaign != address(0)) {
            campaign = _campaign;
            emit ProtocolAddressSet("campaign", _campaign);
        }
        if (_market != address(0)) {
            market = _market;
            emit ProtocolAddressSet("market", _market);
        }
        if (_lendingManager != address(0)) {
            lendingManager = _lendingManager;
            emit ProtocolAddressSet("lendingManager", _lendingManager);
        }
        if (_contest != address(0)) {
            contest = _contest;
            emit ProtocolAddressSet("contest", _contest);
        }
    }
    
    /**
     * @notice Set oracle addresses
     * @dev Batch setter for oracle-related addresses
     */
    function setOracleAddresses(
        address _hybridPriceOracle,
        address _riskOracle,
        address _optimisticPriceOracle,
        address _rateModel
    ) external onlyOwner {
        if (_hybridPriceOracle != address(0)) {
            hybridPriceOracle = _hybridPriceOracle;
            emit ProtocolAddressSet("hybridPriceOracle", _hybridPriceOracle);
        }
        if (_riskOracle != address(0)) {
            riskOracle = _riskOracle;
            emit ProtocolAddressSet("riskOracle", _riskOracle);
        }
        if (_optimisticPriceOracle != address(0)) {
            optimisticPriceOracle = _optimisticPriceOracle;
            emit ProtocolAddressSet("optimisticPriceOracle", _optimisticPriceOracle);
        }
        if (_rateModel != address(0)) {
            rateModel = _rateModel;
            emit ProtocolAddressSet("rateModel", _rateModel);
        }
    }
    
    /**
     * @notice Set system contract addresses (V3)
     * @dev Batch setter for system contracts
     */
    function setSystemAddresses(
        address _feeDistributor,
        address _feeSafe,
        address _contest,
        address _keeperRegistry,
        address _burnRedemption,
        address _surveySnapshot
    ) external onlyOwner {
        if (_feeDistributor != address(0)) {
            feeDistributor = _feeDistributor;
            emit ProtocolAddressSet("feeDistributor", _feeDistributor);
        }
        if (_feeSafe != address(0)) {
            feeSafe = _feeSafe;
            emit ProtocolAddressSet("feeSafe", _feeSafe);
        }
        if (_contest != address(0)) {
            contest = _contest;
            emit ProtocolAddressSet("contest", _contest);
        }
        if (_keeperRegistry != address(0)) {
            keeperRegistry = _keeperRegistry;
            emit ProtocolAddressSet("keeperRegistry", _keeperRegistry);
        }
        if (_burnRedemption != address(0)) {
            burnRedemption = _burnRedemption;
            emit ProtocolAddressSet("burnRedemption", _burnRedemption);
        }
        if (_surveySnapshot != address(0)) {
            surveySnapshot = _surveySnapshot;
            emit ProtocolAddressSet("surveySnapshot", _surveySnapshot);
        }
    }
    
    /**
     * @notice Set campaign contract addresses
     * @dev Batch setter for campaign-related contracts
     */
    function setCampaignAddresses(
        address _campaign,
        address _campaignAdmin,
        address _multiRoundCampaign,
        address _tokenImplementation,
        address _dividendDistributor
    ) external onlyOwner {
        if (_campaign != address(0)) {
            campaign = _campaign;
            emit ProtocolAddressSet("campaign", _campaign);
        }
        if (_campaignAdmin != address(0)) {
            campaignAdmin = _campaignAdmin;
            emit ProtocolAddressSet("campaignAdmin", _campaignAdmin);
        }
        if (_multiRoundCampaign != address(0)) {
            multiRoundCampaign = _multiRoundCampaign;
            emit ProtocolAddressSet("multiRoundCampaign", _multiRoundCampaign);
        }
        if (_tokenImplementation != address(0)) {
            tokenImplementation = _tokenImplementation;
            emit ProtocolAddressSet("tokenImplementation", _tokenImplementation);
        }
        if (_dividendDistributor != address(0)) {
            dividendDistributor = _dividendDistributor;
            emit ProtocolAddressSet("dividendDistributor", _dividendDistributor);
        }
    }

    // --- Lending Infrastructure Management ---

    /**
     * @notice Register per-token lending infrastructure
     * @dev Called by LendingManager when deploying infrastructure for a graduated token
     * @param token Campaign token address
     * @param _stableVault StableVaultV2 clone address
     * @param _stabilityPool StabilityPool clone address
     * @param _safetyModule SafetyModule clone address
     * @param _vaultLedger VaultLedger clone address
     * @param _unifiedVault UnifiedVault clone address
     */
    function registerLendingInfrastructure(
        address token,
        address _stableVault,
        address _stabilityPool,
        address _safetyModule,
        address _vaultLedger,
        address _unifiedVault
    ) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(getCampaignStatus(token) == STATUS_SUCCESS, "Campaign not successful");
        require(!tokenLending[token].initialized, "Infrastructure already registered");
        require(_stableVault != address(0), "Invalid stableVault");
        require(_stabilityPool != address(0), "Invalid stabilityPool");
        require(_safetyModule != address(0), "Invalid safetyModule");
        require(_vaultLedger != address(0), "Invalid vaultLedger");
        require(_unifiedVault != address(0), "Invalid unifiedVault");

        tokenLending[token] = LendingInfrastructure({
            stableVault: _stableVault,
            stabilityPool: _stabilityPool,
            safetyModule: _safetyModule,
            vaultLedger: _vaultLedger,
            unifiedVault: _unifiedVault,
            initialized: true
        });

        emit LendingInfrastructureRegistered(
            token,
            _stableVault,
            _stabilityPool,
            _safetyModule,
            _vaultLedger,
            _unifiedVault
        );
    }

    /**
     * @notice Get lending infrastructure for a token
     * @param token Campaign token address
     * @return infra LendingInfrastructure struct
     */
    function getLendingInfrastructure(address token) external view returns (LendingInfrastructure memory infra) {
        return tokenLending[token];
    }

    /**
     * @notice Check if token has lending infrastructure
     * @param token Campaign token address
     * @return hasInfra Whether infrastructure is initialized
     */
    function hasLendingInfrastructure(address token) external view returns (bool hasInfra) {
        return tokenLending[token].initialized;
    }
    
    /**
     * @notice Register UnifiedVault for a token (V3 simplified registration)
     * @dev Called by LendingManager when deploying UnifiedVault
     * @param token Campaign token address
     * @param _unifiedVault UnifiedVault address
     */
    function registerUnifiedVault(address token, address _unifiedVault) external onlyAuthorized {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(getCampaignStatus(token) == STATUS_SUCCESS, "Campaign not successful");
        require(!tokenLending[token].initialized, "Infrastructure already registered");
        require(_unifiedVault != address(0), "Invalid unifiedVault");

        // V3: Only set unifiedVault, leave V2 fields as zero addresses
        tokenLending[token] = LendingInfrastructure({
            stableVault: address(0),
            stabilityPool: address(0),
            safetyModule: address(0),
            vaultLedger: address(0),
            unifiedVault: _unifiedVault,
            initialized: true
        });

        emit UnifiedVaultRegistered(token, _unifiedVault);
    }
    
    /**
     * @notice Get UnifiedVault address for a token (V3 convenience getter)
     * @param token Campaign token address
     * @return vault UnifiedVault address (or zero if not initialized)
     */
    function getUnifiedVault(address token) external view returns (address vault) {
        return tokenLending[token].unifiedVault;
    }

    // --- View Functions ---
    
    /**
     * @notice Get derived campaign status from conditions
     * @dev Status is NOT stored - it's calculated from:
     *      - cancelled flag (only stored state)
     *      - market.status (SUCCESS if market is open)
     *      - block.timestamp vs startTime/endTime
     *      - totalRaised vs floor
     *      - grace period expiry
     * @param token Campaign token address
     * @return status Derived status (PENDING, ACTIVE, SUCCESS, FAILED, CANCELLED)
     */
    function getCampaignStatus(address token) public view returns (uint8 status) {
        CampaignData memory c = campaigns[token];
        if (c.token == address(0)) return 0; // Not found
        
        // 1. Cancelled - explicit creator action (only stored flag)
        if (c.cancelled) return STATUS_CANCELLED;
        
        // 2. Success - market is open (finalized successfully)
        if (markets[token].status == MARKET_OPEN) return STATUS_SUCCESS;
        
        // 3. Multi-round: simplified campaign-level status
        //    Individual round status is managed by MultiRoundCampaign contract.
        //    Campaign stays ACTIVE until explicitly cancelled or finalized (market opened).
        if (c.isMultiRound) {
            if (block.timestamp < c.startTime) return STATUS_PENDING;
            return STATUS_ACTIVE;
        }
        
        // --- Single-round logic below ---
        
        // 3. Pending - before start time
        if (block.timestamp < c.startTime) return STATUS_PENDING;
        
        // 4. Active - during campaign period
        if (block.timestamp <= c.endTime) return STATUS_ACTIVE;
        
        // 5. After deadline - check if floor met
        if (c.totalRaised >= c.floor) {
            // Floor met but not finalized yet - still considered active
            // (waiting for finalizeCampaign to be called)
            return STATUS_ACTIVE;
        }
        
        // 6. After deadline + grace period, floor not met = FAILED
        if (block.timestamp > c.endTime + GRACE_PERIOD) {
            return STATUS_FAILED;
        }
        
        // 7. In grace period, floor not met - still ACTIVE (can be extended)
        return STATUS_ACTIVE;
    }

    function getCampaign(address token) external view returns (CampaignData memory) {
        return campaigns[token];
    }

    function getMarket(address token) external view returns (MarketData memory) {
        return markets[token];
    }

    function isMarketOpen(address token) external view returns (bool) {
        return markets[token].status == MARKET_OPEN;
    }

    /**
     * @notice Check if token has graduated (market is open)
     * @dev Required by Contest.sol for volume tracking
     * @param token Token address
     * @return graduated Whether token market is open
     */
    function isTokenGraduated(address token) external view returns (bool graduated) {
        return markets[token].status == MARKET_OPEN;
    }

    /**
     * @notice Get timestamp when token graduated (market opened)
     * @dev Required by Contest.sol for epoch calculations
     * @param token Token address
     * @return graduatedTime Timestamp when market was enabled (0 if not graduated)
     */
    function getGraduatedTime(address token) external view returns (uint256 graduatedTime) {
        if (markets[token].status == MARKET_OPEN) {
            return markets[token].enabledAt;
        }
        return 0;
    }

    function getCreatorCampaigns(address creator) external view returns (address[] memory) {
        return creatorCampaigns[creator];
    }
    
    /**
     * @notice Get all creators for a campaign
     * @param token Campaign token address
     * @return creators Array of creator addresses
     */
    function getCampaignCreators(address token) external view returns (address[] memory) {
        return campaignCreators[token];
    }
    
    /**
     * @notice Get number of creators for a campaign
     * @param token Campaign token address
     * @return count Number of creators
     */
    function getCampaignCreatorCount(address token) external view returns (uint256) {
        return campaignCreators[token].length;
    }

    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    function getCampaignProgress(address token) external view returns (uint256 raised, uint256 target, uint256 percentage) {
        CampaignData memory campaignData = campaigns[token];
        raised = campaignData.totalRaised;
        // Target is ceiling if set, otherwise floor
        target = campaignData.ceiling > 0 ? campaignData.ceiling : campaignData.floor;
        percentage = target > 0 ? (raised * 100) / target : 0;
    }
    
    /**
     * @notice Get campaign floor and ceiling info
     * @param token Campaign token address
     * @return floor Minimum raise amount
     * @return ceiling Maximum raise amount (0 if unlimited)
     * @return overageType Type of overage (NONE, UNLIMITED, CEILING)
     */
    function getCampaignLimits(address token) external view returns (
        uint256 floor,
        uint256 ceiling,
        uint8 overageType
    ) {
        CampaignData memory campaignData = campaigns[token];
        floor = campaignData.floor;
        ceiling = campaignData.ceiling;
        overageType = campaignData.overageType;
    }
    
    // ===========================================
    // CENTRALIZED ACCESS CONTROL
    // ===========================================
    
    /**
     * @notice Authorize/deauthorize dividend distributor for a specific token
     * @dev Only token creator or owner can authorize distributors
     * @param token Campaign token address
     * @param distributor Address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function authorizeDividendDistributor(address token, address distributor, bool authorized) external {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(distributor != address(0), "Invalid distributor");
        require(
            isCampaignCreator[token][msg.sender] || msg.sender == owner(),
            "Only creator or owner"
        );
        
        isDividendDistributor[token][distributor] = authorized;
        emit DividendDistributorSet(token, distributor, authorized);
    }
    
    /**
     * @notice Set surveyor authorization for a token
     * @dev Only token creator or owner can authorize surveyors
     * @param token Campaign token address
     * @param surveyor Address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function setSurveyor(address token, address surveyor, bool authorized) external {
        require(campaigns[token].token != address(0), "Campaign does not exist");
        require(surveyor != address(0), "Invalid surveyor");
        require(
            isCampaignCreator[token][msg.sender] || msg.sender == owner(),
            "Only creator or owner"
        );
        
        isSurveyor[token][surveyor] = authorized;
        emit SurveyorSet(token, surveyor, authorized);
    }
    
    // ===========================================
    // TIER LOGIC ADDRESS SETTER
    // ===========================================
    
    /**
     * @notice Set TierLogic contract address
     * @dev Only owner can set. TierLogic handles all tier calculations.
     * @param _tierLogic Address of TierLogic contract
     */
    function setTierLogic(address _tierLogic) external onlyOwner {
        require(_tierLogic != address(0), "Invalid tierLogic");
        tierLogic = _tierLogic;
    }
    
    /**
     * @notice Set VolumeTracker contract address
     * @dev Only owner can set. VolumeTracker stores daily volume data.
     * @param _volumeTracker Address of VolumeTracker contract
     */
    function setVolumeTracker(address _volumeTracker) external onlyOwner {
        require(_volumeTracker != address(0), "Invalid volumeTracker");
        volumeTracker = _volumeTracker;
    }
    
    /**
     * @notice Check if address is authorized dividend distributor for a token
     * @dev Creators are automatically authorized
     * @param token Campaign token address
     * @param account Address to check
     * @return authorized Whether the address is authorized
     */
    function isAuthorizedDividendDistributor(address token, address account) external view returns (bool) {
        return isCampaignCreator[token][account] || isDividendDistributor[token][account];
    }
    
    /**
     * @notice Check if address is authorized surveyor for a token
     * @dev Creators are automatically authorized
     * @param token Campaign token address
     * @param account Address to check
     * @return authorized Whether the address is authorized
     */
    function isAuthorizedSurveyor(address token, address account) external view returns (bool) {
        return isCampaignCreator[token][account] || isSurveyor[token][account];
    }
}
