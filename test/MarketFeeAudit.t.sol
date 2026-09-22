// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/MarketMulticall.sol";
import "../src/Registry.sol";
import "../src/MinimumERC20.sol";
import "../src/TestUSDC.sol";
import "../src/FeeDistributor.sol";
import "../src/Contest.sol";
import "../src/logic/TierLogic.sol";
import "../src/storage/VolumeTracker.sol";
import "../src/interfaces/ITierLogic.sol";

/**
 * @title MarketFeeAuditTest
 * @notice Comprehensive audit tests for Market fee functionality
 * @dev Tests:
 * 1. UI fee can be added to transactions
 * 2. Platform fee (2.5%) is charged correctly
 * 3. Volume-based discounts are applied correctly
 */
contract MarketFeeAuditTest is Test {
    Market public market;
    MarketMulticall public marketMulticall;
    Registry public registry;
    MinimumERC20 public tokenImpl;
    MinimumERC20 public token;
    TestUSDC public usdc;
    FeeDistributor public feeDistributor;
    Contest public contest;
    
    address public owner = address(1);
    address public feeSafe = address(2);
    address public buyer = address(3);
    address public seller = address(4);
    address public integrator = address(5); // UI fee receiver
    address public keeper = address(6); // Keeper with tier discount
    
    uint256 constant INITIAL_BALANCE = 10_000_000e6; // 10M USDC for volume generation
    uint256 constant INITIAL_TOKENS = 100_000e6;
    uint256 constant TRADE_FEE_BPS = 250; // 2.5%
    uint256 constant FEE_DENOMINATOR = 10000;
    
    // Keeper tier constants from Registry
    uint8 constant TIER_NONE = 0;
    uint8 constant TIER_BRONZE = 1;
    uint8 constant TIER_SILVER = 2;
    uint8 constant TIER_GOLD = 3;
    
    function setUp() public {
        vm.startPrank(owner);
        
        usdc = new TestUSDC(owner);
        
        // Deploy Registry as upgradeable proxy
        Registry registryImpl = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        address proxy = address(new ERC1967Proxy(address(registryImpl), initData));
        registry = Registry(proxy);
        
        tokenImpl = new MinimumERC20();
        
        // Deploy both Market and MarketMulticall
        market = new Market(owner, address(registry), TRADE_FEE_BPS);
        marketMulticall = new MarketMulticall(owner, address(registry), TRADE_FEE_BPS);
        
        contest = new Contest(owner, address(registry));
        feeDistributor = new FeeDistributor(owner, address(registry));
        
        registry.setUsdc(address(usdc));
        registry.setFeeSafe(feeSafe);
        registry.setMarket(address(market));
        registry.setContest(address(contest));
        registry.setFeeDistributor(address(feeDistributor));
        registry.setAuthorizedContract(address(market), true);
        registry.setAuthorizedContract(address(marketMulticall), true);
        
        // Allow Market to track volume in Contest
        contest.setSource(address(market), true);
        
        market.setAcceptedPaymentToken(address(usdc), true);
        marketMulticall.setAcceptedPaymentToken(address(usdc), true);
        
        token = MinimumERC20(Clones.clone(address(tokenImpl)));
        token.initialize("Test Token", "TEST", address(this));
        
        registry.registerCampaign(
            address(token),
            owner,
            address(usdc),
            1000e6,
            5000e6,
            1,
            owner,
            block.timestamp,
            block.timestamp + 30 days
        );
        registry.enableMarket(address(token));
        
        vm.stopPrank();
        
        // Fund accounts
        vm.prank(owner);
        usdc.mint(buyer, INITIAL_BALANCE);
        vm.prank(owner);
        usdc.mint(keeper, INITIAL_BALANCE);
        
        vm.prank(address(this));
        token.mint(seller, INITIAL_TOKENS);
    }

    // ===========================================
    // TEST 1: UI FEE FUNCTIONALITY
    // ===========================================
    
    function test_SetUiFeeFactor() public {
        // Integrator sets their UI fee factor (max 50 bps = 0.5%)
        vm.prank(integrator);
        market.setUiFeeFactor(50); // 0.5%
        
        assertEq(market.uiFeeFactor(integrator), 50);
    }
    
    function test_SetUiFeeFactor_MaxLimit() public {
        // Try to set above max (should fail)
        vm.prank(integrator);
        vm.expectRevert("UI fee too high");
        market.setUiFeeFactor(51); // 0.51% - above 0.5% max
    }
    
    function test_FillSellOffer_WithUiFee() public {
        // Setup: Integrator registers 0.5% UI fee
        vm.prank(integrator);
        market.setUiFeeFactor(50); // 0.5%
        
        // Seller creates offer: 1000 tokens @ 1 USDC each
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6; // 1 USDC
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 offerId = 1;
        
        // Calculate expected amounts
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6; // 1000 USDC
        uint256 expectedProtocolFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // 25 USDC (2.5%)
        uint256 expectedUiFee = (totalPrice * 50) / FEE_DENOMINATOR; // 5 USDC (0.5%)
        uint256 expectedSellerReceives = totalPrice; // 1000 USDC (no deduction for sell offers)
        uint256 expectedBuyerPays = totalPrice + expectedProtocolFee + expectedUiFee; // 1030 USDC
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        
        // Buyer fills offer with UI fee going to integrator
        vm.startPrank(buyer);
        usdc.approve(address(market), expectedBuyerPays);
        market.fillSellOffer(offerId, tokenAmount, integrator);
        vm.stopPrank();
        
        // Verify balances
        uint256 buyerBalanceAfter = usdc.balanceOf(buyer);
        uint256 sellerBalanceAfter = usdc.balanceOf(seller);
        uint256 integratorBalanceAfter = usdc.balanceOf(integrator);
        
        assertEq(buyerBalanceBefore - buyerBalanceAfter, expectedBuyerPays, "Buyer should pay price + fees");
        assertEq(sellerBalanceAfter - sellerBalanceBefore, expectedSellerReceives, "Seller should receive full price");
        assertEq(integratorBalanceAfter - integratorBalanceBefore, expectedUiFee, "Integrator should receive UI fee");
        assertEq(token.balanceOf(buyer), tokenAmount, "Buyer should receive tokens");
    }
    
    function test_FillBuyOffer_WithUiFee() public {
        // Setup: Integrator registers 0.5% UI fee
        vm.prank(integrator);
        market.setUiFeeFactor(50); // 0.5%
        
        // Buyer creates buy offer: 1000 tokens @ 1 USDC each
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6; // 1 USDC
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6; // 1000 USDC
        
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice);
        market.createBuyOffer(address(token), address(usdc), tokenAmount, pricePerToken, false);
        vm.stopPrank();
        
        uint256 offerId = 1;
        
        // Calculate expected amounts
        uint256 expectedProtocolFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // 25 USDC (2.5%)
        uint256 expectedUiFee = (totalPrice * 50) / FEE_DENOMINATOR; // 5 USDC (0.5%)
        uint256 expectedSellerReceives = totalPrice - expectedProtocolFee - expectedUiFee; // 970 USDC
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        
        // Seller fills buy offer with UI fee going to integrator
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.fillBuyOffer(offerId, tokenAmount, integrator);
        vm.stopPrank();
        
        // Verify balances
        uint256 sellerBalanceAfter = usdc.balanceOf(seller);
        uint256 integratorBalanceAfter = usdc.balanceOf(integrator);
        
        assertEq(sellerBalanceAfter - sellerBalanceBefore, expectedSellerReceives, "Seller should receive price minus fees");
        assertEq(integratorBalanceAfter - integratorBalanceBefore, expectedUiFee, "Integrator should receive UI fee");
        assertEq(token.balanceOf(buyer), tokenAmount, "Buyer should receive tokens");
    }
    
    function test_FillSellOffer_NoUiFee_WhenZeroAddress() public {
        // Seller creates offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        uint256 expectedProtocolFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        uint256 expectedBuyerPays = totalPrice + expectedProtocolFee;
        
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        
        // Fill with zero address (no UI fee)
        vm.startPrank(buyer);
        usdc.approve(address(market), expectedBuyerPays);
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify no UI fee was paid
        uint256 integratorBalanceAfter = usdc.balanceOf(integrator);
        assertEq(integratorBalanceAfter, integratorBalanceBefore, "No UI fee when address(0)");
    }
    
    function test_FillSellOffer_NoUiFee_WhenNoFactorSet() public {
        // Don't set UI fee factor for integrator
        
        // Seller creates offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        uint256 expectedProtocolFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        uint256 expectedBuyerPays = totalPrice + expectedProtocolFee;
        
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        
        // Try to fill with integrator that has no fee factor set
        vm.startPrank(buyer);
        usdc.approve(address(market), expectedBuyerPays);
        market.fillSellOffer(1, tokenAmount, integrator);
        vm.stopPrank();
        
        // Verify no UI fee was paid
        uint256 integratorBalanceAfter = usdc.balanceOf(integrator);
        assertEq(integratorBalanceAfter, integratorBalanceBefore, "No UI fee when factor not set");
    }

    // ===========================================
    // TEST 2: PLATFORM FEE (2.5%) CORRECTNESS
    // ===========================================
    
    function test_PlatformFee_CorrectlyCalculated_SellOffer() public {
        // Seller creates offer: 1000 tokens @ 1 USDC each
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6; // 1000 USDC
        uint256 expectedFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // 25 USDC (2.5%)
        
        // Get initial fee data
        (uint256 totalReceivedBefore,,,,,) = feeDistributor.tokenFees(address(token));
        
        // Buyer fills offer
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice + expectedFee);
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify fee was recorded by FeeDistributor (fees are distributed immediately to multiple destinations)
        (uint256 totalReceivedAfter,,,,,) = feeDistributor.tokenFees(address(token));
        assertEq(totalReceivedAfter - totalReceivedBefore, expectedFee, "FeeDistributor should record 2.5% fee");
    }
    
    function test_PlatformFee_CorrectlyCalculated_BuyOffer() public {
        // Buyer creates buy offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice);
        market.createBuyOffer(address(token), address(usdc), tokenAmount, pricePerToken, false);
        vm.stopPrank();
        
        uint256 expectedFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // 25 USDC (2.5%)
        
        // Get initial fee data
        (uint256 totalReceivedBefore,,,,,) = feeDistributor.tokenFees(address(token));
        
        // Seller fills buy offer
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.fillBuyOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify fee was recorded by FeeDistributor
        (uint256 totalReceivedAfter,,,,,) = feeDistributor.tokenFees(address(token));
        assertEq(totalReceivedAfter - totalReceivedBefore, expectedFee, "FeeDistributor should record 2.5% fee");
    }
    
    function test_PlatformFee_FeeWhitelist_Buyer() public {
        // Add buyer to whitelist
        vm.prank(owner);
        market.setFeeWhitelist(buyer, true);
        
        // Seller creates offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        
        uint256 feeDistributorBalanceBefore = usdc.balanceOf(address(feeDistributor));
        
        // Whitelisted buyer fills - no fee
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice); // No extra for fees
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify no fee was charged
        uint256 feeDistributorBalanceAfter = usdc.balanceOf(address(feeDistributor));
        assertEq(feeDistributorBalanceAfter, feeDistributorBalanceBefore, "No fee for whitelisted buyer");
    }
    
    function test_PlatformFee_FeeWhitelist_Seller() public {
        // Add seller to whitelist
        vm.prank(owner);
        market.setFeeWhitelist(seller, true);
        
        // Seller creates offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        
        uint256 feeDistributorBalanceBefore = usdc.balanceOf(address(feeDistributor));
        
        // Buyer fills - no fee because seller is whitelisted
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice);
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify no fee was charged
        uint256 feeDistributorBalanceAfter = usdc.balanceOf(address(feeDistributor));
        assertEq(feeDistributorBalanceAfter, feeDistributorBalanceBefore, "No fee when seller is whitelisted");
    }

    // ===========================================
    // TEST 3: VOLUME-BASED DISCOUNT
    // ===========================================
    
    function test_KeeperTier_Discount_Applied() public {
        // Deploy VolumeTracker and TierLogic
        vm.startPrank(owner);
        VolumeTracker volumeTracker = new VolumeTracker(address(registry));
        registry.setVolumeTracker(address(volumeTracker));
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        // Generate volume for keeper to qualify (100k USDC for BRONZE)
        _generateKeeperVolume(keeper, 100_000e6);
        
        // Verify keeper discount
        address tierLogicAddr = registry.tierLogic();
        uint256 discount = ITierLogic(tierLogicAddr).getFeeDiscount(keeper);
        assertEq(discount, 50, "Keeper should have 50 bps discount");
        
        // Create fresh sell offer (use a new seller to avoid conflicts)
        address newSeller = address(100);
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.prank(address(this));
        token.mint(newSeller, tokenAmount);
        
        vm.startPrank(newSeller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = 1000e6;
        // 2.5% - 0.5% discount = 2.0% protocol fee
        uint256 expectedFeeWithDiscount = (totalPrice * (TRADE_FEE_BPS - 50)) / FEE_DENOMINATOR; // 20 USDC
        
        // Get offer ID from the new seller
        uint256[] memory offers = market.getUserOffers(newSeller);
        uint256 offerId = offers[0];
        
        // Keeper fills offer (as buyer) - should get discount
        vm.startPrank(keeper);
        usdc.approve(address(market), totalPrice + expectedFeeWithDiscount);
        market.fillSellOffer(offerId, tokenAmount, address(0));
        vm.stopPrank();
    }
    
    function test_KeeperTier_Discount_NotApplied_WithoutVolume() public {
        // Deploy VolumeTracker and TierLogic
        vm.startPrank(owner);
        VolumeTracker volumeTracker = new VolumeTracker(address(registry));
        registry.setVolumeTracker(address(volumeTracker));
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        // DON'T generate volume - keeper doesn't qualify
        
        // Verify no discount without volume
        address tierLogicAddr = registry.tierLogic();
        uint256 discount = ITierLogic(tierLogicAddr).getFeeDiscount(keeper);
        assertEq(discount, 0, "No discount without meeting volume requirement");
        
        // Create sell offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        uint256 expectedFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // Full 2.5%
        
        // Get initial fee data
        (uint256 totalReceivedBefore,,,,,) = feeDistributor.tokenFees(address(token));
        
        // Keeper fills but doesn't get discount (no volume)
        vm.startPrank(keeper);
        usdc.approve(address(market), totalPrice + expectedFee);
        market.fillSellOffer(1, tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify full fee was recorded
        (uint256 totalReceivedAfter,,,,,) = feeDistributor.tokenFees(address(token));
        uint256 actualFee = totalReceivedAfter - totalReceivedBefore;
        assertEq(actualFee, expectedFee, "Full fee without volume");
    }
    
    function test_KeeperTier_Silver_Discount() public {
        // Deploy VolumeTracker and TierLogic
        vm.startPrank(owner);
        VolumeTracker volumeTracker = new VolumeTracker(address(registry));
        registry.setVolumeTracker(address(volumeTracker));
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        // Generate volume for keeper to qualify (500k USDC for SILVER)
        _generateKeeperVolume(keeper, 500_000e6);
        
        // Verify keeper discount
        address tierLogicAddr = registry.tierLogic();
        uint256 discount = ITierLogic(tierLogicAddr).getFeeDiscount(keeper);
        assertEq(discount, 100, "Keeper should have 100 bps discount");
        
        // Use a fresh seller
        address newSeller = address(101);
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.prank(address(this));
        token.mint(newSeller, tokenAmount);
        
        vm.startPrank(newSeller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256[] memory offers = market.getUserOffers(newSeller);
        
        // Keeper fills with discount
        vm.startPrank(keeper);
        usdc.approve(address(market), 2000e6); // Enough for price + reduced fee
        market.fillSellOffer(offers[0], tokenAmount, address(0));
        vm.stopPrank();
    }
    
    function test_KeeperTier_Gold_Discount() public {
        // Deploy VolumeTracker and TierLogic
        vm.startPrank(owner);
        VolumeTracker volumeTracker = new VolumeTracker(address(registry));
        registry.setVolumeTracker(address(volumeTracker));
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        // Generate volume for keeper to qualify (2M USDC for GOLD)
        _generateKeeperVolume(keeper, 2_000_000e6);
        
        // Verify keeper discount
        address tierLogicAddr = registry.tierLogic();
        uint256 discount = ITierLogic(tierLogicAddr).getFeeDiscount(keeper);
        assertEq(discount, 150, "Keeper should have 150 bps discount");
        
        // Use a fresh seller
        address newSeller = address(102);
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.prank(address(this));
        token.mint(newSeller, tokenAmount);
        
        vm.startPrank(newSeller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256[] memory offers = market.getUserOffers(newSeller);
        
        // Keeper fills with discount
        vm.startPrank(keeper);
        usdc.approve(address(market), 2000e6);
        market.fillSellOffer(offers[0], tokenAmount, address(0));
        vm.stopPrank();
    }
    
    function test_KeeperTier_Discount_CappedAtZero() public {
        // Edge case: Discount shouldn't make fee negative
        // TierLogic has max 150 bps (1.5%) discount for GOLD tier
        
        vm.startPrank(owner);
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        _generateKeeperVolume(keeper, 2_000_000e6); // GOLD tier
        
        // Use a fresh seller
        address newSeller = address(103);
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.prank(address(this));
        token.mint(newSeller, tokenAmount);
        
        vm.startPrank(newSeller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256[] memory offers = market.getUserOffers(newSeller);
        uint256 totalPrice = 1000e6;
        
        // Get initial fee data
        (uint256 totalReceivedBefore,,,,,) = feeDistributor.tokenFees(address(token));
        
        // Keeper fills - should pay 0 fee (100% discount)
        // Still need to approve full amount including potential fees (though fee will be 0)
        vm.startPrank(keeper);
        usdc.approve(address(market), totalPrice + 100e6); // Approve extra to be safe
        market.fillSellOffer(offers[0], tokenAmount, address(0));
        vm.stopPrank();
        
        // Verify no protocol fee was recorded (UI fees would still apply if set)
        (uint256 totalReceivedAfter,,,,,) = feeDistributor.tokenFees(address(token));
        uint256 actualFee = totalReceivedAfter - totalReceivedBefore;
        assertEq(actualFee, 0, "Zero fee with 100% discount");
    }

    // ===========================================
    // TEST 4: PREVIEW FILL OFFER (View Function)
    // ===========================================
    
    function test_PreviewFillOffer_SellOffer() public {
        // Integrator sets UI fee
        vm.prank(integrator);
        market.setUiFeeFactor(50); // 0.5%
        
        // Create offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        // Preview the fill
        (
            uint256 actualAmount,
            uint256 totalPrice,
            uint256 protocolFee,
            uint256 uiFee,
            uint256 sellerReceives,
            uint256 buyerPays
        ) = market.previewFillOffer(1, tokenAmount, buyer, integrator);
        
        uint256 expectedTotalPrice = 1000e6;
        uint256 expectedProtocolFee = (expectedTotalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR; // 25 USDC
        uint256 expectedUiFee = (expectedTotalPrice * 50) / FEE_DENOMINATOR; // 5 USDC
        
        assertEq(actualAmount, tokenAmount, "Preview: actual amount");
        assertEq(totalPrice, expectedTotalPrice, "Preview: total price");
        assertEq(protocolFee, expectedProtocolFee, "Preview: protocol fee");
        assertEq(uiFee, expectedUiFee, "Preview: UI fee");
        assertEq(sellerReceives, expectedTotalPrice, "Preview: seller receives full price");
        assertEq(buyerPays, expectedTotalPrice + expectedProtocolFee + expectedUiFee, "Preview: buyer pays all");
    }
    
    function test_PreviewFillOffer_BuyOffer() public {
        // Integrator sets UI fee
        vm.prank(integrator);
        market.setUiFeeFactor(50);
        
        // Create buy offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        uint256 totalPrice = (tokenAmount * pricePerToken) / 1e6;
        
        vm.startPrank(buyer);
        usdc.approve(address(market), totalPrice);
        market.createBuyOffer(address(token), address(usdc), tokenAmount, pricePerToken, false);
        vm.stopPrank();
        
        // Preview filling the buy offer (seller fills)
        (
            uint256 actualAmount,
            uint256 previewTotalPrice,
            uint256 protocolFee,
            uint256 uiFee,
            uint256 sellerReceives,
            uint256 buyerPays
        ) = market.previewFillOffer(1, tokenAmount, seller, integrator);
        
        uint256 expectedTotalPrice = 1000e6;
        uint256 expectedProtocolFee = (expectedTotalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        uint256 expectedUiFee = (expectedTotalPrice * 50) / FEE_DENOMINATOR;
        
        assertEq(actualAmount, tokenAmount);
        assertEq(previewTotalPrice, expectedTotalPrice);
        assertEq(protocolFee, expectedProtocolFee);
        assertEq(uiFee, expectedUiFee);
        assertEq(sellerReceives, expectedTotalPrice - expectedProtocolFee - expectedUiFee, "Seller receives less for buy offers");
        assertEq(buyerPays, expectedTotalPrice, "Buyer already escrowed");
    }

    // ===========================================
    // TEST 5: COMBINED UI FEE + DISCOUNT
    // ===========================================
    
    function test_Combined_UiFee_And_KeeperDiscount() public {
        // Setup: Integrator with 0.5% UI fee
        vm.prank(integrator);
        market.setUiFeeFactor(50);
        
        // Setup: TierLogic with BRONZE tier 0.5% discount at 100k volume threshold
        vm.startPrank(owner);
        TierLogic tierLogic = new TierLogic(address(registry));
        registry.setTierLogic(address(tierLogic));
        vm.stopPrank();
        
        _generateKeeperVolume(keeper, 100_000e6); // BRONZE tier
        
        // Use a fresh seller
        address newSeller = address(104);
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.prank(address(this));
        token.mint(newSeller, tokenAmount);
        
        vm.startPrank(newSeller);
        token.approve(address(market), tokenAmount);
        market.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = 1000e6;
        uint256 expectedProtocolFee = (totalPrice * (TRADE_FEE_BPS - 50)) / FEE_DENOMINATOR; // 20 USDC (2.0%)
        uint256 expectedUiFee = (totalPrice * 50) / FEE_DENOMINATOR; // 5 USDC (0.5%)
        uint256 expectedTotalCost = totalPrice + expectedProtocolFee + expectedUiFee; // 1025 USDC
        
        uint256 keeperBalanceBefore = usdc.balanceOf(keeper);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        (uint256 totalReceivedBefore,,,,,) = feeDistributor.tokenFees(address(token));
        
        uint256[] memory offers = market.getUserOffers(newSeller);
        
        // Keeper fills with integrator receiving UI fee
        vm.startPrank(keeper);
        usdc.approve(address(market), expectedTotalCost);
        market.fillSellOffer(offers[0], tokenAmount, integrator);
        vm.stopPrank();
        
        // Verify all amounts
        (uint256 totalReceivedAfter,,,,,) = feeDistributor.tokenFees(address(token));
        assertEq(usdc.balanceOf(keeper), keeperBalanceBefore - expectedTotalCost, "Keeper paid correct amount");
        assertEq(usdc.balanceOf(integrator) - integratorBalanceBefore, expectedUiFee, "Integrator got UI fee");
        assertEq(totalReceivedAfter - totalReceivedBefore, expectedProtocolFee, "Protocol fee with discount recorded");
    }

    // ===========================================
    // TEST 6: MARKETMULTICALL UI FEE FUNCTIONS
    // ===========================================
    
    function test_MarketMulticall_FillWithUiFee() public {
        // Setup UI fee
        vm.prank(integrator);
        marketMulticall.setUiFeeFactor(50);
        
        // Create sell offer
        uint256 tokenAmount = 1000e6;
        uint256 pricePerToken = 1e6;
        
        vm.startPrank(seller);
        token.approve(address(marketMulticall), tokenAmount);
        marketMulticall.createSellOffer(address(token), address(usdc), tokenAmount, pricePerToken);
        vm.stopPrank();
        
        uint256 totalPrice = 1000e6;
        uint256 expectedProtocolFee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR;
        uint256 expectedUiFee = (totalPrice * 50) / FEE_DENOMINATOR;
        uint256 expectedTotal = totalPrice + expectedProtocolFee + expectedUiFee;
        
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        
        // Use fillSellOfferWithUiFee
        vm.startPrank(buyer);
        usdc.approve(address(marketMulticall), expectedTotal);
        marketMulticall.fillSellOfferWithUiFee(1, tokenAmount, integrator);
        vm.stopPrank();
        
        // Verify UI fee was paid
        assertEq(usdc.balanceOf(integrator) - integratorBalanceBefore, expectedUiFee);
    }

    // ===========================================
    // HELPER FUNCTIONS
    // ===========================================
    
    function _generateKeeperVolume(address _keeper, uint256 volume) internal {
        // Create multiple trades to generate volume for keeper
        // Each trade needs a new seller and offer
        
        uint256 tradeSize = 1000e6; // 1000 USDC per trade
        uint256 numTrades = volume / tradeSize;
        
        for (uint256 i = 0; i < numTrades; i++) {
            address tradeSeller = address(uint160(1000 + i));
            
            // Mint tokens to seller
            vm.prank(address(this));
            token.mint(tradeSeller, tradeSize);
            
            // Create offer
            vm.startPrank(tradeSeller);
            token.approve(address(market), tradeSize);
            market.createSellOffer(address(token), address(usdc), tradeSize, 1e6);
            vm.stopPrank();
            
            uint256 offerId = i + 1;
            uint256 totalPrice = tradeSize;
            uint256 fee = (totalPrice * TRADE_FEE_BPS) / FEE_DENOMINATOR;
            
            // Keeper fills as buyer (generates buying volume)
            vm.startPrank(_keeper);
            usdc.approve(address(market), totalPrice + fee);
            market.fillSellOffer(offerId, tradeSize, address(0));
            vm.stopPrank();
        }
    }
}
