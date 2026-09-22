// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/BurnRedemption.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BurnRedemptionTest is Test {
    BurnRedemption public burnRedemption;
    Registry public registry;
    TestUSDC public usdc;
    address public owner = address(1);
    address public holder = address(2);
    address public campaign = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        
        Registry implementation = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = Registry(address(proxy));
        usdc = new TestUSDC(owner);
        burnRedemption = new BurnRedemption(owner, address(registry));
        
        registry.setUsdc(address(usdc));
        registry.setBurnRedemption(address(burnRedemption));
        
        vm.stopPrank();
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        vm.startPrank(campaign);
        MinimumERC20 token = new MinimumERC20();
        token.initialize("Test Token", "TEST", campaign);
        token.mint(holder, 1000e6);
        vm.stopPrank();
        
        // Register campaign in Registry so authorization works
        vm.prank(owner);
        registry.setAuthorizedContract(address(this), true);
        registry.registerCampaign(
            address(token),
            campaign,
            address(usdc),
            1000e6, // floor
            0,      // ceiling
            0,      // overageType
            campaign, // fundsRecipient
            block.timestamp,
            block.timestamp + 30 days
        );
        
        return token;
    }
    
    function test_AuthorizeSurveyor() public {
        MinimumERC20 token = _deployToken();
        
        address surveyor = address(999);
        
        // Campaign creator authorizes a surveyor through Registry
        vm.prank(campaign);
        registry.setSurveyor(address(token), surveyor, true);
        
        // Check authorization through Registry
        assertTrue(registry.isAuthorizedSurveyor(address(token), surveyor));
        
        // Also check that campaign creator is automatically authorized
        assertTrue(registry.isAuthorizedSurveyor(address(token), campaign));
    }
    
    function test_CreateRedemptionEvent() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(campaign);
        burnRedemption.authorizeSurveyor(address(token), campaign, true);
        
        string[] memory tierNames = new string[](2);
        tierNames[0] = "T-Shirt";
        tierNames[1] = "Signed T-Shirt";
        
        uint256[] memory burnAmounts = new uint256[](2);
        burnAmounts[0] = 100e6;
        burnAmounts[1] = 300e6;
        
        uint256[] memory maxClaims = new uint256[](2);
        maxClaims[0] = 100;
        maxClaims[1] = 50;
        
        vm.prank(campaign);
        uint256 eventId = burnRedemption.createRedemptionEvent(
            address(token),
            "Test Merch",
            "Test Description",
            block.timestamp,
            block.timestamp + 30 days,
            tierNames,
            burnAmounts,
            maxClaims,
            "event123"
        );
        
        assertEq(eventId, 1);
    }
    
    function test_ClaimRedemption() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(campaign);
        burnRedemption.authorizeSurveyor(address(token), campaign, true);
        
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T-Shirt";
        
        uint256[] memory burnAmounts = new uint256[](1);
        burnAmounts[0] = 100e6;
        
        uint256[] memory maxClaims = new uint256[](1);
        maxClaims[0] = 100;
        
        vm.prank(campaign);
        uint256 eventId = burnRedemption.createRedemptionEvent(
            address(token),
            "Test Merch",
            "Test Description",
            block.timestamp,
            block.timestamp + 30 days,
            tierNames,
            burnAmounts,
            maxClaims,
            "event123"
        );
        
        uint256 balanceBefore = token.balanceOf(holder);
        
        vm.prank(holder);
        burnRedemption.claimRedemption(eventId, 0);
        
        uint256 balanceAfter = token.balanceOf(holder);
        assertEq(balanceBefore - balanceAfter, 100e6); // Burned 100 tokens
    }
    
    function test_OnlyAuthorizedSurveyorCanCreate() public {
        MinimumERC20 token = _deployToken();
        
        string[] memory tierNames = new string[](1);
        tierNames[0] = "T-Shirt";
        
        uint256[] memory burnAmounts = new uint256[](1);
        burnAmounts[0] = 100e6;
        
        uint256[] memory maxClaims = new uint256[](1);
        maxClaims[0] = 100;
        
        vm.prank(address(999));
        vm.expectRevert();
        burnRedemption.createRedemptionEvent(
            address(token),
            "Test Merch",
            "Test Description",
            block.timestamp,
            block.timestamp + 30 days,
            tierNames,
            burnAmounts,
            maxClaims,
            "event123"
        );
    }
}
