// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SurveySnapshot.sol";
import "../src/Registry.sol";
import "../src/MinimumERC20.sol";

contract SurveySnapshotTest is Test {
    SurveySnapshot public surveySnapshot;
    Registry public registry;
    
    address public owner = address(1);
    address public campaign = address(2);
    address public holder1 = address(3);
    address public holder2 = address(4);
    
    function setUp() public {
        vm.startPrank(owner);
        
        registry = new Registry();
        registry.initialize(owner);
        surveySnapshot = new SurveySnapshot(owner, address(registry));
        
        registry.setSurveySnapshot(address(surveySnapshot));
        
        vm.stopPrank();
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        vm.startPrank(campaign);
        MinimumERC20 token = new MinimumERC20();
        token.initialize("Test Token", "TEST", campaign);
        token.mint(holder1, 600e6);
        token.mint(holder2, 400e6);
        vm.stopPrank();
        return token;
    }
    
    function test_CreateSnapshot() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(campaign);
        token.snapshot();
        
        uint256 snapshotId = MinimumERC20(token).getCurrentSnapshotId();
        assertEq(snapshotId, 1);
    }
    
    function test_GetBalanceAtSnapshot() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(campaign);
        token.snapshot();
        
        uint256 balance = token.balanceOfAt(holder1, 1);
        assertEq(balance, 600e6);
    }
    
    function test_GetVotingPower() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(campaign);
        token.snapshot();
        
        // Voting power equals balance at snapshot
        uint256 votingPower = token.balanceOfAt(holder1, 1);
        assertEq(votingPower, 600e6);
    }
    
    function test_SnapshotPreservesBalances() public {
        MinimumERC20 token = _deployToken();
        
        // Take snapshot
        vm.prank(campaign);
        token.snapshot();
        
        // Transfer tokens after snapshot
        vm.prank(holder1);
        token.transfer(holder2, 100e6);
        
        // Snapshot balance should remain unchanged
        uint256 snapshotBalance = token.balanceOfAt(holder1, 1);
        assertEq(snapshotBalance, 600e6);
        
        // Current balance should be reduced
        uint256 currentBalance = token.balanceOf(holder1);
        assertEq(currentBalance, 500e6);
    }
}
