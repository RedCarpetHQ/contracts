// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Registry.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./interfaces/IRiskOracleViews.sol";

/**
 * @title RiskOracle
 * @notice Global risk assessment oracle for all tokens
 * @dev Assesses risk tier (GREEN/YELLOW/RED) based on multiple factors:
 *      - Price staleness (from HybridPriceOracle)
 *      - Vault utilization
 *      - Price disputes (from OptimisticPriceOracle)
 *      - Wash trading detection
 *      - Market health
 * 
 * Risk tiers affect:
 *      - Collateral factors and liquidation thresholds
 *      - Interest distribution splits
 *      - Supply/borrow caps
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract RiskOracle is Ownable, ReentrancyGuard {
    
    // ========== CONSTANTS ==========
    
    uint8 public constant TIER_GREEN = 0;
    uint8 public constant TIER_YELLOW = 1;
    uint8 public constant TIER_RED = 2;
    
    uint256 public constant ONE = 1e18;
    // Configurable: test default 300s (5 min) for fast iteration; production: 3600 (1 hour)
    uint40 public EPOCH_SECS = 300; // production: 3600

    // Staleness thresholds (RWA-optimized for lower liquidity)
    // Configurable: test defaults short for testing; production: 14 days / 3 days
    uint256 public STALE_RED_THRESHOLD = 1 hours; // production: 14 days
    uint256 public STALE_YELLOW_THRESHOLD = 30 minutes; // production: 3 days
    
    // Utilization thresholds with hysteresis (RWA-optimized)
    uint256 public constant UTIL_YELLOW_THRESHOLD_UP = 90e16;   // 90% - escalate GREEN→YELLOW (was 85%)
    uint256 public constant UTIL_RED_THRESHOLD_UP = 97e16;      // 97% - escalate YELLOW→RED (was 95%)
    
    // De-escalation thresholds (lower to prevent oscillation)
    uint256 public constant UTIL_YELLOW_THRESHOLD_DOWN = 85e16; // 85% - de-escalate YELLOW→GREEN (was 80%)
    uint256 public constant UTIL_RED_THRESHOLD_DOWN = 92e16;    // 92% - de-escalate RED→YELLOW (was 90%)
    
    // Bootstrap mode thresholds (relaxed for new projects)
    uint256 public constant UTIL_BOOTSTRAP_YELLOW = 95e16;      // 95% - bootstrap GREEN→YELLOW
    uint256 public constant UTIL_BOOTSTRAP_RED = 99e16;         // 99% - bootstrap YELLOW→YELLOW (never RED)
    
    // Dynamic cap multipliers (scaled to 1e18 for precision)
    uint256 public constant MULTIPLIER_GREEN = 5e18;   // 5.0x market cap
    uint256 public constant MULTIPLIER_YELLOW = 2e18;  // 2.0x market cap
    uint256 public constant MULTIPLIER_RED = 5e17;     // 0.5x market cap
    
    // Bootstrap mode parameters
    // Configurable: test default 2 hours for fast iteration; production: 30 days
    uint256 public BOOTSTRAP_DURATION = 2 hours; // production: 30 days
    uint256 public constant BOOTSTRAP_MIN_VOLUME = 10_000e6; // 10k USDC cap (now dynamic)
    uint256 public constant BOOTSTRAP_VOLUME_BPS = 10000; // 100% of market cap to exit bootstrap
    
    // Wash trading thresholds
    uint16 public constant WASH_THRESHOLD_BPS = 5000; // 50%
    uint8 public constant MIN_UNIQUE_PARTICIPANTS = 5;
    
    // ========== STATE VARIABLES ==========
    
    Registry public registry;
    
    // Circuit breaker state
    mapping(address => bool) public circuitBreakerTriggered;
    mapping(address => uint256) public circuitBreakerTimestamp;
    mapping(address => string) public circuitBreakerReason;
    
    // Circuit breaker thresholds (configurable)
    uint256 public circuitBreakerBadDebtThreshold = 10_000e6; // 10k USDC
    uint256 public circuitBreakerUtilThreshold = 99e16; // 99%
    uint256 public circuitBreakerStaleThreshold = 1 hours; // production 14 days;
    
    // Manual tier override
    mapping(address => uint8) public manualTierOverride;
    mapping(address => bool) public hasManualOverride;
    
    // Per-asset base caps (0 = use default)
    // NOTE: These now serve as ABSOLUTE CEILINGS for dynamic caps
    mapping(address => uint256) public assetBaseCaps;
    uint256 public defaultBaseCap = 10_000_000e6; // 10M USDC absolute ceiling
    
    // Wash trading detection (minimal storage)
    struct WashStats {
        uint32 trades;
        uint32 samePairTrades;
        uint256 bitmapMakers;
        uint256 bitmapTakers;
        address lastMaker;
        address lastTaker;
    }
    mapping(address => mapping(uint40 => WashStats)) internal washStats;
    mapping(address => uint40) public lastEpochId;
    
    // EMA smoothing for tier changes
    mapping(address => uint8) public previousTier;
    mapping(address => uint256) public lastTierUpdate;
    uint256 public tierSmoothingPeriod = 2 minutes; // production 1 hours;
    
    // Hysteresis state for utilization tier (prevents oscillation)
    mapping(address => uint8) public currentUtilTier;
    
    // Risk parameters per tier
    struct TierParams {
        uint256 collateralFactor;    // Max borrow against collateral
        uint256 liquidationThreshold; // When liquidation is allowed
        uint256 supplyCap;           // Max deposits
        uint256 borrowCap;           // Max borrows
    }
    
    mapping(uint8 => TierParams) public tierParams;
    
    // ========== EVENTS ==========
    
    event RiskTierUpdated(address indexed token, uint8 oldTier, uint8 newTier);
    event CircuitBreakerTriggered(address indexed token, string reason, uint256 timestamp);
    event CircuitBreakerReset(address indexed token, address indexed admin);
    event ManualOverrideSet(address indexed token, uint8 tier);
    event ManualOverrideCleared(address indexed token);
    event WashTradingDetected(address indexed token, uint40 epochId, uint32 samePairRatio);
    event ThresholdsUpdated(uint256 badDebtThreshold, uint256 utilThreshold, uint256 staleThreshold);
    event TierParamsUpdated(uint8 tier, uint256 cf, uint256 lt, uint256 supplyCap, uint256 borrowCap);
    event TradeRecorded(address indexed token, address maker, address taker, uint256 price);
    event UtilTierChanged(address indexed token, uint8 oldTier, uint8 newTier, uint256 utilization);
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _owner, address _registry) {
        require(_owner != address(0), "Invalid owner");
        require(_registry != address(0), "Invalid registry");
        
        _transferOwnership(_owner);
        registry = Registry(_registry);
        
        // Initialize default tier parameters
        // GREEN: Most permissive
        tierParams[TIER_GREEN] = TierParams({
            collateralFactor: 50e16,    // 50%
            liquidationThreshold: 60e16, // 60%
            supplyCap: 10_000_000e6,    // 10M USDC
            borrowCap: 5_000_000e6      // 5M USDC
        });
        
        // YELLOW: Moderate restrictions
        tierParams[TIER_YELLOW] = TierParams({
            collateralFactor: 40e16,    // 40%
            liquidationThreshold: 50e16, // 50%
            supplyCap: 5_000_000e6,     // 5M USDC
            borrowCap: 2_000_000e6      // 2M USDC
        });
        
        // RED: Most restrictive
        tierParams[TIER_RED] = TierParams({
            collateralFactor: 30e16,    // 30%
            liquidationThreshold: 40e16, // 40%
            supplyCap: 1_000_000e6,     // 1M USDC
            borrowCap: 500_000e6        // 500k USDC
        });
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    function setManualOverride(address token, uint8 tier) external onlyOwner {
        require(tier <= TIER_RED, "Invalid tier");
        manualTierOverride[token] = tier;
        hasManualOverride[token] = true;
        emit ManualOverrideSet(token, tier);
    }
    
    function clearManualOverride(address token) external onlyOwner {
        hasManualOverride[token] = false;
        emit ManualOverrideCleared(token);
    }
    
    function setCircuitBreakerThresholds(
        uint256 _badDebtThreshold,
        uint256 _utilThreshold,
        uint256 _staleThreshold
    ) external onlyOwner {
        circuitBreakerBadDebtThreshold = _badDebtThreshold;
        circuitBreakerUtilThreshold = _utilThreshold;
        circuitBreakerStaleThreshold = _staleThreshold;
        emit ThresholdsUpdated(_badDebtThreshold, _utilThreshold, _staleThreshold);
    }

    /**
     * @notice Set timing parameters (production configuration)
     * @dev Test defaults are short for fast iteration; multisig sets production values post-deployment
     * @param _epochSecs Epoch length in seconds (test: 300, prod: 3600)
     * @param _staleRedThreshold Staleness for RED tier (test: 1 hour, prod: 14 days)
     * @param _staleYellowThreshold Staleness for YELLOW tier (test: 30 min, prod: 3 days)
     * @param _bootstrapDuration Bootstrap period (test: 2 hours, prod: 30 days)
     */
    function setTimingParameters(
        uint40 _epochSecs,
        uint256 _staleRedThreshold,
        uint256 _staleYellowThreshold,
        uint256 _bootstrapDuration
    ) external onlyOwner {
        require(_epochSecs >= 60 && _epochSecs <= 1 days, "Invalid epoch secs");
        require(_staleRedThreshold > _staleYellowThreshold, "RED threshold must > YELLOW");
        require(_staleYellowThreshold >= 5 minutes, "YELLOW threshold too low");
        require(_bootstrapDuration >= 1 hours && _bootstrapDuration <= 365 days, "Invalid bootstrap");

        EPOCH_SECS = _epochSecs;
        STALE_RED_THRESHOLD = _staleRedThreshold;
        STALE_YELLOW_THRESHOLD = _staleYellowThreshold;
        BOOTSTRAP_DURATION = _bootstrapDuration;

        emit TimingParametersUpdated(_epochSecs, _staleRedThreshold, _staleYellowThreshold, _bootstrapDuration);
    }

    event TimingParametersUpdated(uint40 epochSecs, uint256 staleRedThreshold, uint256 staleYellowThreshold, uint256 bootstrapDuration);
    
    function setTierParams(
        uint8 tier,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 supplyCap,
        uint256 borrowCap
    ) external onlyOwner {
        require(tier <= TIER_RED, "Invalid tier");
        require(liquidationThreshold > collateralFactor, "LT must > CF");
        
        tierParams[tier] = TierParams({
            collateralFactor: collateralFactor,
            liquidationThreshold: liquidationThreshold,
            supplyCap: supplyCap,
            borrowCap: borrowCap
        });
        
        emit TierParamsUpdated(tier, collateralFactor, liquidationThreshold, supplyCap, borrowCap);
    }
    
    function setDefaultBaseCap(uint256 _cap) external onlyOwner {
        defaultBaseCap = _cap;
    }
    
    function setAssetBaseCap(address token, uint256 _cap) external onlyOwner {
        assetBaseCaps[token] = _cap;
    }
    
    function setTierSmoothingPeriod(uint256 _period) external onlyOwner {
        tierSmoothingPeriod = _period;
    }
    
    // ========== CIRCUIT BREAKER ==========
    
    function triggerCircuitBreaker(address token, string calldata reason) external {
        // Only owner or authorized contracts can trigger
        require(
            msg.sender == owner() || registry.authorizedContracts(msg.sender),
            "Not authorized"
        );
        
        circuitBreakerTriggered[token] = true;
        circuitBreakerTimestamp[token] = block.timestamp;
        circuitBreakerReason[token] = reason;
        
        emit CircuitBreakerTriggered(token, reason, block.timestamp);
    }
    
    function resetCircuitBreaker(address token) external onlyOwner {
        circuitBreakerTriggered[token] = false;
        circuitBreakerTimestamp[token] = 0;
        circuitBreakerReason[token] = "";
        
        emit CircuitBreakerReset(token, msg.sender);
    }
    
    /**
     * @notice Check and auto-trigger circuit breaker if conditions met
     */
    function checkCircuitBreaker(address token) external {
        if (circuitBreakerTriggered[token]) return;
        
        // Check bad debt
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault != address(0)) {
            try IUnifiedVaultView(infra.unifiedVault).getBadDebt() returns (uint256 badDebt) {
                if (badDebt >= circuitBreakerBadDebtThreshold) {
                    _triggerCircuitBreaker(token, "Bad debt threshold exceeded");
                    return;
                }
            } catch {}
            
            try IUnifiedVaultView(infra.unifiedVault).getUtilization() returns (uint256 util) {
                if (util >= circuitBreakerUtilThreshold) {
                    _triggerCircuitBreaker(token, "Utilization threshold exceeded");
                    return;
                }
            } catch {}
        }
        
        // Check price staleness
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle != address(0)) {
            try IPriceOracleView(priceOracle).getPriceStaleness(token) returns (uint256 staleness) {
                if (staleness >= circuitBreakerStaleThreshold) {
                    _triggerCircuitBreaker(token, "Price staleness threshold exceeded");
                    return;
                }
            } catch {}
        }
    }
    
    function _triggerCircuitBreaker(address token, string memory reason) internal {
        circuitBreakerTriggered[token] = true;
        circuitBreakerTimestamp[token] = block.timestamp;
        circuitBreakerReason[token] = reason;
        emit CircuitBreakerTriggered(token, reason, block.timestamp);
    }
    
    // ========== RISK TIER ASSESSMENT ==========
    
    /**
     * @notice Get current risk tier for a token (view function)
     * @param token Campaign token address
     * @return tier Risk tier (0=GREEN, 1=YELLOW, 2=RED)
     */
    function getRiskTier(address token) external view returns (uint8) {
        return _calculateRiskTier(token);
    }
    
    /**
     * @notice Update and get risk tier with hysteresis state persistence
     * @dev Called by UnifiedVault during interest accrual to update utilization tier state
     *      This is gas-efficient: only writes state when tier actually changes
     * @param token Campaign token address
     * @return tier Risk tier (0=GREEN, 1=YELLOW, 2=RED)
     */
    function updateRiskTier(address token) external returns (uint8) {
        // Only authorized contracts can update (UnifiedVault, Market, etc.)
        require(
            registry.authorizedContracts(msg.sender) || msg.sender == owner(),
            "Not authorized"
        );
        
        // Update utilization tier with hysteresis
        _updateUtilTier(token);
        
        return _calculateRiskTier(token);
    }
    
    /**
     * @notice Internal calculation of risk tier (pure logic, no state changes)
     * @dev Bootstrap mode: New projects get relaxed tier assessment for 30 days
     */
    function _calculateRiskTier(address token) internal view returns (uint8) {
        // Circuit breaker = RED (always applies, even in bootstrap)
        if (circuitBreakerTriggered[token]) return TIER_RED;
        
        // Manual override takes precedence
        if (hasManualOverride[token]) {
            return manualTierOverride[token];
        }
        
        // Bootstrap mode: Apply relaxed rules for new projects
        if (isBootstrapping(token)) {
            uint8 bootstrapPriceTier = _assessPriceHealth(token);
            uint8 bootstrapVaultTier = _assessVaultHealthBootstrap(token); // Use bootstrap-specific assessment
            uint8 bootstrapDisputeTier = _assessDisputeStatus(token);
            // Skip wash trading check during bootstrap (not enough data)
            
            uint8 bootstrapTier = _max(_max(bootstrapPriceTier, bootstrapVaultTier), bootstrapDisputeTier);
            
            // Cap at YELLOW during bootstrap (never RED unless circuit breaker)
            return bootstrapTier > TIER_YELLOW ? TIER_YELLOW : bootstrapTier;
        }
        
        // Normal mode: Calculate tier from multiple factors
        uint8 priceTier = _assessPriceHealth(token);
        uint8 vaultTier = _assessVaultHealth(token);
        uint8 disputeTier = _assessDisputeStatus(token);
        uint8 washTier = _assessWashTrading(token);
        
        // Return worst tier (highest number)
        uint8 calculatedTier = _max(_max(priceTier, vaultTier), _max(disputeTier, washTier));
        
        // Apply EMA smoothing to prevent rapid tier changes
        return _applySmoothing(token, calculatedTier);
    }
    
    /**
     * @notice Update utilization tier state with hysteresis
     * @dev Only writes to storage if tier actually changes (gas optimization)
     */
    function _updateUtilTier(address token) internal {
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) return;
        
        try IUnifiedVaultView(infra.unifiedVault).getUtilization() returns (uint256 utilization) {
            uint8 prevTier = currentUtilTier[token];
            uint8 newTier;
            
            // Apply hysteresis based on previous tier
            if (prevTier == TIER_GREEN) {
                if (utilization >= UTIL_RED_THRESHOLD_UP) {
                    newTier = TIER_RED;
                } else if (utilization >= UTIL_YELLOW_THRESHOLD_UP) {
                    newTier = TIER_YELLOW;
                } else {
                    newTier = TIER_GREEN;
                }
            } else if (prevTier == TIER_YELLOW) {
                if (utilization >= UTIL_RED_THRESHOLD_UP) {
                    newTier = TIER_RED;
                } else if (utilization < UTIL_YELLOW_THRESHOLD_DOWN) {
                    newTier = TIER_GREEN;
                } else {
                    newTier = TIER_YELLOW;
                }
            } else {
                if (utilization < UTIL_YELLOW_THRESHOLD_DOWN) {
                    newTier = TIER_GREEN;
                } else if (utilization < UTIL_RED_THRESHOLD_DOWN) {
                    newTier = TIER_YELLOW;
                } else {
                    newTier = TIER_RED;
                }
            }
            
            // Only write to storage if tier changed (gas optimization)
            if (newTier != prevTier) {
                currentUtilTier[token] = newTier;
                emit UtilTierChanged(token, prevTier, newTier, utilization);
            }
        } catch {
            // Keep previous tier on error
        }
    }
    
    function _assessPriceHealth(address token) internal view returns (uint8) {
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle == address(0)) return TIER_GREEN;
        
        try IPriceOracleView(priceOracle).getPriceStaleness(token) returns (uint256 staleness) {
            if (staleness >= STALE_RED_THRESHOLD) return TIER_RED;
            if (staleness >= STALE_YELLOW_THRESHOLD) return TIER_YELLOW;
            return TIER_GREEN;
        } catch {
            return TIER_YELLOW; // Conservative if oracle fails
        }
    }
    
    /**
     * @notice Assess vault health with hysteresis to prevent tier oscillation
     * @dev Uses different thresholds for escalation vs de-escalation
     *      - GREEN→YELLOW at 85%, YELLOW→GREEN at 80% (5% dead zone)
     *      - YELLOW→RED at 95%, RED→YELLOW at 90% (5% dead zone)
     */
    function _assessVaultHealth(address token) internal view returns (uint8) {
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) return TIER_GREEN;
        
        try IUnifiedVaultView(infra.unifiedVault).getUtilization() returns (uint256 utilization) {
            uint8 prevTier = currentUtilTier[token];
            
            // Apply hysteresis based on previous tier
            if (prevTier == TIER_GREEN) {
                // From GREEN: only escalate if above UP thresholds
                if (utilization >= UTIL_RED_THRESHOLD_UP) return TIER_RED;
                if (utilization >= UTIL_YELLOW_THRESHOLD_UP) return TIER_YELLOW;
                return TIER_GREEN;
            } else if (prevTier == TIER_YELLOW) {
                // From YELLOW: escalate at UP, de-escalate at DOWN
                if (utilization >= UTIL_RED_THRESHOLD_UP) return TIER_RED;
                if (utilization < UTIL_YELLOW_THRESHOLD_DOWN) return TIER_GREEN;
                return TIER_YELLOW; // Stay in YELLOW (hysteresis zone 85-90%)
            } else {
                // From RED: only de-escalate if below DOWN thresholds
                if (utilization < UTIL_YELLOW_THRESHOLD_DOWN) return TIER_GREEN;
                if (utilization < UTIL_RED_THRESHOLD_DOWN) return TIER_YELLOW;
                return TIER_RED; // Stay in RED (hysteresis zone 92-97%)
            }
        } catch {
            return TIER_YELLOW;
        }
    }
    
    /**
     * @notice Assess vault health during bootstrap mode with relaxed thresholds
     * @dev Bootstrap mode prevents new projects from being trapped in RED tier
     *      Uses higher thresholds: 95% for YELLOW, 99% caps at YELLOW (never RED)
     */
    function _assessVaultHealthBootstrap(address token) internal view returns (uint8) {
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) return TIER_GREEN;
        
        try IUnifiedVaultView(infra.unifiedVault).getUtilization() returns (uint256 utilization) {
            // Relaxed thresholds during bootstrap
            if (utilization >= UTIL_BOOTSTRAP_RED) return TIER_YELLOW; // 99% → YELLOW (not RED)
            if (utilization >= UTIL_BOOTSTRAP_YELLOW) return TIER_YELLOW; // 95% → YELLOW
            return TIER_GREEN;
        } catch {
            return TIER_YELLOW; // Conservative default
        }
    }
    
    function _assessDisputeStatus(address token) internal view returns (uint8) {
        address optimisticOracle = registry.optimisticPriceOracle();
        if (optimisticOracle == address(0)) return TIER_GREEN;
        
        try IOptimisticOracleView(optimisticOracle).hasActiveDispute(token) returns (bool hasDispute) {
            if (hasDispute) return TIER_YELLOW;
            return TIER_GREEN;
        } catch {
            return TIER_GREEN;
        }
    }
    
    function _assessWashTrading(address token) internal view returns (uint8) {
        uint40 currentEpoch = uint40(block.timestamp / EPOCH_SECS);
        WashStats storage stats = washStats[token][currentEpoch];
        
        if (stats.trades < MIN_UNIQUE_PARTICIPANTS) return TIER_GREEN;
        
        uint256 washRatio = (uint256(stats.samePairTrades) * 10000) / stats.trades;
        if (washRatio >= WASH_THRESHOLD_BPS) return TIER_RED;
        if (washRatio >= WASH_THRESHOLD_BPS / 2) return TIER_YELLOW;
        
        return TIER_GREEN;
    }
    
    function _applySmoothing(address token, uint8 calculatedTier) internal view returns (uint8) {
        uint8 prevTier = previousTier[token];
        uint256 lastUpdate = lastTierUpdate[token];
        
        // If no previous tier or smoothing period passed, use calculated
        if (lastUpdate == 0 || block.timestamp >= lastUpdate + tierSmoothingPeriod) {
            return calculatedTier;
        }
        
        // During smoothing period, only allow tier to worsen (increase), not improve
        if (calculatedTier > prevTier) {
            return calculatedTier; // Allow immediate worsening
        }
        
        return prevTier; // Keep previous tier during smoothing
    }
    
    function _max(uint8 a, uint8 b) internal pure returns (uint8) {
        return a > b ? a : b;
    }
    
    // ========== TRADE RECORDING (for wash trading detection) ==========
    
    /**
     * @notice Record a trade for wash trading analysis
     * @dev Called by Market after each trade
     */
    function recordTrade(
        address token,
        address maker,
        address taker,
        uint256 price
    ) external {
        // Only Market can record trades
        require(msg.sender == registry.market(), "Only market");
        
        uint40 currentEpoch = uint40(block.timestamp / EPOCH_SECS);
        WashStats storage stats = washStats[token][currentEpoch];
        
        // Increment trade count
        stats.trades++;
        
        // Check for same-pair trading (potential wash)
        if (stats.lastMaker == taker && stats.lastTaker == maker) {
            stats.samePairTrades++;
        }
        
        // Update last maker/taker
        stats.lastMaker = maker;
        stats.lastTaker = taker;
        
        // Update participant bitmaps (simple hash-based tracking)
        stats.bitmapMakers |= (1 << (uint256(uint160(maker)) % 256));
        stats.bitmapTakers |= (1 << (uint256(uint160(taker)) % 256));
        
        // Update epoch tracking
        if (lastEpochId[token] != currentEpoch) {
            lastEpochId[token] = currentEpoch;
            // FIX (#9): Use internal function instead of external call for gas efficiency
            previousTier[token] = _calculateRiskTier(token);
            lastTierUpdate[token] = block.timestamp;
        }
        
        emit TradeRecorded(token, maker, taker, price);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get risk parameters for a token based on its tier
     */
    function getRiskParams(address token) external view returns (
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 supplyCap,
        uint256 borrowCap
    ) {
        // FIX (#9): Use internal function instead of external call for gas efficiency
        uint8 tier = _calculateRiskTier(token);
        TierParams memory params = tierParams[tier];
        
        return (
            params.collateralFactor,
            params.liquidationThreshold,
            params.supplyCap,
            params.borrowCap
        );
    }
    
    /**
     * @notice Get detailed risk assessment for a token
     */
    function getDetailedRiskAssessment(address token) external view returns (
        uint8 overallTier,
        uint8 priceTier,
        uint8 vaultTier,
        uint8 disputeTier,
        uint8 washTier,
        bool circuitBreaker,
        bool manualOverrideActive
    ) {
        overallTier = _calculateRiskTier(token);
        priceTier = _assessPriceHealth(token);
        vaultTier = _assessVaultHealth(token);
        disputeTier = _assessDisputeStatus(token);
        washTier = _assessWashTrading(token);
        circuitBreaker = circuitBreakerTriggered[token];
        manualOverrideActive = hasManualOverride[token];
    }
    
    /**
     * @notice Get wash trading stats for current epoch
     */
    function getWashStats(address token) external view returns (
        uint40 epochId,
        uint32 trades,
        uint32 samePairTrades,
        uint256 washRatioBps
    ) {
        epochId = uint40(block.timestamp / EPOCH_SECS);
        WashStats storage stats = washStats[token][epochId];
        trades = stats.trades;
        samePairTrades = stats.samePairTrades;
        washRatioBps = trades > 0 ? (uint256(samePairTrades) * 10000) / trades : 0;
    }
    
    /**
     * @notice Get recommended supply cap for a token
     */
    function getRecommendedSupplyCap(address token) external view returns (uint256) {
        return _getRecommendedSupplyCapInternal(token);
    }
    
    /**
     * @notice Internal supply cap calculation - Dynamic proportional cap based on market value
     * @dev Formula: Cap = min((TotalSupply × OraclePrice) × TierMultiplier, AbsoluteCeiling)
     *      Falls back to totalRaised if oracle unavailable
     */
    function _getRecommendedSupplyCapInternal(address token) internal view returns (uint256) {
        uint8 tier = _calculateRiskTier(token);
        
        // Get market cap from oracle
        uint256 marketCap = _getMarketCap(token);
        
        // If market cap unavailable, fall back to totalRaised
        if (marketCap == 0) {
            Registry.CampaignData memory campaign = registry.getCampaign(token);
            marketCap = campaign.totalRaised;
        }
        
        // If still zero, use minimum safe cap
        if (marketCap == 0) {
            return 100_000e6; // 100k USDC minimum
        }
        
        // Apply tier multiplier
        uint256 multiplier;
        if (tier == TIER_GREEN) {
            multiplier = MULTIPLIER_GREEN;  // 5x
        } else if (tier == TIER_YELLOW) {
            multiplier = MULTIPLIER_YELLOW; // 2x
        } else {
            multiplier = MULTIPLIER_RED;    // 0.5x
        }
        
        uint256 calculatedCap = (marketCap * multiplier) / ONE;
        
        // Apply absolute ceiling (safety limit)
        uint256 ceiling = assetBaseCaps[token] > 0 ? assetBaseCaps[token] : defaultBaseCap;
        
        return calculatedCap < ceiling ? calculatedCap : ceiling;
    }
    
    /**
     * @notice Get recommended borrow cap for a token
     */
    function getRecommendedBorrowCap(address token) external view returns (uint256) {
        uint256 supplyCap = _getRecommendedSupplyCapInternal(token);
        uint8 tier = _calculateRiskTier(token);
        
        // Borrow cap is a fraction of supply cap based on tier
        if (tier == TIER_GREEN) {
            return (supplyCap * 80) / 100; // 80% of supply
        } else if (tier == TIER_YELLOW) {
            return (supplyCap * 60) / 100; // 60% of supply
        } else {
            return (supplyCap * 40) / 100; // 40% of supply
        }
    }
    
    /**
     * @notice Check if borrowing is allowed for a token
     */
    function isBorrowingAllowed(address token) external view returns (bool) {
        if (circuitBreakerTriggered[token]) return false;
        
        uint8 tier = _calculateRiskTier(token);
        // Allow borrowing for GREEN and YELLOW, not RED
        return tier != TIER_RED;
    }
    
    /**
     * @notice Check if new deposits are allowed for a token
     */
    function isDepositAllowed(address token) external view returns (bool) {
        // Only block deposits if circuit breaker is triggered
        return !circuitBreakerTriggered[token];
    }
    
    /**
     * @notice Get minimum lending liquidity required for a token
     * @dev Proportional to campaign size (10% of market cap/totalRaised), capped at 10k USDC
     * @param token Campaign token address
     * @return Minimum lending pool liquidity in USDC (6 decimals)
     */
    function getMinLendingLiquidity(address token) external view returns (uint256) {
        // Get campaign size (market cap or totalRaised)
        uint256 marketCap = _getMarketCap(token);
        
        if (marketCap == 0) {
            Registry.CampaignData memory campaign = registry.getCampaign(token);
            marketCap = campaign.totalRaised;
        }
        
        // If still zero (pre-launch), use absolute minimum
        if (marketCap == 0) {
            return 100e6; // 100 USDC absolute minimum
        }
        
        // Proportional minimum: 10% of campaign size
        // For $5k campaign: 10% = $500 min liquidity
        // For $100k campaign: 10% = $10k min liquidity
        uint256 proportionalMin = (marketCap * 10) / 100;
        
        // Cap at reasonable maximum (10k USDC)
        uint256 maxMin = 10_000e6;
        
        return proportionalMin < maxMin ? proportionalMin : maxMin;
    }
    
    // ========== DYNAMIC CAP HELPERS ==========
    
    /**
     * @notice Calculate market capitalization from oracle price and total supply
     * @dev Returns market cap in USDC (6 decimals)
     * @param token Campaign token address
     * @return marketCap Market capitalization in USDC, or 0 if unavailable
     */
    function _getMarketCap(address token) internal view returns (uint256) {
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle == address(0)) return 0;
        
        try IPriceOracleView(priceOracle).getPrice(token) returns (uint256 price, bool reliable) {
            if (!reliable) return 0;
            
            // Get total supply
            try IERC20(token).totalSupply() returns (uint256 supply) {
                // marketCap = (supply * price) / precision
                // supply: 6 decimals (campaign token), price: 18 decimals (scaled to 1e18)
                // result: USDC (6 decimals)
                // Formula: (supply * price) / 1e18 = USDC amount
                return (supply * price) / 1e18;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Get dynamic bootstrap volume requirement based on campaign size
     * @dev Scales to 100% of market cap, capped at 10k USDC
     * @param token Campaign token address
     * @return Dynamic bootstrap exit volume in USDC (6 decimals)
     */
    function getBootstrapMinVolume(address token) public view returns (uint256) {
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        uint256 marketCap = campaign.totalRaised;
        
        // If no campaign data, use static cap
        if (marketCap == 0) return BOOTSTRAP_MIN_VOLUME;
        
        // Calculate 100% of market cap for bootstrap exit
        uint256 dynamicMin = (marketCap * BOOTSTRAP_VOLUME_BPS) / 10000;
        
        // Cap at 10k USDC to prevent excessive requirements
        return dynamicMin < BOOTSTRAP_MIN_VOLUME ? dynamicMin : BOOTSTRAP_MIN_VOLUME;
    }
    
    /**
     * @notice Check if a token is in bootstrap mode (30-day grace period for new projects)
     * @dev Bootstrap mode prevents new projects from being trapped in RED tier due to low initial liquidity
     *      Now uses dynamic volume threshold based on campaign size
     * @param token Campaign token address
     * @return bool True if in bootstrap mode
     */
    function isBootstrapping(address token) public view returns (bool) {
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        
        // Check if campaign exists
        if (campaign.token == address(0)) return false;
        
        // Check if within 30 days of campaign end
        if (block.timestamp <= campaign.endTime + BOOTSTRAP_DURATION) {
            // Get dynamic volume threshold based on campaign size
            uint256 minVolume = getBootstrapMinVolume(token);
            
            // Check if minimum volume threshold NOT met
            // Once volume is high enough, normal rules apply
            address priceOracle = registry.hybridPriceOracle();
            if (priceOracle != address(0)) {
                try IPriceOracleView(priceOracle).getVolume24h(token) returns (uint256 volume) {
                    if (volume >= minVolume) {
                        return false; // Volume threshold met, exit bootstrap
                    }
                } catch {
                    // Oracle error, stay in bootstrap mode to be safe
                }
            }
            return true; // Still bootstrapping
        }
        return false; // Bootstrap period expired
    }
    
    /**
     * @notice Get market cap for a token (public view function)
     * @param token Campaign token address
     * @return marketCap Market capitalization in USDC (6 decimals)
     */
    function getMarketCap(address token) external view returns (uint256) {
        return _getMarketCap(token);
    }
}
