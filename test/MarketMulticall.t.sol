// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/MarketMulticall.sol";
import "../src/Registry.sol";
import "../src/MinimumERC20.sol";
import "../src/TestUSDC.sol";
import "../src/FeeDistributor.sol";
import "../src/Contest.sol";

/**
 * @title MarketMulticallTest
 * @notice Comprehensive test suite for MarketMulticall functionality
 */
contract MarketMulticallTest is Test {
    MarketMulticall public market;
    Registry public registry;
    MinimumERC20 public tokenImpl;
    MinimumERC20 public token;
    TestUSDC public usdc;
    FeeDistributor public feeDistributor;
    Contest public contest;
    
    address public owner = address(1);
    address public feeSafe = address(2);
    address public buyer1 = address(3);
    address public buyer2 = address(4);
    address public seller1 = address(5);
    address public seller2 = address(6);
    address public seller3 = address(7);
    
    uint256 constant INITIAL_BALANCE = 10000e6;
    uint256 constant INITIAL_TOKENS = 10000e6;
    
    event BatchFillCompleted(
        address indexed filler,
        uint256 successCount,
        uint256 failCount,
        uint256 totalVolume
    );
    
    function setUp() public {
        vm.startPrank(owner);
        
        usdc = new TestUSDC(owner);
        registry = new Registry();
        registry.initialize(owner);
        tokenImpl = new MinimumERC20();
        
        market = new MarketMulticall(owner, address(registry), 250);
        
        contest = new Contest(owner, address(registry));
        feeDistributor = new FeeDistributor(owner, address(registry));
        
        registry.setUsdc(address(usdc));
        registry.setFeeSafe(feeSafe);
        registry.setMarket(address(market));
        registry.setContest(address(contest));
        registry.setFeeDistributor(address(feeDistributor));
        registry.setAuthorizedContract(address(market), true);
        
        market.setAcceptedPaymentToken(address(usdc), true);
        
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
        
        vm.prank(owner);
        usdc.mint(buyer1, INITIAL_BALANCE);
        vm.prank(owner);
        usdc.mint(buyer2, INITIAL_BALANCE);
        
        vm.prank(address(this));
        token.mint(seller1, INITIAL_TOKENS);
        vm.prank(address(this));
        token.mint(seller2, INITIAL_TOKENS);
        vm.prank(address(this));
        token.mint(seller3, INITIAL_TOKENS);
    }
    
    function testGetTokenOffersPaginated() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(seller1);
            token.approve(address(market), 100e6);
            market.createSellOffer(
                address(token),
                address(usdc),
                100e6,
                (1e6 + i * 10000)
            );
            vm.stopPrank();
        }
        
        (MarketMulticall.OfferDetails[] memory offers, uint256 total) = 
            market.getTokenOffersPaginated(address(token), 0, 5);
        
        assertEq(total, 10);
        assertEq(offers.length, 5);
    }
    
    function testGetOpenOffers() public {
        vm.startPrank(seller1);
        token.approve(address(market), 300e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 1.3e6);
        market.createSellOffer(address(token), address(usdc), 200e6, 1.4e6);
        vm.stopPrank();
        
        MarketMulticall.OfferDetails[] memory sellOffers = 
            market.getOpenOffers(address(token), 2, 100);
        
        assertEq(sellOffers.length, 2);
        assertEq(sellOffers[0].pricePerToken, 1.3e6);
    }
    
    function testBatchFillSellOffers() public {
        vm.startPrank(seller1);
        token.approve(address(market), 300e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 1.0e6);
        vm.stopPrank();
        
        vm.startPrank(seller2);
        token.approve(address(market), 200e6);
        market.createSellOffer(address(token), address(usdc), 200e6, 1.1e6);
        vm.stopPrank();
        
        MarketMulticall.FillRequest[] memory requests = new MarketMulticall.FillRequest[](2);
        requests[0] = MarketMulticall.FillRequest({offerId: 1, tokenAmount: 100e6});
        requests[1] = MarketMulticall.FillRequest({offerId: 2, tokenAmount: 200e6});
        
        uint256 totalCost = (100e6 * 1.0e6 / 1e6) + (200e6 * 1.1e6 / 1e6);
        uint256 totalFee = totalCost * 250 / 10000;
        
        vm.startPrank(buyer1);
        usdc.approve(address(market), totalCost + totalFee);
        
        MarketMulticall.FillResult[] memory results = market.batchFillSellOffers(requests);
        vm.stopPrank();
        
        assertTrue(results[0].success);
        assertTrue(results[1].success);
        assertEq(token.balanceOf(buyer1), 300e6);
    }
    
    function testBatchFillWithPartialFailure() public {
        vm.startPrank(seller1);
        token.approve(address(market), 200e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 1.0e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 1.1e6);
        vm.stopPrank();
        
        vm.startPrank(buyer2);
        usdc.approve(address(market), 200e6);
        market.fillSellOffer(1, 100e6, address(0));
        vm.stopPrank();
        
        MarketMulticall.FillRequest[] memory requests = new MarketMulticall.FillRequest[](2);
        requests[0] = MarketMulticall.FillRequest({offerId: 1, tokenAmount: 100e6});
        requests[1] = MarketMulticall.FillRequest({offerId: 2, tokenAmount: 100e6});
        
        vm.startPrank(buyer1);
        usdc.approve(address(market), 300e6);
        
        MarketMulticall.FillResult[] memory results = market.batchFillSellOffers(requests);
        vm.stopPrank();
        
        assertFalse(results[0].success);
        assertTrue(results[1].success);
    }
}
