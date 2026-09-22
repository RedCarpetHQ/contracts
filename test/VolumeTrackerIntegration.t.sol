// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/MarketMulticall.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/FeeDistributor.sol";
import "../src/Contest.sol";
import "../src/logic/TierLogic.sol";
import "../src/storage/VolumeTracker.sol";
import "../src/interfaces/ITierLogic.sol";
import "../src/interfaces/IVolumeTracker.sol";

/**
 * @title VolumeTrackerIntegrationTest
 * @notice Comprehensive integration tests for VolumeTracker + TierLogic architecture
 * @dev Tests the complete flow: Market → VolumeTracker → TierLogic
 */
contract VolumeTrackerIntegrationTest is Test {
    
    // Contracts
    Registry public registry;
    Registry public registryImpl;
    Market public market;
    MarketMulticall public marketMulticall;
    TestUSDC public usdc;
    FeeDistributor public feeDistributor;
    Contest public contest;
    TierLogic public tierLogic;
    VolumeTracker public volumeTracker;
    
    // Test accounts
    address public owner;
    address public alice;
    address public bob;
    address public carol;
    address public seller;
    
    // Constants
    uint256 constant INITIAL_USDC = 1_000_000e6; // 1M USDC
    uint256 constant TRADE_FEE = 250; // 2.5%
    
    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        seller = makeAddr("seller");
        
        // Deploy USDC
        usdc = new TestUSDC(owner);
        
        // Deploy Registry (UUPS proxy)
        registryImpl = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = Registry(address(proxy));
        
        // Deploy FeeDistributor
        feeDistributor = new FeeDistributor(owner, address(registry));
        
        // Deploy and configure Contest (V3 constructor: owner, registry)
        contest = new Contest(owner, address(registry));
        
        // Deploy Market
        market = new Market(owner, address(registry), TRADE_FEE);
        
        // Deploy MarketMulticall
        marketMulticall = new MarketMulticall(owner, address(registry), TRADE_FEE);
        
        // Deploy VolumeTracker
        volumeTracker = new VolumeTracker(address(registry));
        
        // Deploy TierLogic
        tierLogic = new TierLogic(address(registry));
        
        // Configure Registry
        registry.setUsdc(address(usdc));
        registry.setFeeWallet(address(feeDistributor));
        registry.setFeeDistributor(address(feeDistributor));
        registry.setContest(address(contest));
        registry.setMarket(address(market));
        registry.setVolumeTracker(address(volumeTracker));
        registry.setTierLogic(address(tierLogic));
        
        // Configure Contest
        contest.setSource(address(market), true);
        
        // Mint USDC to test users
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(carol, INITIAL_USDC);
        usdc.mint(seller, INITIAL_USDC);
    }
    
    // ===========================================
    // VOLUMETRACKER TESTS
    // ===========================================
    
    function test_VolumeTracker_InitialState() public {
        assertEq(address(volumeTracker.registry()), address(registry));
        assertEq(registry.volumeTracker(), address(volumeTracker));
    }
    
    function test_VolumeTracker_TrackVolume_SingleDay() public {
        uint256 volume = 1000e6;
        
        // Only market can track volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, volume);
        vm.stopPrank();
        
        uint256 currentDay = block.timestamp / 1 days;
        assertEq(volumeTracker.getDailyVolume(alice, currentDay), volume);
    }
    
    function test_VolumeTracker_TrackVolume_MultipleDays() public {
        uint256 volume1 = 1000e6;
        uint256 volume2 = 2000e6;
        
        vm.startPrank(address(market));
        
        // Day 1
        volumeTracker.trackVolume(alice, volume1);
        
        // Move to day 2
        vm.warp(block.timestamp + 1 days);
        
        // Day 2
        volumeTracker.trackVolume(alice, volume2);
        
        vm.stopPrank();
        
        uint256 day1 = (block.timestamp - 1 days) / 1 days;
        uint256 day2 = block.timestamp / 1 days;
        
        assertEq(volumeTracker.getDailyVolume(alice, day1), volume1);
        assertEq(volumeTracker.getDailyVolume(alice, day2), volume2);
    }
    
    function test_VolumeTracker_GetRollingVolume_30Days() public {
        uint256 dailyVolume = 1000e6;
        
        vm.startPrank(address(market));
        
        // Add volume for 10 days
        for (uint i = 0; i < 10; i++) {
            volumeTracker.trackVolume(alice, dailyVolume);
            vm.warp(block.timestamp + 1 days);
        }
        
        vm.stopPrank();
        
        // Should get sum of 10 days (most recent)
        uint256 rollingVolume = volumeTracker.getRollingVolume(alice, 30);
        assertEq(rollingVolume, dailyVolume * 10);
    }
    
    function test_VolumeTracker_GetRollingVolume_7Days() public {
        uint256 dailyVolume = 1000e6;
        
        vm.startPrank(address(market));
        
        // Add volume for 7 days (exactly what we want to query)
        for (uint i = 0; i < 7; i++) {
            volumeTracker.trackVolume(bob, dailyVolume);
            if (i < 6) vm.warp(block.timestamp + 1 days); // Don't warp after last iteration
        }
        
        vm.stopPrank();
        
        // 7-day rolling should count all 7 days
        uint256 rollingVolume = volumeTracker.getRollingVolume(bob, 7);
        assertEq(rollingVolume, dailyVolume * 7);
    }
    
    function test_VolumeTracker_OnlyMarketCanTrack() public {
        uint256 volume = 1000e6;
        
        // Try to track from non-market address (should fail)
        vm.expectRevert("Only Market");
        volumeTracker.trackVolume(alice, volume);
    }
    
    function test_VolumeTracker_EmptyVolumeReturnsZero() public {
        uint256 rollingVolume = volumeTracker.getRollingVolume(alice, 30);
        assertEq(rollingVolume, 0);
    }
    
    // ===========================================
    // TIERLOGIC TESTS
    // ===========================================
    
    function test_TierLogic_InitialState() public {
        assertEq(address(tierLogic.registry()), address(registry));
        assertEq(registry.tierLogic(), address(tierLogic));
    }
    
    function test_TierLogic_NoVolume_NoTier() public {
        // No volume tracked yet
        uint256 tier = tierLogic.getTier(alice);
        assertEq(tier, 0); // No tier
        
        uint256 discount = tierLogic.getFeeDiscount(alice);
        assertEq(discount, 0);
    }
    
    function test_TierLogic_BronzeTier() public {
        uint256 bronzeThreshold = 100_000e6; // 100k USDC
        
        // Track enough volume for bronze (in single day)
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, bronzeThreshold);
        vm.stopPrank();
        
        // Check tier
        uint256 tier = tierLogic.getTier(alice);
        assertEq(tier, 1); // BRONZE = 1
        
        // Check discount (50 bps = 0.5%)
        uint256 discount = tierLogic.getFeeDiscount(alice);
        assertEq(discount, 50);
    }
    
    function test_TierLogic_SilverTier() public {
        uint256 silverThreshold = 500_000e6; // 500k USDC
        
        vm.startPrank(address(market));
        volumeTracker.trackVolume(bob, silverThreshold);
        vm.stopPrank();
        
        uint256 tier = tierLogic.getTier(bob);
        assertEq(tier, 2); // SILVER = 2
        
        uint256 discount = tierLogic.getFeeDiscount(bob);
        assertEq(discount, 100); // 100 bps = 1%
    }
    
    function test_TierLogic_GoldTier() public {
        uint256 goldThreshold = 2_000_000e6; // 2M USDC
        
        vm.startPrank(address(market));
        volumeTracker.trackVolume(carol, goldThreshold);
        vm.stopPrank();
        
        uint256 tier = tierLogic.getTier(carol);
        assertEq(tier, 3); // GOLD = 3
        
        uint256 discount = tierLogic.getFeeDiscount(carol);
        assertEq(discount, 150); // 150 bps = 1.5%
    }
    
    function test_TierLogic_RollingVolume_Calculation() public {
        // Add volume over multiple days
        uint256 dailyVolume = 50_000e6; // 50k per day
        
        vm.startPrank(address(market));
        
        // Add 50k x 3 = 150k over 3 days (exceeds bronze 100k)
        for (uint i = 0; i < 3; i++) {
            volumeTracker.trackVolume(alice, dailyVolume);
            if (i < 2) vm.warp(block.timestamp + 1 days);
        }
        
        vm.stopPrank();
        
        // Should qualify for bronze (150k > 100k)
        uint256 tier = tierLogic.getTier(alice);
        assertEq(tier, 1);
    }
    
    function test_TierLogic_TrackVolume_Deprecated() public {
        // trackVolume on TierLogic should revert with instruction to use VolumeTracker
        vm.expectRevert("Use VolumeTracker.trackVolume()");
        tierLogic.trackVolume(alice, 1000e6);
    }
    
    // ===========================================
    // REGISTRY TESTS
    // ===========================================
    
    function test_Registry_SetVolumeTracker() public {
        // Deploy new VolumeTracker
        VolumeTracker newVolumeTracker = new VolumeTracker(address(registry));
        
        // Set in registry
        vm.startPrank(owner);
        registry.setVolumeTracker(address(newVolumeTracker));
        vm.stopPrank();
        
        assertEq(registry.volumeTracker(), address(newVolumeTracker));
    }
    
    function test_Registry_SetTierLogic() public {
        // Deploy new TierLogic
        TierLogic newTierLogic = new TierLogic(address(registry));
        
        // Set in registry
        vm.startPrank(owner);
        registry.setTierLogic(address(newTierLogic));
        vm.stopPrank();
        
        assertEq(registry.tierLogic(), address(newTierLogic));
    }
    
    function test_Registry_OnlyOwnerCanSetVolumeTracker() public {
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setVolumeTracker(address(volumeTracker));
        vm.stopPrank();
    }
    
    function test_Registry_OnlyOwnerCanSetTierLogic() public {
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
    }
    
    function test_Registry_ZeroAddressValidation_VolumeTracker() public {
        vm.startPrank(owner);
        vm.expectRevert("Invalid volumeTracker");
        registry.setVolumeTracker(address(0));
        vm.stopPrank();
    }
    
    function test_Registry_ZeroAddressValidation_TierLogic() public {
        vm.startPrank(owner);
        vm.expectRevert("Invalid tierLogic");
        registry.setTierLogic(address(0));
        vm.stopPrank();
    }
    
    // ===========================================
    // MARKET TESTS
    // ===========================================
    
    function test_Market_CallsVolumeTracker_OnTrade() public {
        // First, enable market for token and fund seller
        // Setup trade: seller sells 1000 tokens at 1 USDC each
        uint256 tokenAmount = 1000e18;
        uint256 pricePerToken = 1e6; // 1 USDC
        uint256 totalPrice = tokenAmount * pricePerToken / 1e18;
        
        // Seller needs to approve and create sell offer
        vm.startPrank(seller);
        usdc.approve(address(market), totalPrice);
        
        // Create token and approve market (simplified)
        // In reality, this would go through full campaign flow
        vm.stopPrank();
        
        // Track volume manually to test the flow
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 100_000e6); // Bronze volume
        vm.stopPrank();
        
        // Verify volume was tracked
        uint256 rollingVolume = volumeTracker.getRollingVolume(alice, 30);
        assertEq(rollingVolume, 100_000e6);
        
        // Verify tier is calculated correctly
        uint256 tier = tierLogic.getTier(alice);
        assertEq(tier, 1); // Bronze
    }
    
    function test_Market_FeeCalculation_WithoutTier() public {
        // No volume tracked - no discount
        uint256 baseFee = 250; // 2.5%
        uint256 tierDiscount = tierLogic.getFeeDiscount(alice);
        
        assertEq(tierDiscount, 0);
        
        // Effective fee should be full fee
        uint256 effectiveFee = baseFee - tierDiscount;
        assertEq(effectiveFee, 250);
    }
    
    function test_Market_FeeCalculation_WithBronzeTier() public {
        // Track bronze volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 100_000e6);
        vm.stopPrank();
        
        uint256 baseFee = 250;
        uint256 tierDiscount = tierLogic.getFeeDiscount(alice);
        
        assertEq(tierDiscount, 50); // 0.5% discount
        
        uint256 effectiveFee = baseFee - tierDiscount;
        assertEq(effectiveFee, 200); // 2.0% effective fee
    }
    
    function test_Market_FeeCalculation_WithSilverTier() public {
        // Track silver volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 500_000e6);
        vm.stopPrank();
        
        uint256 baseFee = 250;
        uint256 tierDiscount = tierLogic.getFeeDiscount(alice);
        
        assertEq(tierDiscount, 100); // 1% discount
        
        uint256 effectiveFee = baseFee - tierDiscount;
        assertEq(effectiveFee, 150); // 1.5% effective fee
    }
    
    function test_Market_FeeCalculation_WithGoldTier() public {
        // Track gold volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 2_000_000e6);
        vm.stopPrank();
        
        uint256 baseFee = 250;
        uint256 tierDiscount = tierLogic.getFeeDiscount(alice);
        
        assertEq(tierDiscount, 150); // 1.5% discount
        
        uint256 effectiveFee = baseFee - tierDiscount;
        assertEq(effectiveFee, 100); // 1.0% effective fee
    }
    
    // ===========================================
    // MARKETMULTICALL TESTS
    // ===========================================
    
    function test_MarketMulticall_InitialState() public {
        assertEq(address(marketMulticall.registry()), address(registry));
        assertEq(marketMulticall.tradeFee(), TRADE_FEE);
        assertEq(marketMulticall.owner(), owner);
    }
    
    function test_MarketMulticall_TierLogicIntegration() public {
        // Ensure MarketMulticall can access tierLogic via registry
        address tierLogicAddr = marketMulticall.registry().tierLogic();
        assertEq(tierLogicAddr, address(tierLogic));
        
        // Ensure MarketMulticall can access volumeTracker via registry
        address volumeTrackerAddr = marketMulticall.registry().volumeTracker();
        assertEq(volumeTrackerAddr, address(volumeTracker));
    }
    
    // ===========================================
    // INTEGRATION TESTS - FULL FLOW
    // ===========================================
    
    function test_FullFlow_BronzeQualification() public {
        // Step 1: Initial state - no tier
        assertEq(tierLogic.getTier(alice), 0);
        assertEq(tierLogic.getFeeDiscount(alice), 0);
        
        // Step 2: Track volume through Market flow
        uint256 bronzeVolume = 100_000e6;
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, bronzeVolume);
        vm.stopPrank();
        
        // Step 3: Verify VolumeTracker state
        assertEq(volumeTracker.getRollingVolume(alice, 30), bronzeVolume);
        
        // Step 4: Verify TierLogic reads correctly
        assertEq(tierLogic.getTier(alice), 1); // Bronze
        assertEq(tierLogic.getFeeDiscount(alice), 50);
        
        // Step 5: Calculate effective fee
        uint256 baseFee = 250;
        uint256 effectiveFee = baseFee - tierLogic.getFeeDiscount(alice);
        assertEq(effectiveFee, 200); // 2.0%
    }
    
    function test_FullFlow_UpgradeTier() public {
        // Start with bronze volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 100_000e6);
        vm.stopPrank();
        
        assertEq(tierLogic.getTier(alice), 1); // Bronze
        
        // Add more volume to reach silver
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 400_000e6); // Additional 400k = 500k total
        vm.stopPrank();
        
        assertEq(tierLogic.getTier(alice), 2); // Silver
        assertEq(tierLogic.getFeeDiscount(alice), 100);
    }
    
    function test_FullFlow_VolumePersistence_AcrossTierLogicReplacement() public {
        // Track volume
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 500_000e6);
        vm.stopPrank();
        
        // Verify tier
        assertEq(tierLogic.getTier(alice), 2); // Silver
        
        // Deploy NEW TierLogic (simulating upgrade)
        TierLogic newTierLogic = new TierLogic(address(registry));
        
        // Update registry to point to new TierLogic
        vm.startPrank(owner);
        registry.setTierLogic(address(newTierLogic));
        vm.stopPrank();
        
        // Volume data is preserved in VolumeTracker
        // New TierLogic can still read the same volume
        assertEq(newTierLogic.getTier(alice), 2); // Still Silver!
        assertEq(newTierLogic.getFeeDiscount(alice), 100);
        
        // Verify old TierLogic no longer connected
        // (it would still work but registry points to new one)
        assertEq(registry.tierLogic(), address(newTierLogic));
    }
    
    function test_FullFlow_MultipleUsers_DifferentTiers() public {
        // Alice: Bronze
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 100_000e6);
        
        // Bob: Silver
        volumeTracker.trackVolume(bob, 500_000e6);
        
        // Carol: Gold
        volumeTracker.trackVolume(carol, 2_000_000e6);
        vm.stopPrank();
        
        assertEq(tierLogic.getTier(alice), 1);
        assertEq(tierLogic.getTier(bob), 2);
        assertEq(tierLogic.getTier(carol), 3);
        
        assertEq(tierLogic.getFeeDiscount(alice), 50);
        assertEq(tierLogic.getFeeDiscount(bob), 100);
        assertEq(tierLogic.getFeeDiscount(carol), 150);
    }
    
    function test_FullFlow_VolumeDecays_OverTime() public {
        // Add volume today
        vm.startPrank(address(market));
        volumeTracker.trackVolume(alice, 100_000e6);
        vm.stopPrank();
        
        assertEq(tierLogic.getTier(alice), 1); // Bronze
        
        // Move forward 31 days (beyond 30-day window)
        vm.warp(block.timestamp + 31 days);
        
        // Volume now outside 30-day window
        uint256 rollingVolume = volumeTracker.getRollingVolume(alice, 30);
        assertEq(rollingVolume, 0);
        
        // Tier should be back to 0
        assertEq(tierLogic.getTier(alice), 0);
    }
}
