// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/FeeDistributor.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";

contract FeeDistributorTest is Test {
    FeeDistributor public feeDistributor;
    Registry public registry;
    TestUSDC public usdc;
    
    address public owner = address(1);
    address public feeSafe = address(2);
    address public campaign = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        
        registry = new Registry();
        registry.initialize(owner);
        usdc = new TestUSDC(owner);
        feeDistributor = new FeeDistributor(owner, address(registry));
        
        registry.setUsdc(address(usdc));
        registry.setFeeDistributor(address(feeDistributor));
        registry.setFeeSafe(feeSafe);
        
        vm.stopPrank();
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        vm.startPrank(campaign);
        MinimumERC20 token = new MinimumERC20();
        token.initialize("Test Token", "TEST", campaign);
        vm.stopPrank();
        return token;
    }
    
    function test_DistributeFees() public {
        MinimumERC20 token = _deployToken();
        
        // Send fees to distributor
        vm.prank(owner);
        usdc.mint(address(feeDistributor), 1000e6);
        
        // Authorize owner to distribute
        vm.prank(owner);
        registry.setAuthorizedContract(owner, true);
        
        // Distribute
        vm.prank(owner);
        feeDistributor.distributeFees(address(token), 1000e6);
        
        // Check distribution (40% to feeSafe, 40% to contest, 10% to vault, 10% to producer)
        (,uint256 toFeeSafe,,,,) = feeDistributor.tokenFees(address(token));
        assertEq(toFeeSafe, 400e6); // 40% of 1000
    }
    
    function test_GetTokenFeeData() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(owner);
        usdc.mint(address(feeDistributor), 1000e6);
        
        vm.prank(owner);
        registry.setAuthorizedContract(owner, true);
        
        vm.prank(owner);
        feeDistributor.distributeFees(address(token), 1000e6);
        
        // Verify fee tracking
        (uint256 totalReceived, uint256 toFeeSafe, uint256 toContest,, uint256 toProducer,) = feeDistributor.tokenFees(address(token));
        assertEq(totalReceived, 1000e6);
        assertEq(toFeeSafe, 400e6);
        assertEq(toContest, 400e6);
        assertEq(toProducer, 100e6);
    }
    
    function test_OnlyAuthorizedCanDistribute() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(address(999));
        vm.expectRevert();
        feeDistributor.distributeFees(address(token), 1000e6);
    }
}
