// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./Registry.sol";

/**
 * @title HybridPriceOracle
 * @notice Volume-weighted average price oracle for campaign tokens
 * @dev Uses VWAP (Volume-Weighted Average Price) to prevent low-volume manipulation
 *      Price impact is weighted by trade volume - larger trades have more influence
 */
contract HybridPriceOracle is IPriceOracle, Ownable {
    uint256 public constant ONE = 1e18;
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant PAYMENT_TOKEN_DECIMALS = 1e6; // USDC decimals
    
    // Per-token configuration
    struct TokenConfig {
        uint256 staleThreshold;    // Time before price considered stale (default: 1 hour)
        uint256 minVolume24h;      // Minimum 24h volume for reliable price (default: 1000 USDC)
        uint256 targetVolume;      // Reference volume for VWAP weight (default: 10k USDC)
        uint256 minUpdateVolume;   // Min volume to trigger update (default: 100 USDC)
    }
    
    // VWAP data structure
    struct VWAPData {
        uint256 price;           // Current EMA price (scaled to 1e18)
        uint256 lastUpdate;      // Last update timestamp
        uint256 volume24h;       // Rolling 24h volume
        uint256 lastVolumeReset; // Last time volume was reset
        uint256 initTime;        // When price was initialized (for bootstrap period)
        bool initialized;        // Whether price has been set
    }
    
    // Storage
    mapping(address => TokenConfig) public tokenConfigs;
    mapping(address => VWAPData) public vwapData;
    mapping(address => bool) public authorizedUpdaters;

    // Consecutive rejection tracking for reliability assessment
    // When price deviations are repeatedly clamped, the EMA may be stuck far from market
    // This counter preserves the "unreliable" signal even though lastUpdate advances
    mapping(address => uint256) public consecutiveRejections;
    uint256 public constant MAX_CONSECUTIVE_REJECTIONS = 10; // After this, price marked unreliable
    
    // Fallback oracle (ManualPriceOracle or OptimisticPriceOracle)
    // NOTE: fallbackOracle removed - now retrieved from Registry as optimisticPriceOracle
    Registry public registry;
    
    // Price deviation limits (CRITICAL SECURITY FIX)
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000; // 20% max deviation per update

    // Bootstrap period: first 24h after initialization, no deviation clamp and faster EMA
    // This allows new tokens to converge to market price quickly without getting stuck
    uint256 public constant BOOTSTRAP_PERIOD = 24 hours;
    uint256 public constant BOOTSTRAP_MIN_ALPHA = 2e17; // 20% min alpha during bootstrap (ensures convergence)
    uint256 public constant BOOTSTRAP_MAX_ALPHA = 5e17; // 50% max alpha during bootstrap (vs ~2% normal)

    // Configurable timing parameters (set via setDecayConfig in multisig deployment)
    // Test defaults allow fast iteration; production values set post-deployment
    uint256 public MIN_UPDATE_INTERVAL = 5 minutes; // production: 1 hours
    uint256 public PHASE1_DAYS = 1; // production: 14 (days)
    uint256 public PHASE2_DAYS = 3; // production: 30 (days)
    uint256 public MAX_DECAY_DAYS = 6; // production: 60 (days)

    // Price decay rates (constant — not deployment-configurable)
    uint256 public constant DECAY_RATE_PHASE1 = 2e16; // 2% per day
    uint256 public constant DECAY_RATE_PHASE2 = 5e16; // 5% per day
    uint256 public constant DECAY_RATE_PHASE3 = 10e16; // 10% per day
    
    // Minimum price floor (5% of last trade price)
    uint256 public constant MIN_PRICE_FLOOR = 5e16; // 5% minimum
    
    // Default configurations (used as caps for dynamic scaling)
    uint256 public defaultStaleThreshold = 15 minutes; // production 4 hours;
    uint256 public defaultMinVolume24h = 1000e6;      // 1000 USDC (cap)
    uint256 public defaultTargetVolume = 10000e6;     // 10k USDC (cap)
    uint256 public defaultMinUpdateVolume = 100e6;    // 100 USDC (cap)
    
    // Dynamic volume scaling percentages (basis points)
    uint256 public constant MIN_VOLUME_BPS = 1000;     // 10% of market cap for reliable price
    uint256 public constant TARGET_VOLUME_BPS = 10000; // 100% of market cap for VWAP target
    uint256 public constant UPDATE_VOLUME_BPS = 100;   // 1% of market cap for updates
    
    // Events
    event PriceUpdated(address indexed asset, uint256 price, uint256 volume);
    event TokenConfigured(address indexed asset, uint256 staleThreshold, uint256 minVolume24h, uint256 targetVolume);
    event UpdaterAuthorized(address indexed updater, bool authorized);
    event DecayConfigUpdated(uint256 minUpdateInterval, uint256 phase1Days, uint256 phase2Days, uint256 maxDecayDays);
    event FallbackOracleSet(address indexed fallbackOracle);
    event FallbackUsed(address indexed asset, uint256 price, string reason);
    event PriceDeviationRejected(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 deviation);
    event PriceDeviationClamped(address indexed asset, uint256 oldPrice, uint256 clampedPrice, uint256 originalPrice, uint256 deviation);
    event PriceInitialized(address indexed asset, uint256 price, uint256 volume);
    
    constructor(address _owner) { 
        _transferOwnership(_owner); 
    }
    
    // --- Registry Functions ---
    
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    function _getFallbackOracle() internal view returns (IPriceOracle) {
        if (address(registry) == address(0)) return IPriceOracle(address(0));
        address addr = registry.optimisticPriceOracle();
        return addr != address(0) ? IPriceOracle(addr) : IPriceOracle(address(0));
    }
    
    modifier onlyAuthorized() {
        require(authorizedUpdaters[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    /**
     * @notice Configure token pricing parameters
     * @param asset Token address
     * @param staleThreshold Custom staleness threshold (0 = use default)
     * @param minVolume24h Minimum 24h volume for reliable price (0 = use default)
     * @param targetVolume Reference volume for VWAP weighting (0 = use default)
     */
    function configureToken(
        address asset,
        uint256 staleThreshold,
        uint256 minVolume24h,
        uint256 targetVolume
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        
        if (staleThreshold == 0) staleThreshold = defaultStaleThreshold;
        if (minVolume24h == 0) minVolume24h = defaultMinVolume24h;
        if (targetVolume == 0) targetVolume = defaultTargetVolume;
        
        tokenConfigs[asset] = TokenConfig({
            staleThreshold: staleThreshold,
            minVolume24h: minVolume24h,
            targetVolume: targetVolume,
            minUpdateVolume: defaultMinUpdateVolume
        });
        
        emit TokenConfigured(asset, staleThreshold, minVolume24h, targetVolume);
    }
    
    /**
     * @notice Record a trade (alias for updatePrice for interface compatibility)
     * @dev Called by Market after each trade
     */
    function recordTrade(address token, uint256 price, uint256 amount) external onlyAuthorized {
        TokenConfig memory config = tokenConfigs[token];
        
        // Use defaults if not configured
        if (config.staleThreshold == 0) {
            config.staleThreshold = defaultStaleThreshold;
            config.minVolume24h = defaultMinVolume24h;
            config.targetVolume = defaultTargetVolume;
            config.minUpdateVolume = defaultMinUpdateVolume;
        }
        
        // Scale price from 6 decimals to 18 decimals
        uint256 scaledPrice = price * PRICE_SCALE / PAYMENT_TOKEN_DECIMALS;
        
        _updateVWAP(token, scaledPrice, amount, config);
        
        emit PriceUpdated(token, scaledPrice, amount);
    }
    
    function updatePrice(address asset, uint256 priceWad, uint256 volumeWad) external override onlyAuthorized {
        TokenConfig memory config = tokenConfigs[asset];
        
        // Use defaults if not configured
        if (config.staleThreshold == 0) {
            config.staleThreshold = defaultStaleThreshold;
            config.minVolume24h = defaultMinVolume24h;
            config.targetVolume = defaultTargetVolume;
            config.minUpdateVolume = defaultMinUpdateVolume;
        }
        
        // priceWad is already in 1e18 format (Wad suffix convention), no scaling needed
        _updateVWAP(asset, priceWad, volumeWad, config);
        
        emit PriceUpdated(asset, priceWad, volumeWad);
    }
    
    /**
     * @notice Update VWAP (existing volume-weighted EMA logic)
     */
    function _updateVWAP(
        address asset,
        uint256 scaledPrice,
        uint256 volumeWad,
        TokenConfig memory config
    ) internal {
        VWAPData storage data = vwapData[asset];

        // Always accumulate 24h volume (even if price update is skipped)
        if (block.timestamp >= data.lastVolumeReset + 24 hours) {
            data.volume24h = volumeWad;
            data.lastVolumeReset = block.timestamp;
        } else {
            data.volume24h += volumeWad;
        }

        if (!data.initialized) {
            // First price update: Accept any volume to initialize
            data.price = scaledPrice;
            data.initialized = true;
            data.initTime = block.timestamp;
            data.lastUpdate = block.timestamp;
            return;
        }

        // SECURITY: Skip price update if too frequent (prevents rapid manipulation)
        // Volume has already been accumulated above — only price update is rate-limited
        if (block.timestamp < data.lastUpdate + MIN_UPDATE_INTERVAL) {
            return;
        }

        // CRITICAL FIX (L-2): Guard against division by zero
        if (data.price == 0) {
            data.price = scaledPrice;
            data.lastUpdate = block.timestamp;
            return;
        }

        // Check if in bootstrap period (first 24h after initialization)
        bool inBootstrap = block.timestamp - data.initTime < BOOTSTRAP_PERIOD;

        if (inBootstrap) {
            // BOOTSTRAP: No deviation clamp — let EMA converge to market price freely
            // This prevents the "stuck EMA" death spiral for new tokens trading far from mint price
            consecutiveRejections[asset] = 0;

            // Only update price if volume is significant
            if (volumeWad >= config.minUpdateVolume) {
                // Use higher alpha during bootstrap for faster convergence
                uint256 alpha = (volumeWad * ONE) / (volumeWad + config.targetVolume);
                // Enforce minimum alpha during bootstrap (ensures convergence even for small trades)
                if (alpha < BOOTSTRAP_MIN_ALPHA) alpha = BOOTSTRAP_MIN_ALPHA;
                if (alpha > BOOTSTRAP_MAX_ALPHA) alpha = BOOTSTRAP_MAX_ALPHA;

                uint256 newWeight = scaledPrice * alpha / ONE;
                uint256 oldWeight = data.price * (ONE - alpha) / ONE;
                data.price = newWeight + oldWeight;
            }
        } else {
            // NORMAL: Check price deviation — clamp instead of reject
            // This prevents manipulation while allowing gradual convergence
            uint256 deviation = scaledPrice > data.price ?
                ((scaledPrice - data.price) * 10000) / data.price :
                ((data.price - scaledPrice) * 10000) / data.price;

            if (deviation > MAX_PRICE_DEVIATION_BPS) {
                // Clamp trade price to ±20% boundary of current EMA
                uint256 originalPrice = scaledPrice;
                if (scaledPrice > data.price) {
                    scaledPrice = data.price * (10000 + MAX_PRICE_DEVIATION_BPS) / 10000;
                } else {
                    scaledPrice = data.price * (10000 - MAX_PRICE_DEVIATION_BPS) / 10000;
                }
                consecutiveRejections[asset]++;
                emit PriceDeviationClamped(asset, data.price, scaledPrice, originalPrice, deviation);
            } else {
                // Normal update within deviation bounds — reset rejection counter
                consecutiveRejections[asset] = 0;
            }

            // Only update price if volume is significant
            if (volumeWad >= config.minUpdateVolume) {
                // Calculate dynamic alpha based on volume
                uint256 alpha = (volumeWad * ONE) / (volumeWad + config.targetVolume);

                // VWAP EMA: newPrice = alpha * tradePrice + (1 - alpha) * currentPrice
                uint256 newWeight = scaledPrice * alpha / ONE;
                uint256 oldWeight = data.price * (ONE - alpha) / ONE;
                data.price = newWeight + oldWeight;
            }
        }

        data.lastUpdate = block.timestamp;
    }
    
    
    /**
     * @notice Get price of asset with multi-tier fallback
     * @param asset Token address
     * @return priceWad Price scaled to 1e18
     * @return reliable Whether price is reliable (not stale, sufficient volume)
     * 
     * Fallback tiers:
     * 1. On-chain VWAP (if reliable)
     * 2. Fallback oracle (OptimisticPriceOracle)
     * 3. Decayed last known price (tiered decay based on staleness)
     */
    function getPrice(address asset) external view override returns (uint256 priceWad, bool reliable) {
        TokenConfig memory config = tokenConfigs[asset];
        
        // Use defaults if not configured
        if (config.staleThreshold == 0) {
            config.staleThreshold = defaultStaleThreshold;
            config.minVolume24h = defaultMinVolume24h;
        }
        
        // Tier 1: Try on-chain VWAP
        (priceWad, reliable) = _getVWAPPrice(asset, config);
        
        if (reliable && priceWad > 0) {
            return (priceWad, true);
        }
        
        // Tier 2: Try fallback oracle (OptimisticPriceOracle from Registry)
        IPriceOracle _fallbackOracle = _getFallbackOracle();
        if (address(_fallbackOracle) != address(0)) {
            try _fallbackOracle.getPrice(asset) returns (uint256 fallbackPrice, bool fallbackReliable) {
                if (fallbackReliable && fallbackPrice > 0) {
                    return (fallbackPrice, true);
                }
            } catch {}
        }
        
        // Tier 3: Use decayed last known price (unreliable but better than nothing)
        if (priceWad > 0) {
            uint256 decayedPrice = _getDecayedPrice(asset, priceWad);
            return (decayedPrice, false); // Mark as unreliable
        }
        
        // No price available
        return (0, false);
    }
    
    /**
     * @notice Get VWAP price
     * @dev Checks staleness and volume requirements (now dynamic based on campaign size)
     */
    function _getVWAPPrice(address asset, TokenConfig memory config) internal view returns (uint256 priceWad, bool reliable) {
        VWAPData memory data = vwapData[asset];
        
        if (!data.initialized) {
            return (0, false);
        }
        
        // Check if price is stale
        bool notStale = block.timestamp - data.lastUpdate <= config.staleThreshold;
        
        // Get dynamic minimum volume requirement based on campaign size
        uint256 dynamicMinVolume = _getDynamicMinVolume(asset, config.minVolume24h);
        
        // Check if sufficient volume
        bool sufficientVolume = data.volume24h >= dynamicMinVolume;
        
        // Check if EMA is stuck (too many consecutive clamped updates)
        // When rejections pile up, the EMA may be far from market price even though lastUpdate is fresh
        bool notStuck = consecutiveRejections[asset] < MAX_CONSECUTIVE_REJECTIONS;
        
        reliable = notStale && sufficientVolume && notStuck;
        priceWad = data.price;
    }
    
    
    /**
     * @notice Manually set price (admin only, for initialization or emergency)
     * @dev Also resets consecutiveRejections counter to unstick wedged tokens
     * @param asset Token address
     * @param priceWad Price in 1e18 format
     */
    function setPrice(address asset, uint256 priceWad) external onlyOwner {
        require(priceWad > 0, "Price must be > 0");
        VWAPData storage data = vwapData[asset];
        data.price = priceWad;
        data.lastUpdate = block.timestamp;
        data.initialized = true;
        if (data.lastVolumeReset == 0) {
            data.lastVolumeReset = block.timestamp;
        }
        if (data.initTime == 0) {
            data.initTime = block.timestamp;
        }
        // Reset rejection counter — admin override to unstick wedged tokens
        consecutiveRejections[asset] = 0;
        
        emit PriceUpdated(asset, priceWad, 0);
    }

    /**
     * @notice Set price, volume, and reset rejections in one call (admin only, for migration/re-seeding)
     * @dev Used when migrating to a new oracle instance or re-seeding after configuration changes
     * @param asset Token address
     * @param priceWad Price in 1e18 format
     * @param volume24h Initial 24h volume in USDC (6 decimals)
     */
    function setPriceWithVolume(address asset, uint256 priceWad, uint256 volume24h) external onlyOwner {
        require(priceWad > 0, "Price must be > 0");
        VWAPData storage data = vwapData[asset];
        data.price = priceWad;
        data.lastUpdate = block.timestamp;
        data.volume24h = volume24h;
        data.lastVolumeReset = block.timestamp;
        data.initTime = block.timestamp; // Enable bootstrap for migrated tokens (allows EMA convergence)
        data.initialized = true;
        consecutiveRejections[asset] = 0;
        
        emit PriceUpdated(asset, priceWad, volume24h);
    }
    
    /**
     * @notice Initialize price at campaign success (called by LendingManager)
     * @dev Computes initial price from campaign data (totalRaised / totalSupply) instead of
     *      hardcoding $1.00. Falls back to $1.00 if campaign data is unavailable.
     *      Sets initTime for bootstrap period tracking.
     * @param asset Token address
     * @param initialVolume Campaign total raised (mint volume in USDC, 6 decimals)
     */
    function initializePrice(address asset, uint256 initialVolume) external onlyAuthorized {
        require(!vwapData[asset].initialized, "Price already initialized");
        
        // Compute initial price from campaign data: totalRaised / totalSupply
        // Both are in 6 decimals (USDC and MinimumERC20 tokens), so the ratio is dimensionless
        // Scale to 1e18 WAD format for internal storage
        uint256 initialPrice = ONE; // Default to $1.00
        if (address(registry) != address(0)) {
            Registry.CampaignData memory campaign = registry.getCampaign(asset);
            if (campaign.totalRaised > 0) {
                uint256 tokenSupply = IERC20(asset).totalSupply();
                if (tokenSupply > 0) {
                    initialPrice = (campaign.totalRaised * ONE) / tokenSupply;
                }
            }
        }
        
        VWAPData storage data = vwapData[asset];
        data.price = initialPrice;
        data.lastUpdate = block.timestamp;
        data.volume24h = initialVolume;
        data.lastVolumeReset = block.timestamp;
        data.initTime = block.timestamp;
        data.initialized = true;
        
        emit PriceInitialized(asset, initialPrice, initialVolume);
    }
    
    /**
     * @notice Calculate dynamic minimum volume based on campaign size
     * @dev Scales volume requirements proportionally to market cap, capped at static defaults
     * @param asset Token address
     * @param staticCap Maximum volume requirement (fallback/cap)
     * @return Dynamic minimum volume in USDC (6 decimals)
     */
    function _getDynamicMinVolume(address asset, uint256 staticCap) internal view returns (uint256) {
        // Get market cap from campaign data
        if (address(registry) == address(0)) return staticCap;
        
        Registry.CampaignData memory campaign = registry.getCampaign(asset);
        uint256 marketCap = campaign.totalRaised;
        
        // If no campaign data, use static cap
        if (marketCap == 0) return staticCap;
        
        // Calculate 10% of market cap for minimum volume
        uint256 dynamicMin = (marketCap * MIN_VOLUME_BPS) / 10000;
        
        // Cap at static default to prevent excessive requirements for large campaigns
        return dynamicMin < staticCap ? dynamicMin : staticCap;
    }
    
    /**
     * @notice Get dynamic minimum volume requirement for a token (public view)
     * @param asset Token address
     * @return Minimum 24h volume required for reliable price
     */
    function getMinVolume24h(address asset) external view returns (uint256) {
        TokenConfig memory config = tokenConfigs[asset];
        uint256 staticCap = config.minVolume24h > 0 ? config.minVolume24h : defaultMinVolume24h;
        return _getDynamicMinVolume(asset, staticCap);
    }
    
    /**
     * @notice Set default configuration parameters
     */
    function setDefaultConfig(
        uint256 staleThreshold,
        uint256 minVolume24h,
        uint256 targetVolume,
        uint256 minUpdateVolume
    ) external onlyOwner {
        require(staleThreshold >= 30 minutes && staleThreshold <= 7 days, "Invalid stale threshold");
        require(minVolume24h >= 100e6, "Min volume too low");
        require(targetVolume >= 1000e6, "Target volume too low");
        require(minUpdateVolume >= 10e6, "Min update volume too low");
        
        defaultStaleThreshold = staleThreshold;
        defaultMinVolume24h = minVolume24h;
        defaultTargetVolume = targetVolume;
        defaultMinUpdateVolume = minUpdateVolume;
    }
    
    /**
     * @notice Set decay and update timing parameters (production configuration)
     * @dev Test defaults are short for fast iteration; multisig sets production values post-deployment
     * @param _minUpdateInterval Minimum time between price updates (test: 5 min, prod: 1 hour)
     * @param _phase1Days Phase 1 decay duration in days (test: 1, prod: 14)
     * @param _phase2Days Phase 2 decay duration in days (test: 3, prod: 30)
     * @param _maxDecayDays Maximum decay duration in days (test: 6, prod: 60)
     */
    function setDecayConfig(
        uint256 _minUpdateInterval,
        uint256 _phase1Days,
        uint256 _phase2Days,
        uint256 _maxDecayDays
    ) external onlyOwner {
        require(_minUpdateInterval >= 1 minutes && _minUpdateInterval <= 1 days, "Invalid update interval");
        require(_phase1Days > 0 && _phase1Days < _phase2Days, "Invalid phase1 days");
        require(_phase2Days > _phase1Days && _phase2Days < _maxDecayDays, "Invalid phase2 days");
        require(_maxDecayDays > _phase2Days && _maxDecayDays <= 365 days, "Invalid max decay days");

        MIN_UPDATE_INTERVAL = _minUpdateInterval;
        PHASE1_DAYS = _phase1Days;
        PHASE2_DAYS = _phase2Days;
        MAX_DECAY_DAYS = _maxDecayDays;

        emit DecayConfigUpdated(_minUpdateInterval, _phase1Days, _phase2Days, _maxDecayDays);
    }

    /**
     * @notice Authorize or deauthorize a price updater (e.g., Market contract)
     */
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorized(updater, authorized);
    }
    
    /**
     * @notice Get token configuration
     */
    function getTokenConfig(address asset) external view returns (TokenConfig memory) {
        return tokenConfigs[asset];
    }
    
    /**
     * @notice Get VWAP data for an asset
     */
    function getVWAPData(address asset) external view returns (VWAPData memory) {
        return vwapData[asset];
    }
    
    /**
     * @notice Get price staleness in seconds
     * @dev Used by RiskOracle for staleness-based risk assessment
     * @param asset Token address
     * @return secondsStale Number of seconds since last price update
     */
    function getPriceStaleness(address asset) external view returns (uint256) {
        uint256 lastUpdate = vwapData[asset].lastUpdate;
        if (lastUpdate == 0) return type(uint256).max;
        return block.timestamp - lastUpdate;
    }

    /**
     * @notice Get consecutive rejection count for a token
     * @dev High count indicates EMA is stuck far from market price
     * @param asset Token address
     * @return count Number of consecutive clamped updates (resets to 0 on normal update)
     */
    function getConsecutiveRejections(address asset) external view returns (uint256) {
        return consecutiveRejections[asset];
    }
    
    // NOTE: setFallbackOracle removed - fallback oracle now retrieved from Registry as optimisticPriceOracle
    
    /**
     * @notice Calculate decayed price with two-tier decay model
     * @dev Phase 1: 2% per day (0-14 days) - gentle for short-term illiquidity
     *      Phase 2: 5% per day (15-30 days) - moderate warning signal
     *      Phase 3: 10% per day (31-60 days) - aggressive for dead projects
     *      Floor: 5% minimum - allows recovery, prevents complete zero
     */
    function _getDecayedPrice(
        address asset,
        uint256 lastPrice
    ) internal view returns (uint256) {
        uint256 lastUpdate = vwapData[asset].lastUpdate;
        if (lastUpdate == 0) return 0;
        
        uint256 elapsed = block.timestamp - lastUpdate;
        uint256 daysElapsed = elapsed / 1 days;
        
        // If no decay needed, return original price
        if (daysElapsed == 0) return lastPrice;
        
        uint256 decayFactor = ONE; // 1e18
        
        // CRITICAL FIX (#8): Use exponential calculation instead of loops to save gas
        // Old approach: up to 60 loop iterations = excessive gas
        // New approach: direct exponential calculation
        
        // Phase 1: Days 0-14 (2% per day)
        if (daysElapsed <= PHASE1_DAYS) {
            decayFactor = _expDecay(ONE - DECAY_RATE_PHASE1, daysElapsed);
        }
        // Phase 2: Days 15-30 (5% per day)
        else if (daysElapsed <= PHASE2_DAYS) {
            // Apply Phase 1 decay (14 days at 2%)
            decayFactor = _expDecay(ONE - DECAY_RATE_PHASE1, PHASE1_DAYS);
            // Apply Phase 2 decay (remaining days at 5%)
            uint256 phase2Days = daysElapsed - PHASE1_DAYS;
            decayFactor = (decayFactor * _expDecay(ONE - DECAY_RATE_PHASE2, phase2Days)) / ONE;
        }
        // Phase 3: Days 31+ (10% per day, capped at 60 days)
        else {
            // Apply Phase 1 decay (14 days at 2%)
            decayFactor = _expDecay(ONE - DECAY_RATE_PHASE1, PHASE1_DAYS);
            // Apply Phase 2 decay (16 days at 5%)
            uint256 phase2Days = PHASE2_DAYS - PHASE1_DAYS;
            decayFactor = (decayFactor * _expDecay(ONE - DECAY_RATE_PHASE2, phase2Days)) / ONE;
            // Apply Phase 3 decay (remaining days at 10%, capped at 60 total)
            uint256 phase3Days = daysElapsed - PHASE2_DAYS;
            if (phase3Days > (MAX_DECAY_DAYS - PHASE2_DAYS)) {
                phase3Days = MAX_DECAY_DAYS - PHASE2_DAYS;
            }
            decayFactor = (decayFactor * _expDecay(ONE - DECAY_RATE_PHASE3, phase3Days)) / ONE;
        }
        
        // Calculate decayed price
        uint256 decayedPrice = lastPrice * decayFactor / ONE;
        
        // Apply floor (minimum 5% of last price)
        uint256 minPrice = lastPrice * MIN_PRICE_FLOOR / ONE;
        if (decayedPrice < minPrice) {
            decayedPrice = minPrice;
        }
        
        return decayedPrice;
    }
    
    /**
     * @notice Calculate exponential decay efficiently using binary exponentiation
     * @dev CRITICAL FIX (#8): Replaces O(n) loops with O(log n) calculation
     * @param base The decay factor per period (e.g., 0.98e18 for 2% decay)
     * @param exp Number of periods
     * @return result base^exp in 1e18 precision
     */
    function _expDecay(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = ONE; // 1e18
        
        // Binary exponentiation: O(log n) instead of O(n)
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * base) / ONE;
            }
            base = (base * base) / ONE;
            exp >>= 1;
        }
    }
    
    /**
     * @notice Get 24-hour trading volume for a token
     * @dev Used by RiskOracle for bootstrap mode detection
     * @param asset Token address
     * @return volume24h Rolling 24-hour volume in USDC (6 decimals)
     */
    function getVolume24h(address asset) external view returns (uint256) {
        return vwapData[asset].volume24h;
    }
}
