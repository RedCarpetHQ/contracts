// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/MultiRoundCampaign.sol";
import "../src/CampaignAdmin.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "../src/LendingManager.sol";
import "../src/VaultFactory.sol";
import "../src/HybridPriceOracle.sol";
import "../src/logic/MultiRoundLogic.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MultiRoundCampaignTest is Test {
    MultiRoundCampaign public multiRoundCampaign;
    CampaignAdmin public campaignAdmin;
    Registry public registry;
    TestUSDC public usdc;
    LendingManager public lendingManager;
    MultiRoundLogic public multiRoundLogic;
    
    address public owner = address(1);
    address public creator = address(2);
    address public buyer1 = address(3);
    address public buyer2 = address(4);
    
    address public token;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Registry
        Registry implementation = new Registry();
        bytes memory registryInitData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(implementation), registryInitData);
        registry = Registry(address(registryProxy));
        
        // Deploy USDC
        usdc = new TestUSDC(owner);
        registry.setUsdc(address(usdc));
        
        // Deploy MultiRoundLogic
        multiRoundLogic = new MultiRoundLogic(owner);
        registry.setMultiRoundLogic(address(multiRoundLogic));
        
        // Deploy CampaignAdmin
        campaignAdmin = new CampaignAdmin(owner, address(registry));
        
        // Deploy MultiRoundCampaign (UUPS Upgradeable)
        MultiRoundCampaign multiRoundCampaignImpl = new MultiRoundCampaign();
        bytes memory campaignInitData = abi.encodeWithSelector(
            MultiRoundCampaign.initialize.selector,
            owner,
            address(registry),
            address(campaignAdmin)
        );
        ERC1967Proxy campaignProxy = new ERC1967Proxy(address(multiRoundCampaignImpl), campaignInitData);
        multiRoundCampaign = MultiRoundCampaign(address(campaignProxy));
        
        // Set token implementation
        MinimumERC20 tokenImpl = new MinimumERC20();
        registry.setTokenImplementation(address(tokenImpl));
        
        // Deploy LendingManager and VaultFactory
        lendingManager = new LendingManager(owner, address(registry));
        registry.setLendingManager(address(lendingManager));

        VaultFactory vaultFactory = new VaultFactory(owner);
        vaultFactory.setLendingManager(address(lendingManager));
        lendingManager.setVaultFactory(address(vaultFactory));
        
        // Deploy and set up price oracle for finalization tests
        HybridPriceOracle priceOracle = new HybridPriceOracle(owner);
        registry.setHybridPriceOracle(address(priceOracle));
        
        // Authorize contracts
        registry.setAuthorizedContract(address(multiRoundCampaign), true);
        registry.setAuthorizedContract(address(lendingManager), true);
        
        // Approve test campaign
        campaignAdmin.setCampaignIdApproval("multi-round-test-1", true);
        
        vm.stopPrank();
        
        // Fund buyers
        vm.prank(owner);
        usdc.mint(buyer1, 100_000e6);
        vm.prank(owner);
        usdc.mint(buyer2, 100_000e6);
        
        // Create initial campaign
        address[] memory additionalCreators = new address[](0);
        vm.prank(creator);
        token = multiRoundCampaign.createMultiRoundCampaign(
            "multi-round-test-1",
            "Multi-Round Movie",
            "MRMOVIE",
            address(usdc),
            1000e6,  // floor
            2000e6,  // ceiling
            2,       // CEILING overage type
            creator,
            block.timestamp,
            block.timestamp + 30 days,
            additionalCreators
        );
    }
    
    // ========== Round Creation ==========
    
    function test_CreateNextRound() public {
        // Complete first round
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Must wait MIN_ROUND_GAP (2 days) before creating next round
        vm.warp(block.timestamp + 2 days);

        // Create next round - calculate times carefully
        // NOTE: Using direct literals to work around potential compiler bug
        uint256 _start = 2937601;  // 2851201 + 1 day
        uint256 _end = 5529601;    // 2851201 + 31 days
        vm.prank(creator);
        multiRoundCampaign.createNextRound(
            token,
            1500e6,  // floor (must be >= last successful floor)
            3000e6,  // ceiling
            2,       // CEILING overage type
            _start,
            _end
        );

        IMultiRoundLogic.MultiRoundState memory state = multiRoundCampaign.getMultiRoundState(token);
        assertEq(state.totalRoundsCreated, 2);
        assertEq(state.currentRoundId, 2);
    }
    
    function test_CreateNextRound_RevertFloorTooLow() public {
        // Complete first round with 1500e6
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Must wait MIN_ROUND_GAP (2 days) before creating next round
        vm.warp(block.timestamp + 2 days);

        // Try to create next round with floor below minimum (50% of 1000e6 floor = 500e6)
        // NOTE: Using calculated values to work around potential compiler bug
        uint256 _start = 2937601;  // 2851201 + 1 day
        uint256 _end = 5529601;    // 2851201 + 31 days
        vm.prank(creator);
        vm.expectRevert("Floor too low compared to previous round");
        multiRoundCampaign.createNextRound(
            token,
            400e6,   // Below 500e6 minimum (50% of 1000e6 floor)
            3000e6,
            2,
            _start,
            _end
        );
    }
    
    function test_CreateNextRound_RevertMaxRounds() public {
        // Create and complete 5 rounds (max)
        for (uint256 i = 1; i <= 5; i++) {
            // Purchase to complete round
            vm.startPrank(buyer1);
            usdc.approve(address(multiRoundCampaign), 1500e6);
            multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
            vm.stopPrank();

            vm.warp(block.timestamp + 31 days);

            vm.prank(creator);
            multiRoundCampaign.endRound(token, i);

            // Must wait MIN_ROUND_GAP (2 days) before creating next round
            vm.warp(block.timestamp + 2 days);

            // Create next round if not at max
            if (i < 5) {
                uint256 nextRoundStart = block.timestamp + 1 days;
                uint256 nextRoundEnd = block.timestamp + 31 days;
                vm.prank(creator);
                multiRoundCampaign.createNextRound(
                    token,
                    1500e6,
                    3000e6,
                    2,
                    nextRoundStart,
                    nextRoundEnd
                );
                // Warp to next round start time to allow purchases
                vm.warp(nextRoundStart);
            }
        }

        // Try to create 6th round
        uint256 round6Start = block.timestamp + 1 days;
        uint256 round6End = block.timestamp + 31 days;
        vm.prank(creator);
        vm.expectRevert("Maximum rounds reached");
        multiRoundCampaign.createNextRound(
            token,
            1500e6,
            3000e6,
            2,
            round6Start,
            round6End
        );
    }
    
    // ========== Round Purchases ==========
    
    function test_PurchaseTokens_MultipleRounds() public {
        // Round 1 purchase
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1000e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1000e6, address(0));
        vm.stopPrank();

        assertEq(MinimumERC20(token).balanceOf(buyer1), 1000e6);

        // Complete round 1
        vm.warp(block.timestamp + 31 days);
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Must wait MIN_ROUND_GAP (2 days) before creating next round
        vm.warp(block.timestamp + 2 days);

        // Create round 2
        uint256 round2Start = block.timestamp + 1 days;
        uint256 round2End = block.timestamp + 31 days;
        vm.prank(creator);
        multiRoundCampaign.createNextRound(
            token,
            1000e6,
            2000e6,
            2,
            round2Start,
            round2End
        );

        // Warp to round 2 start time
        vm.warp(round2Start);

        // Round 2 purchase
        vm.startPrank(buyer2);
        usdc.approve(address(multiRoundCampaign), 500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 500e6, address(0));
        vm.stopPrank();

        assertEq(MinimumERC20(token).balanceOf(buyer2), 500e6);
    }
    
    // ========== Round Ending ==========
    
    function test_EndRound_Success() public {
        // Purchase to reach floor
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();
        
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);
        
        IMultiRoundLogic.Round memory round = multiRoundCampaign.getRound(token, 1);
        
        assertEq(round.status, 3); // SUCCESS
        assertEq(round.totalRaised, 1500e6);
    }
    
    function test_EndRound_Failed() public {
        // Purchase below floor
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 500e6, address(0));
        vm.stopPrank();
        
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);
        
        IMultiRoundLogic.Round memory round = multiRoundCampaign.getRound(token, 1);
        
        assertEq(round.status, 4); // FAILED
        assertEq(round.totalRaised, 500e6);
    }
    
    // ========== Fund Collection ==========
    
    function test_CollectRoundFunds() public {
        // Complete successful round
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();
        
        vm.warp(block.timestamp + 31 days);
        
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);
        
        // Collect funds
        uint256 balanceBefore = usdc.balanceOf(creator);
        
        vm.prank(creator);
        multiRoundCampaign.collectRoundFunds(token, 1);
        
        uint256 balanceAfter = usdc.balanceOf(creator);
        assertEq(balanceAfter - balanceBefore, 1500e6);
    }
    
    function test_CollectAllFunds() public {
        // Complete 2 successful rounds
        for (uint256 i = 1; i <= 2; i++) {
            vm.startPrank(buyer1);
            usdc.approve(address(multiRoundCampaign), 1000e6);
            multiRoundCampaign.purchaseTokensMultiRound(token, 1000e6, address(0));
            vm.stopPrank();

            vm.warp(block.timestamp + 31 days);

            vm.prank(creator);
            multiRoundCampaign.endRound(token, i);

            if (i == 1) {
                // Must wait MIN_ROUND_GAP (2 days) before creating next round
                vm.warp(block.timestamp + 2 days);

                uint256 round2Start = block.timestamp + 1 days;
                uint256 round2End = block.timestamp + 31 days;
                vm.prank(creator);
                multiRoundCampaign.createNextRound(
                    token,
                    1000e6,
                    2000e6,
                    2,
                    round2Start,
                    round2End
                );
                // Warp to round 2 start to allow purchases
                vm.warp(round2Start);
            }
        }

        // Collect all funds
        uint256 balanceBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        multiRoundCampaign.collectAllFunds(token);

        uint256 balanceAfter = usdc.balanceOf(creator);
        assertEq(balanceAfter - balanceBefore, 2000e6);
    }
    
    // ========== Round Cancellation ==========
    
    function test_CancelRound() public {
        vm.prank(creator);
        multiRoundCampaign.cancelRound(token);
        
        IMultiRoundLogic.Round memory round = multiRoundCampaign.getRound(token, 1);
        
        assertEq(round.status, 5); // CANCELLED
    }
    
    function test_CancelAllRounds() public {
        // Create 2 rounds - round 1 succeeds, then cancel all
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);  // Round 1 succeeds

        // Must wait MIN_ROUND_GAP (2 days) before creating next round
        vm.warp(2851201);

        // NOTE: Using calculated values to work around potential compiler bug
        uint256 _start = 2937601;  // 2851201 + 1 day
        uint256 _end = 5529601;    // 2851201 + 31 days
        vm.prank(creator);
        multiRoundCampaign.createNextRound(
            token,
            1000e6,
            2000e6,
            2,
            _start,
            _end
        );

        // Cancel all (requires at least one successful round)
        vm.prank(creator);
        multiRoundCampaign.cancelAllRounds(token);

        // Round 1 stays SUCCESS (3), round 2 becomes CANCELLED (5)
        IMultiRoundLogic.Round memory round1 = multiRoundCampaign.getRound(token, 1);
        IMultiRoundLogic.Round memory round2 = multiRoundCampaign.getRound(token, 2);

        assertEq(round1.status, 3); // SUCCESS (not cancelled - already ended)
        assertEq(round2.status, 5); // CANCELLED
    }
    
    // ========== Refunds ==========
    
    function test_RefundRound_FailedRound() public {
        // Purchase in round 1
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 500e6, address(0));
        vm.stopPrank();

        // End round as failed
        vm.warp(block.timestamp + 31 days);
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Approve campaign to burn tokens for refund
        uint256 tokensToBurn = MinimumERC20(token).balanceOf(buyer1);
        vm.prank(buyer1);
        MinimumERC20(token).approve(address(multiRoundCampaign), tokensToBurn);

        // Refund
        uint256 balanceBefore = usdc.balanceOf(buyer1);

        vm.prank(buyer1);
        multiRoundCampaign.refundRound(token, 1);

        uint256 balanceAfter = usdc.balanceOf(buyer1);
        assertEq(balanceAfter - balanceBefore, 500e6);
    }
    
    function test_RefundMultipleRounds() public {
        // Purchase in round 1 (above floor to make it succeed)
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);  // Round 1 succeeds

        // Must wait MIN_ROUND_GAP (2 days) before creating next round
        // After warp, timestamp = 2851201
        vm.warp(2851201);

        // Create round 2 with explicit timestamps
        uint256 round2Start = 2937601;  // 2851201 + 1 day
        uint256 round2End = 5529601;    // 2851201 + 31 days
        vm.prank(creator);
        multiRoundCampaign.createNextRound(
            token,
            1000e6,
            2000e6,
            2,
            round2Start,
            round2End
        );

        // Warp to round 2 start time
        vm.warp(round2Start);

        // Purchase in round 2 (below floor to make it fail)
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 500e6, address(0));
        vm.stopPrank();

        // Warp to one second past round 2 end time (> not >= check in shouldEndRound)
        vm.warp(round2End + 1);
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 2);  // Round 2 fails

        // Approve campaign to burn tokens for refunds
        uint256 totalTokens = MinimumERC20(token).balanceOf(buyer1);
        vm.prank(buyer1);
        MinimumERC20(token).approve(address(multiRoundCampaign), totalTokens);

        // Refund round 2 only (failed round)
        uint256 balanceBefore = usdc.balanceOf(buyer1);

        vm.prank(buyer1);
        multiRoundCampaign.refundRound(token, 2);

        uint256 balanceAfter = usdc.balanceOf(buyer1);
        assertEq(balanceAfter - balanceBefore, 500e6); // Only round 2 refund
    }
    
    // ========== Finalization ==========
    
    function test_CreatorFinalizeMultiRound() public {
        // Complete successful round
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Must wait MIN_ROUND_GAP (2 days) before creator can finalize
        vm.warp(block.timestamp + 2 days);

        // Finalize
        vm.prank(creator);
        multiRoundCampaign.creatorFinalizeMultiRound(token);

        // Check supply is locked
        assertTrue(MinimumERC20(token).isSupplyLocked());
    }
    
    function test_PublicFinalizeMultiRound() public {
        // Complete successful round
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 1500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 1500e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);

        // Wait for CREATOR_FINALIZE_GRACE (30 days) + MIN_ROUND_GAP (2 days) after round end
        // Public can only finalize after creator grace period expires
        vm.warp(block.timestamp + 32 days);

        // Anyone can finalize
        vm.prank(buyer2);
        multiRoundCampaign.publicFinalizeMultiRound(token);

        assertTrue(MinimumERC20(token).isSupplyLocked());
    }
    
    // ========== View Functions ==========
    
    function test_GetMultiRoundState() public {
        IMultiRoundLogic.MultiRoundState memory state = multiRoundCampaign.getMultiRoundState(token);
        
        assertEq(state.totalRoundsCreated, 1);
        assertEq(state.currentRoundId, 1);
        assertEq(state.totalTokensMinted, 0);
    }
    
    function test_GetRound() public {
        IMultiRoundLogic.Round memory round = multiRoundCampaign.getRound(token, 1);
        
        assertEq(round.floor, 1000e6);
        assertEq(round.ceiling, 2000e6);
        assertEq(round.overageType, 2);
        assertEq(round.status, 1); // PENDING
    }
    
    function test_IsRoundRefundable() public {
        // Purchase below floor
        vm.startPrank(buyer1);
        usdc.approve(address(multiRoundCampaign), 500e6);
        multiRoundCampaign.purchaseTokensMultiRound(token, 500e6, address(0));
        vm.stopPrank();
        
        // End round as failed
        vm.warp(block.timestamp + 31 days);
        vm.prank(creator);
        multiRoundCampaign.endRound(token, 1);
        
        // Check round status is FAILED
        IMultiRoundLogic.Round memory round = multiRoundCampaign.getRound(token, 1);
        assertEq(round.status, 4); // FAILED - refundable
    }
}
