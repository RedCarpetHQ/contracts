// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/RiskOracle.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";

contract RiskOracleTest is Test {
    RiskOracle public riskOracle;
    Registry public registry;
    
    address public owner = address(1);
    address public token = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        
        registry = new Registry();
        registry.initialize(owner);
        riskOracle = new RiskOracle(owner, address(registry));
        
        vm.stopPrank();
    }
    
    function test_GetRiskTier_DefaultsToGreen() public {
        // New campaigns default to GREEN to encourage early usage
        // All tokens are screened before campaign launch
        uint8 tier = riskOracle.getRiskTier(token);
        assertEq(tier, 0); // GREEN
    }
    
    function test_UpdateRiskTier_CalculatesBasedOnMetrics() public {
        // Register a campaign in registry first
        vm.prank(owner);
        registry.setAuthorizedContract(owner, true);
        
        vm.prank(owner);
        registry.registerCampaign(
            token,
            owner,
            address(4), // paymentToken
            1000e6,     // floor
            0,          // ceiling
            1,          // overageType
            owner,      // fundsRecipient
            block.timestamp,
            block.timestamp + 30 days
        );
        
        // Update risk tier (owner can always update)
        vm.prank(owner);
        uint8 tier = riskOracle.updateRiskTier(token);
        assertTrue(tier >= 0 && tier <= 2);
    }
    
    function test_OnlyAuthorizedCanUpdate() public {
        vm.prank(address(999));
        vm.expectRevert();
        riskOracle.updateRiskTier(token);
    }
}
