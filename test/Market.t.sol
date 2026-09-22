// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/Market.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "../src/HybridPriceOracle.sol";

contract MarketTest is Test {
    Market public market;
    Registry public registry;
    HybridPriceOracle public priceOracle;
    TestUSDC public usdc;
    
    address public owner = address(1);
    address public campaign = address(2);
    address public seller = address(3);
    address public buyer = address(4);
    
    function setUp() public {
        vm.startPrank(owner);
        
        registry = new Registry();
        registry.initialize(owner);
        usdc = new TestUSDC(owner);
        priceOracle = new HybridPriceOracle(owner);
        market = new Market(owner, address(registry), 250); // 2.5% fee
        
        registry.setUsdc(address(usdc));
        registry.setMarket(address(market));
        registry.setHybridPriceOracle(address(priceOracle));
        
        priceOracle.setRegistry(address(registry));
        priceOracle.setAuthorizedUpdater(address(market), true);
        
        vm.stopPrank();
        
        // Fund buyer
        vm.prank(owner);
        usdc.mint(buyer, 10_000e6);
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        vm.startPrank(campaign);
        MinimumERC20 token = new MinimumERC20();
        token.initialize("Test Token", "TEST", campaign);
        token.mint(seller, 1000e6);
        vm.stopPrank();
        return token;
    }
    
    function test_CreateSellOffer() public {
        MinimumERC20 token = _deployToken();
        
        vm.startPrank(seller);
        token.approve(address(market), 100e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 0.1e18);
        vm.stopPrank();
        
        // Verify offer was created by checking user offers
        uint256[] memory offers = market.getUserOffers(seller);
        assertGt(offers.length, 0);
    }
    
    function test_FillSellOffer() public {
        MinimumERC20 token = _deployToken();
        
        // Seller creates sell offer
        vm.startPrank(seller);
        token.approve(address(market), 100e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 0.1e18);
        vm.stopPrank();
        
        // Get the offer ID
        uint256[] memory offers = market.getUserOffers(seller);
        uint256 offerId = offers[0];
        
        // Buyer fills offer
        vm.startPrank(buyer);
        usdc.approve(address(market), 20e6); // 100 tokens * 0.1 USDC + fees
        market.fillSellOffer(offerId, 100e6, address(0));
        vm.stopPrank();
        
        assertEq(token.balanceOf(buyer), 100e6);
    }
    
    function test_CancelOffer() public {
        MinimumERC20 token = _deployToken();
        
        vm.startPrank(seller);
        token.approve(address(market), 100e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 0.1e18);
        
        uint256[] memory offers = market.getUserOffers(seller);
        uint256 offerId = offers[0];
        
        market.cancelOffer(offerId);
        vm.stopPrank();
        
        // Verify offer was cancelled by checking it can't be filled
        vm.startPrank(buyer);
        usdc.approve(address(market), 20e6);
        vm.expectRevert();
        market.fillSellOffer(offerId, 100e6, address(0));
        vm.stopPrank();
    }
    
    function test_CreateBuyOffer() public {
        MinimumERC20 token = _deployToken();
        
        vm.startPrank(buyer);
        usdc.approve(address(market), 20e6);
        market.createBuyOffer(address(token), address(usdc), 100e6, 0.1e18, false);
        vm.stopPrank();
        
        // Verify offer was created
        uint256[] memory offers = market.getUserOffers(buyer);
        assertGt(offers.length, 0);
    }
    
    function test_GetOffer() public {
        MinimumERC20 token = _deployToken();
        
        vm.startPrank(seller);
        token.approve(address(market), 100e6);
        market.createSellOffer(address(token), address(usdc), 100e6, 0.1e18);
        vm.stopPrank();
        
        // Get offer ID and verify we can retrieve offer data
        uint256[] memory offers = market.getUserOffers(seller);
        market.getOffer(offers[0]);
    }
}
