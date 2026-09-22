// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/Registry.sol";
import "../src/RiskOracle.sol";
import "../src/HybridPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title RiskOracleProportional Test
 * @notice Comprehensive tests for dynamic proportional vault cap system
 * @dev Tests the following scenarios:
 *      1. Cap increases when token price rises
 *      2. Cap decreases when token price drops
 *      3. Cap changes immediately when risk tier changes
 *      4. Bootstrap mode prevents RED tier for new projects
 *      5. Bootstrap mode exits after 30 days or volume threshold
 *      6. Fallback to totalRaised when oracle unavailable
 */
contract RiskOracleProportionalTest is Test {
    RiskOracle public riskOracle;
    Registry public registry;
    HybridPriceOracle public priceOracle;
    
    address public owner = address(this);
    address public mockToken;
    address public mockVault;
    
    uint256 constant INITIAL_SUPPLY = 1_000_000e18; // 1M tokens
    uint256 constant INITIAL_PRICE = 1e18; // $1
    uint256 constant INITIAL_RAISED = 1_000_000e6; // 1M USDC
    
    event RiskTierUpdated(address indexed token, uint8 oldTier, uint8 newTier);
    
    function setUp() public {
        // Set block timestamp to a reasonable value to avoid underflow
        vm.warp(100 days);
        
        // Deploy Registry with proxy
        Registry registryImpl = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = Registry(address(registryProxy));
        
        // Deploy HybridPriceOracle
        priceOracle = new HybridPriceOracle(owner);
        
        // Deploy RiskOracle
        riskOracle = new RiskOracle(owner, address(registry));
        
        // Set price oracle in registry
        registry.setHybridPriceOracle(address(priceOracle));
        
        // Authorize test contract to update prices
        priceOracle.setAuthorizedUpdater(address(this), true);
        
        // Deploy mock token
        mockToken = address(new MockCampaignToken("Movie Token", "MOVIE", INITIAL_SUPPLY));
        
        // Configure token in price oracle (set low thresholds for testing)
        priceOracle.configureToken(mockToken, 1 hours, 100e6, 1000e6);
        
        // Deploy mock vault
        mockVault = address(new MockUnifiedVault());
        
        // Register campaign (ended, successful)
        registry.registerCampaign(
            mockToken,
            owner, // creator
            address(0), // paymentToken (use default USDC)
            500_000e6, // floor
            2_000_000e6, // ceiling
            0, // OVERAGE_NONE
            owner, // fundsRecipient
            block.timestamp - 31 days, // startTime (started 31 days ago)
            block.timestamp - 1 days // endTime (ended yesterday - campaign is over)
        );
        
        // Update totalRaised to meet floor (makes campaign successful)
        registry.updateCampaignRaise(mockToken, INITIAL_RAISED);
        
        // Enable market (marks campaign as successful)
        registry.enableMarket(mockToken);
        
        // Register lending infrastructure
        registry.registerUnifiedVault(mockToken, mockVault);
        
        // Initialize price oracle with volume (makes it reliable)
        priceOracle.updatePrice(mockToken, INITIAL_PRICE, 1000e6); // $1, 1000 USDC volume
        
        // Advance time after setup to allow price updates in tests
        vm.warp(block.timestamp + 6 minutes);
    }
    
    // ========== TEST CASE 1: Cap Increases with Price ==========
    
    function test_CapIncreasesWithPrice() public {
        // Initial state: Price = $1, Supply = 1M, Tier = GREEN
        // Expected cap = (1M * $1) * 5x = $5M
        uint256 initialCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(initialCap, 5_000_000e6, "Initial cap should be 5M USDC");
        
        // Advance time to avoid MIN_UPDATE_INTERVAL
        vm.warp(block.timestamp + 6 minutes);
        
        // Simulate price increase to $2
        priceOracle.updatePrice(mockToken, 2e18, 2000e6);
        
        // Expected cap = (1M * $2) * 5x = $10M (hits ceiling)
        uint256 newCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(newCap, 10_000_000e6, "Cap should increase to 10M USDC (ceiling)");
    }
    
    function test_CapIncreasesWithPriceNoceiling() public {
        // Set higher ceiling
        riskOracle.setAssetBaseCap(mockToken, 50_000_000e6); // 50M ceiling
        
        // Advance time
        vm.warp(block.timestamp + 6 minutes);
        
        // Price = $3
        priceOracle.updatePrice(mockToken, 3e18, 3000e6);
        
        // Expected cap = (1M * $3) * 5x = $15M
        uint256 cap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(cap, 15_000_000e6, "Cap should be 15M USDC");
    }
    
    // ========== TEST CASE 2: Cap Decreases with Price Drop ==========
    
    function test_CapDecreasesWithPriceDrop() public {
        // Initial cap at $1
        uint256 initialCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(initialCap, 5_000_000e6, "Initial cap should be 5M USDC");
        
        // Advance time
        vm.warp(block.timestamp + 6 minutes);
        
        // Price drops to $0.50
        priceOracle.updatePrice(mockToken, 5e17, 500e6);
        
        // Expected cap = (1M * $0.50) * 5x = $2.5M
        uint256 newCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(newCap, 2_500_000e6, "Cap should decrease to 2.5M USDC");
    }
    
    function test_CapDecreasesWithPriceCrash() public {
        // Advance time
        vm.warp(block.timestamp + 6 minutes);
        
        // Price crashes to $0.10
        priceOracle.updatePrice(mockToken, 1e17, 100e6);
        
        // Expected cap = (1M * $0.10) * 5x = $500k
        uint256 cap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(cap, 500_000e6, "Cap should decrease to 500k USDC");
    }
    
    // ========== TEST CASE 3: Cap Changes with Risk Tier ==========
    
    function test_CapChangesWithTierChange() public {
        // Initial: GREEN tier, cap = 5M
        uint256 greenCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(greenCap, 5_000_000e6, "GREEN cap should be 5M USDC");
        
        // Force YELLOW tier via manual override
        riskOracle.setManualOverride(mockToken, 1); // TIER_YELLOW
        
        // Expected cap = (1M * $1) * 2x = $2M
        uint256 yellowCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(yellowCap, 2_000_000e6, "YELLOW cap should be 2M USDC");
        
        // Force RED tier
        riskOracle.setManualOverride(mockToken, 2); // TIER_RED
        
        // Expected cap = (1M * $1) * 0.5x = $500k
        uint256 redCap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(redCap, 500_000e6, "RED cap should be 500k USDC");
    }
    
    // ========== TEST CASE 4: Bootstrap Mode Prevents RED Tier ==========
    
    function test_BootstrapModePreventsRedTier() public {
        // Create a brand new campaign (just ended)
        address newToken = address(new MockCampaignToken("New Movie", "NEW", 100_000e18));
        
        registry.registerCampaign(
            newToken,
            owner,
            address(0), // paymentToken
            50_000e6, // floor
            200_000e6, // ceiling
            0,
            owner,
            block.timestamp - 31 days, // started 31 days ago
            block.timestamp - 1 hours // ended 1 hour ago (JUST finished)
        );
        
        registry.updateCampaignRaise(newToken, 100_000e6);
        
        // Create vault with 99% utilization (would normally be RED)
        address newVault = address(new MockUnifiedVault());
        MockUnifiedVault(newVault).setUtilization(99e16); // 99%
        registry.registerUnifiedVault(newToken, newVault);
        
        // Initialize price with volume
        priceOracle.updatePrice(newToken, 1e18, 200e6);
        
        // Check if bootstrapping
        assertTrue(riskOracle.isBootstrapping(newToken), "Should be in bootstrap mode");
        
        // Check tier - should be YELLOW, not RED
        uint8 tier = riskOracle.getRiskTier(newToken);
        assertEq(tier, 1, "Should be YELLOW tier during bootstrap, not RED");
        
        // Cap should use YELLOW multiplier (2x)
        uint256 cap = riskOracle.getRecommendedSupplyCap(newToken);
        assertEq(cap, 200_000e6, "Bootstrap cap should be 200k USDC (2x)");
    }
    
    function test_BootstrapModeExitsAfter30Days() public {
        // Create campaign that ended 31 days ago
        address oldToken = address(new MockCampaignToken("Old Movie", "OLD", 100_000e18));
        
        registry.registerCampaign(
            oldToken,
            owner,
            address(0), // paymentToken
            50_000e6,
            200_000e6,
            0,
            owner,
            block.timestamp - 62 days,
            block.timestamp - 31 days // ended 31 days ago
        );
        
        registry.updateCampaignRaise(oldToken, 100_000e6);
        priceOracle.updatePrice(oldToken, 1e18, 200e6);
        
        // Should NOT be bootstrapping
        assertFalse(riskOracle.isBootstrapping(oldToken), "Should NOT be in bootstrap mode after 30 days");
    }
    
    function test_BootstrapModeExitsWithHighVolume() public {
        // Create new campaign
        address newToken = address(new MockCampaignToken("Popular Movie", "POP", 100_000e18));
        
        registry.registerCampaign(
            newToken,
            owner,
            address(0), // paymentToken
            50_000e6,
            200_000e6,
            0,
            owner,
            block.timestamp - 10 days,
            block.timestamp - 1 hours
        );
        
        registry.updateCampaignRaise(newToken, 100_000e6);
        
        // Initialize with HIGH volume (above 10k threshold)
        priceOracle.updatePrice(newToken, 1e18, 15_000e6); // 15k USDC volume
        
        // Should NOT be bootstrapping due to high volume
        assertFalse(riskOracle.isBootstrapping(newToken), "Should exit bootstrap with high volume");
    }
    
    // ========== TEST CASE 5: Fallback to totalRaised ==========
    
    function test_FallbackToTotalRaisedWhenOracleUnavailable() public {
        // Create token without price oracle initialization
        address unpricedToken = address(new MockCampaignToken("Unpriced", "UNPRICE", 500_000e18));
        
        registry.registerCampaign(
            unpricedToken,
            owner,
            address(0), // paymentToken
            250_000e6,
            1_000_000e6,
            0,
            owner,
            block.timestamp - 5 days,
            block.timestamp + 25 days
        );
        
        registry.updateCampaignRaise(unpricedToken, 500_000e6); // 500k raised
        
        // Cap should fall back to totalRaised * multiplier
        // GREEN tier: 500k * 5x = 2.5M
        uint256 cap = riskOracle.getRecommendedSupplyCap(unpricedToken);
        assertEq(cap, 2_500_000e6, "Should fallback to totalRaised-based cap");
    }
    
    // ========== TEST CASE 6: Market Cap Calculation ==========
    
    function test_MarketCapCalculation() public {
        // Price = $1, Supply = 1M tokens
        uint256 marketCap = riskOracle.getMarketCap(mockToken);
        assertEq(marketCap, 1_000_000e6, "Market cap should be 1M USDC");
        
        // Advance time
        vm.warp(block.timestamp + 6 minutes);
        
        // Price = $2.50
        priceOracle.updatePrice(mockToken, 25e17, 2500e6);
        marketCap = riskOracle.getMarketCap(mockToken);
        assertEq(marketCap, 2_500_000e6, "Market cap should be 2.5M USDC");
    }
    
    // ========== TEST CASE 7: Edge Cases ==========
    
    function test_MinimumCapWhenNoData() public {
        address emptyToken = address(new MockCampaignToken("Empty", "EMPTY", 0));
        
        registry.registerCampaign(
            emptyToken,
            owner,
            address(0), // paymentToken
            0,
            0,
            0,
            owner,
            block.timestamp,
            block.timestamp + 30 days
        );
        
        // Should return minimum safe cap
        uint256 cap = riskOracle.getRecommendedSupplyCap(emptyToken);
        assertEq(cap, 100_000e6, "Should return 100k minimum cap");
    }
    
    function test_CapRespectsCeiling() public {
        // Set low ceiling
        riskOracle.setAssetBaseCap(mockToken, 1_000_000e6); // 1M ceiling
        
        // Advance time
        vm.warp(block.timestamp + 6 minutes);
        
        // Price = $10 (would give 50M cap without ceiling)
        priceOracle.updatePrice(mockToken, 10e18, 10000e6);
        
        // Should be capped at ceiling
        uint256 cap = riskOracle.getRecommendedSupplyCap(mockToken);
        assertEq(cap, 1_000_000e6, "Should respect 1M ceiling");
    }
}

// ========== MOCK CONTRACTS ==========

contract MockCampaignToken is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract MockUnifiedVault {
    uint256 private utilization = 50e16; // 50% default
    
    function getUtilization() external view returns (uint256) {
        return utilization;
    }
    
    function setUtilization(uint256 _util) external {
        utilization = _util;
    }
    
    function getBadDebt() external pure returns (uint256) {
        return 0;
    }
}
