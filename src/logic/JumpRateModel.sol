// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ILendingInterfaces.sol";

/**
 * @title JumpRateModel
 * @notice Risk-Aware JumpRateModel with tier-based interest rate curves
 * @dev Returns per-second borrow rate based on utilization AND risk tier
 *      Implements preset curves for GREEN/YELLOW/RED tiers per Dynamic_JumpRateModel_PID.md
 */
contract JumpRateModel is IRateModel, Ownable {
    uint256 public constant ONE = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Maximum allowed APR: 500% (5e18)
    uint256 public constant MAX_BASE_RATE = 5e18;
    uint256 public constant MAX_SLOPE = 10e18; // 1000% max slope
    
    // Risk tiers
    uint8 public constant TIER_GREEN = 0;
    uint8 public constant TIER_YELLOW = 1;
    uint8 public constant TIER_RED = 2;

    // Rate parameters per tier - packed into single struct for gas efficiency
    // All values in 1e18 APR terms
    struct RateParams {
        uint64 baseRate;   // e.g. 0.02e18 = 2% APR (fits in uint64 for values up to 18e18)
        uint64 slope1;     // before kink
        uint64 slope2;     // after kink  
        uint64 kink;       // utilization threshold (0 to 1e18)
    }
    
    // Tier params stored in array for O(1) lookup - more gas efficient than mapping
    RateParams[3] public tierParams;

    event TierRateModelUpdated(uint8 indexed tier, uint256 baseRate, uint256 slope1, uint256 slope2, uint256 kink);
    event RateModelUpdated(uint256 baseRate, uint256 slope1, uint256 slope2, uint256 kink);

    constructor(address _owner) {
        _transferOwnership(_owner);
        
        // Initialize with RWA-optimized presets from Dynamic_JumpRateModel_PID.md
        // GREEN (Growth): 0% base, 6% slope1, 80% slope2, 90% kink → 5.4% APR at kink
        tierParams[TIER_GREEN] = RateParams({
            baseRate: 0,
            slope1: uint64(6e16),      // 6%
            slope2: uint64(80e16),     // 80%
            kink: uint64(90e16)        // 90%
        });
        
        // YELLOW (Caution): 2% base, 12% slope1, 150% slope2, 80% kink → 11.6% APR at kink
        tierParams[TIER_YELLOW] = RateParams({
            baseRate: uint64(2e16),    // 2%
            slope1: uint64(12e16),     // 12%
            slope2: uint64(150e16),    // 150%
            kink: uint64(80e16)        // 80%
        });
        
        // RED (Emergency): 5% base, 40% slope1, 300% slope2, 70% kink → 33% APR at kink
        tierParams[TIER_RED] = RateParams({
            baseRate: uint64(5e16),    // 5%
            slope1: uint64(40e16),     // 40%
            slope2: uint64(300e16),    // 300%
            kink: uint64(70e16)        // 70%
        });
    }

    /**
     * @notice Update rate parameters for a specific tier
     * @param tier Risk tier (0=GREEN, 1=YELLOW, 2=RED)
     * @param _baseRate Base rate in 1e18 APR terms
     * @param _slope1 Slope before kink in 1e18 APR terms
     * @param _slope2 Slope after kink in 1e18 APR terms  
     * @param _kink Utilization threshold in 1e18 (0 to 1e18)
     */
    function setTierParams(
        uint8 tier,
        uint256 _baseRate,
        uint256 _slope1,
        uint256 _slope2,
        uint256 _kink
    ) external onlyOwner {
        require(tier <= TIER_RED, "Invalid tier");
        require(_kink <= ONE, "BAD_KINK");
        require(_baseRate <= MAX_BASE_RATE, "Base rate too high");
        require(_slope1 <= MAX_SLOPE, "Slope1 too high");
        require(_slope2 <= MAX_SLOPE, "Slope2 too high");
        
        tierParams[tier] = RateParams({
            baseRate: uint64(_baseRate),
            slope1: uint64(_slope1),
            slope2: uint64(_slope2),
            kink: uint64(_kink)
        });
        
        emit TierRateModelUpdated(tier, _baseRate, _slope1, _slope2, _kink);
    }

    /**
     * @notice Get borrow rate per second based on utilization and risk tier
     * @param utilization Current utilization scaled 1e18 (0 to 1e18)
     * @param riskTier Risk tier (0=GREEN, 1=YELLOW, 2=RED)
     * @return Borrow rate per second scaled 1e18
     */
    function getBorrowRatePerSecond(uint256 utilization, uint8 riskTier) external view override returns (uint256) {
        return _calculateRate(utilization, riskTier);
    }
    
    /**
     * @notice Internal rate calculation - optimized for gas
     * @dev Uses unchecked math where safe, single SLOAD for tier params
     */
    function _calculateRate(uint256 utilization, uint8 riskTier) internal view returns (uint256) {
        if (utilization > ONE) utilization = ONE;
        if (riskTier > TIER_RED) riskTier = TIER_GREEN; // Default to GREEN for invalid tiers
        
        // Single SLOAD - load entire struct at once (gas optimization)
        RateParams memory params = tierParams[riskTier];
        
        uint256 ratePerYear;
        uint256 kinkVal = uint256(params.kink);
        
        if (utilization <= kinkVal) {
            // Below kink: baseRate + slope1 * utilization / ONE
            ratePerYear = uint256(params.baseRate) + (uint256(params.slope1) * utilization / ONE);
        } else {
            // Above kink: baseRate + slope1 * kink + slope2 * (utilization - kink)
            uint256 extra = utilization - kinkVal;
            ratePerYear = uint256(params.baseRate) 
                + (uint256(params.slope1) * kinkVal / ONE) 
                + (uint256(params.slope2) * extra / ONE);
        }
        
        // Convert APR to per-second rate
        return ratePerYear / SECONDS_PER_YEAR;
    }

    /**
     * @notice Get supply rate per second (for display purposes)
     * @param utilization Current utilization scaled 1e18
     * @param reserveFactor Protocol reserve factor scaled 1e18
     * @param riskTier Risk tier (0=GREEN, 1=YELLOW, 2=RED)
     */
    function getSupplyRatePerSecond(uint256 utilization, uint256 reserveFactor, uint8 riskTier) external view returns (uint256) {
        if (utilization > ONE) utilization = ONE;
        
        uint256 borrowRate = _calculateRate(utilization, riskTier);
        uint256 rateToPool = borrowRate * (ONE - reserveFactor) / ONE;
        return rateToPool * utilization / ONE;
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get rate parameters for a specific tier
     */
    function getTierParams(uint8 tier) external view returns (
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 kink
    ) {
        require(tier <= TIER_RED, "Invalid tier");
        RateParams memory params = tierParams[tier];
        return (
            uint256(params.baseRate),
            uint256(params.slope1),
            uint256(params.slope2),
            uint256(params.kink)
        );
    }
    
    /**
     * @notice Calculate APR at a given utilization and tier (for display)
     */
    function getAPR(uint256 utilization, uint8 riskTier) external view returns (uint256) {
        return _calculateRate(utilization, riskTier) * SECONDS_PER_YEAR;
    }
    
    /**
     * @notice Get APR at kink for each tier (for comparison)
     */
    function getAPRsAtKink() external view returns (
        uint256 greenAPR,
        uint256 yellowAPR,
        uint256 redAPR
    ) {
        greenAPR = _calculateRate(uint256(tierParams[TIER_GREEN].kink), TIER_GREEN) * SECONDS_PER_YEAR;
        yellowAPR = _calculateRate(uint256(tierParams[TIER_YELLOW].kink), TIER_YELLOW) * SECONDS_PER_YEAR;
        redAPR = _calculateRate(uint256(tierParams[TIER_RED].kink), TIER_RED) * SECONDS_PER_YEAR;
    }
}
