// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/DividendDistributor.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "../src/CampaignAdmin.sol";

contract DividendDistributorTest is Test {
    DividendDistributor public dividendDistributor;
    Registry public registry;
    TestUSDC public usdc;
    
    address public owner = address(1);
    address public campaign = address(2);
    address public holder1 = address(3);
    address public holder2 = address(4);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Registry via UUPS proxy (constructor disables initializers on impl)
        Registry registryImpl = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = Registry(address(registryProxy));
        
        usdc = new TestUSDC(owner);
        dividendDistributor = new DividendDistributor(address(registry));
        
        registry.setUsdc(address(usdc));
        registry.setDividendDistributor(address(dividendDistributor));
        
        vm.stopPrank();
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        // Clone from implementation (constructor sets initialized=true, clone doesn't)
        MinimumERC20 tokenImpl = new MinimumERC20();
        MinimumERC20 token = MinimumERC20(Clones.clone(address(tokenImpl)));
        
        vm.prank(campaign);
        token.initialize("Test Token", "TEST", campaign);
        
        // Register token in Registry so createDividendRound works
        vm.startPrank(owner);
        registry.setTokenImplementation(address(tokenImpl));
        registry.setAuthorizedContract(address(this), true);
        vm.stopPrank();
        
        registry.registerCampaign(
            address(token),
            campaign,
            address(usdc),       // paymentToken
            1000e6,              // floor
            0,                   // ceiling
            0,                   // overageType
            campaign,            // fundsRecipient
            block.timestamp,     // startTime
            block.timestamp + 30 days // endTime
        );
        
        vm.startPrank(owner);
        // Authorize campaign as dividend distributor
        registry.authorizeDividendDistributor(address(token), campaign, true);
        // Grant snapshot role to dividend distributor
        vm.stopPrank();
        
        // Grant SNAPSHOT_ROLE to dividendDistributor so it can take snapshots
        vm.startPrank(campaign);
        token.grantRole(token.SNAPSHOT_ROLE(), address(dividendDistributor));
        token.mint(holder1, 600e6); // 60%
        token.mint(holder2, 400e6); // 40%
        vm.stopPrank();
        
        return token;
    }
    
    function test_CreateDividendRound() public {
        MinimumERC20 token = _deployToken();
        
        // Fund campaign with USDC
        vm.prank(owner);
        usdc.mint(campaign, 1000e6);
        
        // Create dividend round
        vm.startPrank(campaign);
        usdc.approve(address(dividendDistributor), 1000e6);
        uint256 roundId = dividendDistributor.createDividendRound(address(token), 1000e6);
        vm.stopPrank();
        
        assertEq(roundId, 1);
    }
    
    function test_CreateAndClaimDividends() public {
        MinimumERC20 token = _deployToken();
        
        // Fund campaign
        vm.prank(owner);
        usdc.mint(campaign, 1000e6);
        
        // Create round (snapshot is created automatically)
        vm.startPrank(campaign);
        usdc.approve(address(dividendDistributor), 1000e6);
        uint256 roundId = dividendDistributor.createDividendRound(address(token), 1000e6);
        vm.stopPrank();
        
        // Claim dividends
        uint256 balanceBefore = usdc.balanceOf(holder1);
        
        vm.prank(holder1);
        dividendDistributor.claimDividend(address(token), roundId);
        
        uint256 balanceAfter = usdc.balanceOf(holder1);
        // Holder1 has 60% of supply, should get 60% of 1000e6
        assertEq(balanceAfter - balanceBefore, 600e6);
    }
    
    function test_PreventDoubleClaim() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(owner);
        usdc.mint(campaign, 1000e6);
        
        vm.startPrank(campaign);
        usdc.approve(address(dividendDistributor), 1000e6);
        uint256 roundId = dividendDistributor.createDividendRound(address(token), 1000e6);
        vm.stopPrank();
        
        vm.startPrank(holder1);
        dividendDistributor.claimDividend(address(token), roundId);
        
        vm.expectRevert();
        dividendDistributor.claimDividend(address(token), roundId);
        vm.stopPrank();
    }
    
    function test_OnlyAuthorizedCanCreate() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(address(999));
        vm.expectRevert();
        dividendDistributor.createDividendRound(address(token), 1000e6);
    }
}
