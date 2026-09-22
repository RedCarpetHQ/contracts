// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/CampaignAdmin.sol";
import "../src/Registry.sol";
import "../src/SingleRoundCampaign.sol";
import "../src/MinimumERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title CampaignAdminFundsRecipientTest
 * @notice Tests for multi-creator funds recipient consensus mechanism
 */
contract CampaignAdminFundsRecipientTest is Test {
    CampaignAdmin public campaignAdmin;
    Registry public registry;
    SingleRoundCampaign public campaign;
    MinimumERC20 public tokenImpl;
    
    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public carol = address(4);
    address public dave = address(5);
    address public usdc = address(6);
    
    address public oldRecipient = address(100);
    address public newRecipient = address(200);
    address public anotherRecipient = address(300);
    
    address public token;
    
    event FundsRecipientProposalCreated(address indexed token, address indexed proposer, address proposedRecipient);
    event FundsRecipientProposalApproved(address indexed token, address indexed approver, address proposedRecipient);
    event FundsRecipientProposalExecuted(address indexed token, address oldRecipient, address newRecipient);
    event FundsRecipientUpdated(address indexed token, address indexed oldRecipient, address indexed newRecipient);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Registry
        Registry registryImpl = new Registry();
        bytes memory registryData = abi.encodeWithSignature("initialize(address)", owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryData);
        registry = Registry(address(registryProxy));
        
        // Deploy CampaignAdmin
        campaignAdmin = new CampaignAdmin(owner, address(registry));
        
        // Deploy SingleRoundCampaign
        SingleRoundCampaign campaignImpl = new SingleRoundCampaign();
        bytes memory campaignData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            owner,
            address(registry),
            address(campaignAdmin)
        );
        ERC1967Proxy campaignProxy = new ERC1967Proxy(address(campaignImpl), campaignData);
        campaign = SingleRoundCampaign(address(campaignProxy));
        
        // Deploy token implementation
        tokenImpl = new MinimumERC20();
        
        // Set addresses in Registry
        registry.setUsdc(usdc);
        registry.setCampaign(address(campaign));
        registry.setCampaignAdmin(address(campaignAdmin));
        registry.setTokenImplementation(address(tokenImpl));
        
        // Authorize contracts
        registry.setAuthorizedContract(address(campaign), true);
        registry.setAuthorizedContract(address(campaignAdmin), true);
        
        // Disable screening for tests
        campaignAdmin.setScreeningEnabled(false);
        
        vm.stopPrank();
    }
    
    function _createSingleCreatorCampaign() internal returns (address) {
        vm.prank(alice);
        address _token = campaign.createCampaign(
            "test-campaign",
            "Test Token",
            "TEST",
            usdc,
            1000 ether,
            2000 ether,
            2, // OVERAGE_CEILING
            oldRecipient,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            new address[](0) // No additional creators
        );
        return _token;
    }
    
    function _createMultiCreatorCampaign() internal returns (address) {
        address[] memory additionalCreators = new address[](2);
        additionalCreators[0] = bob;
        additionalCreators[1] = carol;
        
        vm.prank(alice);
        address _token = campaign.createCampaign(
            "test-campaign-multi",
            "Test Token Multi",
            "TESTM",
            usdc,
            1000 ether,
            2000 ether,
            2, // OVERAGE_CEILING
            oldRecipient,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            additionalCreators
        );
        return _token;
    }
    
    // ========== Single Creator Tests ==========
    
    function testSingleCreatorProposalExecutesImmediately() public {
        token = _createSingleCreatorCampaign();
        
        // Alice proposes and it should execute immediately
        vm.expectEmit(true, true, false, true);
        emit FundsRecipientProposalApproved(token, alice, newRecipient);
        
        vm.expectEmit(true, true, false, true);
        emit FundsRecipientProposalCreated(token, alice, newRecipient);
        
        vm.expectEmit(true, true, true, true);
        emit FundsRecipientUpdated(token, oldRecipient, newRecipient);
        
        vm.expectEmit(true, true, true, true);
        emit FundsRecipientProposalExecuted(token, oldRecipient, newRecipient);
        
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Verify change executed
        assertEq(registry.getCampaign(token).fundsRecipient, newRecipient);
    }
    
    // ========== Multi-Creator Tests ==========
    
    function testMultiCreatorProposalRequiresAllApprovals() public {
        token = _createMultiCreatorCampaign();
        
        // Alice proposes (auto-approves)
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Should not execute yet
        assertEq(registry.getCampaign(token).fundsRecipient, oldRecipient);
        
        // Bob approves
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Still not executed
        assertEq(registry.getCampaign(token).fundsRecipient, oldRecipient);
        
        // Carol approves - should execute
        vm.expectEmit(true, true, true, true);
        emit FundsRecipientUpdated(token, oldRecipient, newRecipient);
        
        vm.prank(carol);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Verify executed
        assertEq(registry.getCampaign(token).fundsRecipient, newRecipient);
    }
    
    function testProposerAutoApproves() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Check Alice's approval
        (address proposedRecipient, uint256 approvalCount, bool executed) = 
            campaignAdmin.getProposalDetails(token);
        
        assertEq(proposedRecipient, newRecipient);
        assertEq(approvalCount, 1); // Alice auto-approved
        assertFalse(executed);
        assertTrue(campaignAdmin.hasApproved(token, alice));
    }
    
    function testCannotApproveWithoutProposal() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(bob);
        vm.expectRevert("No active proposal");
        campaignAdmin.approveFundsRecipientChange(token);
    }
    
    function testCannotApproveTwice() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Bob tries to approve again
        vm.prank(bob);
        vm.expectRevert("Already approved");
        campaignAdmin.approveFundsRecipientChange(token);
    }
    
    function testNonCreatorCannotPropose() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(dave); // Not a creator
        vm.expectRevert("Only creator");
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
    }
    
    function testNonCreatorCannotApprove() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        vm.prank(dave); // Not a creator
        vm.expectRevert("Only creator");
        campaignAdmin.approveFundsRecipientChange(token);
    }
    
    function testCannotProposeZeroAddress() public {
        token = _createMultiCreatorCampaign();
        
        vm.prank(alice);
        vm.expectRevert("Invalid recipient");
        campaignAdmin.proposeFundsRecipientChange(token, address(0));
    }
    
    function testCannotExecuteProposalTwice() public {
        token = _createMultiCreatorCampaign();
        
        // Execute proposal
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        vm.prank(carol);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Try to propose again after execution
        vm.prank(alice);
        vm.expectRevert("Proposal already executed");
        campaignAdmin.proposeFundsRecipientChange(token, anotherRecipient);
    }
    
    function testChangingProposalResetsApprovals() public {
        token = _createMultiCreatorCampaign();
        
        // Alice proposes newRecipient
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Bob approves
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Check approval count
        (, uint256 approvalCount1, ) = campaignAdmin.getProposalDetails(token);
        assertEq(approvalCount1, 2); // Alice + Bob
        
        // Carol proposes different recipient - should reset
        vm.prank(carol);
        campaignAdmin.proposeFundsRecipientChange(token, anotherRecipient);
        
        // Check approval count reset
        (address proposedRecipient, uint256 approvalCount2, ) = 
            campaignAdmin.getProposalDetails(token);
        
        assertEq(proposedRecipient, anotherRecipient);
        assertEq(approvalCount2, 1); // Only Carol's auto-approval
    }
    
    function testProposerCanReProposeSameRecipient() public {
        token = _createMultiCreatorCampaign();
        
        // Alice proposes
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Alice proposes again (same recipient) - should not reset
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Approval count should still be 1
        (, uint256 approvalCount, ) = campaignAdmin.getProposalDetails(token);
        assertEq(approvalCount, 1);
    }
    
    function testFourCreatorCampaign() public {
        // Create campaign with 4 creators
        address[] memory additionalCreators = new address[](3);
        additionalCreators[0] = bob;
        additionalCreators[1] = carol;
        additionalCreators[2] = dave;
        
        vm.prank(alice);
        token = campaign.createCampaign(
            "test-campaign-four",
            "Test Token Four",
            "TEST4",
            usdc,
            1000 ether,
            2000 ether,
            2,
            oldRecipient,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            additionalCreators
        );
        
        // Alice proposes
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Bob, Carol approve
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        vm.prank(carol);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Not executed yet
        assertEq(registry.getCampaign(token).fundsRecipient, oldRecipient);
        
        // Dave approves - should execute
        vm.prank(dave);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Verify executed
        assertEq(registry.getCampaign(token).fundsRecipient, newRecipient);
    }
    
    function testEventsEmittedCorrectly() public {
        token = _createMultiCreatorCampaign();
        
        // Test proposal creation event
        vm.expectEmit(true, true, false, true);
        emit FundsRecipientProposalCreated(token, alice, newRecipient);
        
        vm.prank(alice);
        campaignAdmin.proposeFundsRecipientChange(token, newRecipient);
        
        // Test approval event
        vm.expectEmit(true, true, false, true);
        emit FundsRecipientProposalApproved(token, bob, newRecipient);
        
        vm.prank(bob);
        campaignAdmin.approveFundsRecipientChange(token);
        
        // Test execution events
        vm.expectEmit(true, true, true, true);
        emit FundsRecipientUpdated(token, oldRecipient, newRecipient);
        
        vm.expectEmit(true, true, true, true);
        emit FundsRecipientProposalExecuted(token, oldRecipient, newRecipient);
        
        vm.prank(carol);
        campaignAdmin.approveFundsRecipientChange(token);
    }
}
