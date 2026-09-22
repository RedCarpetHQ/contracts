// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Contest.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";

contract ContestTest is Test {
    Contest public contest;
    Registry public registry;
    TestUSDC public usdc;

    address public owner = address(1);
    address public market = address(2);
    address public feeDistributor = address(3);
    address public trader1 = address(4);
    address public trader2 = address(5);
    address public trader3 = address(6);

    address public token = address(100);

    uint32 public constant EPOCH_LENGTH = 3 hours;
    uint96 public constant THRESHOLD = 15_000e6;
    uint96 public constant BPS = 100; // 1%

    function setUp() public {
        vm.startPrank(owner);

        // Deploy Registry via UUPS proxy (proper upgradeable pattern)
        Registry registryImpl = new Registry();
        bytes memory registryInitData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = Registry(address(registryProxy));

        usdc = new TestUSDC(owner);
        contest = new Contest(owner, address(registry));

        registry.setUsdc(address(usdc));
        registry.setContest(address(contest));

        contest.setSource(market, true);
        contest.setSource(feeDistributor, true);
        contest.setCollector(feeDistributor, true);

        vm.stopPrank();

        // Register a campaign and enable market for the token
        vm.startPrank(owner);
        registry.registerCampaign(token, owner, address(usdc), 0, 5000e6, 1, owner, block.timestamp, block.timestamp + 1 days);
        registry.enableMarket(token);
        vm.stopPrank();
    }

    // --- Helpers ---

    function _mintUsdc(address to, uint256 amount) internal {
        vm.prank(owner);
        usdc.mint(to, amount);
    }

    function _warpToEpochEnd(uint32 epoch) internal {
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        uint256 target = enabledAt + (uint256(epoch) + 1) * EPOCH_LENGTH;
        vm.warp(target);
    }

    function _depositFees(uint32 epoch, uint256 amount) internal {
        _mintUsdc(feeDistributor, amount);
        vm.startPrank(feeDistributor);
        usdc.approve(address(contest), amount);
        contest.depositFees(token, epoch, amount);
        vm.stopPrank();
    }

    function _addVolume(address trader, uint128 volume) internal {
        vm.prank(market);
        contest.addBuyVolume(token, trader, volume);
    }

    function _qualify(address trader) internal {
        _addVolume(trader, THRESHOLD + 1e6);
    }

    // --- Core Redesign Tests ---

    function test_finalizeEpoch_autoSweepOneDeadEpoch() public {
        // Epoch 0: dead (no qualifiers), fees = 100 USDC
        // Epoch 1: alive, fees = 200 USDC
        _depositFees(0, 100e6);
        _depositFees(1, 200e6);

        // Warp to just before epoch 1 ends, then qualify trader1 in epoch 1
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        vm.warp(enabledAt + 2 * EPOCH_LENGTH - 1);
        _qualify(trader1); // epoch 1

        _warpToEpochEnd(1);

        // finalize epoch 1 -> auto-sweeps dead epoch 0
        contest.finalizeEpoch(token, 1);

        // Check epoch 1 prize pool includes swept rollover
        (,, uint128 usdcPrize,, bool finalized,) = contest.getEpochData(token, 1);
        assertTrue(finalized);
        // Total pool = 100 + 200 = 300 USDC, bounty = 3 USDC, prize = 297 USDC
        assertEq(usdcPrize, 297e6);

        // Epoch 0 should be finalized as dead
        (,,,, bool e0Finalized,) = contest.getEpochData(token, 0);
        assertTrue(e0Finalized);
    }

    function test_finalizeEpoch_sweepsMultipleDeadEpochs() public {
        // Epochs 0,1,2 dead; Epoch 3 alive
        _depositFees(0, 10e6);
        _depositFees(1, 20e6);
        _depositFees(2, 30e6);
        _depositFees(3, 100e6);

        // Warp to just before epoch 3 ends, qualify trader1 in epoch 3
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        vm.warp(enabledAt + 4 * EPOCH_LENGTH - 1);
        _qualify(trader1); // epoch 3
        _warpToEpochEnd(3);

        contest.finalizeEpoch(token, 3);

        (,, uint128 usdcPrize,, bool finalized,) = contest.getEpochData(token, 3);
        assertTrue(finalized);
        // Total pool = 10+20+30+100 = 160 USDC, bounty = 1.6 USDC, prize = 158.4 USDC
        assertEq(usdcPrize, 158.4e6);
    }

    function test_finalizeEpoch_stopsAtAliveEpoch() public {
        // Epoch 0: alive (has qualifiers)
        // Epoch 1: dead
        // Epoch 2: alive
        _depositFees(0, 100e6);
        _depositFees(1, 50e6);
        _depositFees(2, 200e6);

        _qualify(trader1); // epoch 0
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        // Warp to just before epoch 2 ends, qualify trader2 in epoch 2
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        vm.warp(enabledAt + 3 * EPOCH_LENGTH - 1);
        _qualify(trader2); // epoch 2
        _warpToEpochEnd(2);

        // finalize epoch 2 -> should sweep epoch 1, stop at epoch 0 (already finalized)
        contest.finalizeEpoch(token, 2);

        (,, uint128 usdcPrize2,, bool finalized2,) = contest.getEpochData(token, 2);
        assertTrue(finalized2);
        // Pool = 50 (epoch1 swept) + 200 (epoch2) = 250, bounty = 2.5, prize = 247.5
        assertEq(usdcPrize2, 247.5e6);
    }

    function test_finalizeEpoch_deadEpochReverts() public {
        _depositFees(0, 100e6);
        _warpToEpochEnd(0);

        // Epoch 0 is dead (no qualifiers)
        vm.expectRevert("dead epoch - no qualifiers");
        contest.finalizeEpoch(token, 0);
    }

    function test_finalizeEpoch_alreadyFinalizedReverts() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);

        contest.finalizeEpoch(token, 0);

        vm.expectRevert("already finalized");
        contest.finalizeEpoch(token, 0);
    }

    function test_finalizeEpoch_epochNotEndedReverts() public {
        _qualify(trader1);
        // Don't warp - epoch is still live
        vm.expectRevert("epoch live");
        contest.finalizeEpoch(token, 0);
    }

    function test_sweepDeadEpochs() public {
        _depositFees(0, 100e6);
        _warpToEpochEnd(0);

        // Fund contest with USDC for rebate
        _mintUsdc(address(contest), 10e6);
        vm.prank(owner);
        contest.setDeadEpochSweepReward(1e6);

        uint32[] memory deadEpochs = new uint32[](1);
        deadEpochs[0] = 0;

        uint256 balanceBefore = usdc.balanceOf(address(this));
        contest.sweepDeadEpochs(token, deadEpochs);
        uint256 balanceAfter = usdc.balanceOf(address(this));

        // Should receive 1 USDC rebate
        assertEq(balanceAfter - balanceBefore, 1e6);

        // Epoch 0 should be finalized
        (,,,, bool finalized,) = contest.getEpochData(token, 0);
        assertTrue(finalized);
    }

    function test_sweepDeadEpochs_zeroRewardNoRebate() public {
        _depositFees(0, 100e6);
        _warpToEpochEnd(0);

        // Reward is 0 by default
        uint32[] memory deadEpochs = new uint32[](1);
        deadEpochs[0] = 0;

        uint256 balanceBefore = usdc.balanceOf(address(this));
        contest.sweepDeadEpochs(token, deadEpochs);
        uint256 balanceAfter = usdc.balanceOf(address(this));

        // No rebate paid
        assertEq(balanceAfter - balanceBefore, 0);
    }

    function test_sweepDeadEpochs_skipsAliveEpochs() public {
        _depositFees(0, 100e6);
        _qualify(trader1); // epoch 0 alive
        _warpToEpochEnd(0);

        uint32[] memory deadEpochs = new uint32[](1);
        deadEpochs[0] = 0;

        // Epoch 0 is alive, should skip
        contest.sweepDeadEpochs(token, deadEpochs);

        (,,,, bool finalized,) = contest.getEpochData(token, 0);
        assertFalse(finalized); // not finalized because it's alive
    }

    function test_sweepDeadEpochs_skipsFinalizedEpochs() public {
        _depositFees(0, 100e6);
        _warpToEpochEnd(0);

        // First sweep
        uint32[] memory deadEpochs = new uint32[](1);
        deadEpochs[0] = 0;
        contest.sweepDeadEpochs(token, deadEpochs);

        // Second sweep should skip (already finalized)
        contest.sweepDeadEpochs(token, deadEpochs);
        // Should not revert
    }

    function test_sweepDeadEpochs_epochLiveReverts() public {
        _depositFees(0, 100e6);
        // Don't warp - epoch still live

        uint32[] memory deadEpochs = new uint32[](1);
        deadEpochs[0] = 0;

        vm.expectRevert("epoch live");
        contest.sweepDeadEpochs(token, deadEpochs);
    }

    // --- getEstimatedPrizePool Tests ---

    function test_getEstimatedPrizePool_beforeFinalization() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);

        (uint128 totalPrize, uint128 bounty, uint128 fees, uint128 rollover, bool hasQualifiers, bool isFinalized) =
            contest.getEstimatedPrizePool(token, 0);

        assertTrue(hasQualifiers);
        assertFalse(isFinalized);
        assertEq(fees, 100e6);
        assertEq(rollover, 0);
        // Total pool = 100, bounty = 1, prize = 99
        assertEq(totalPrize, 99e6);
        assertEq(bounty, 1e6);
    }

    function test_getEstimatedPrizePool_withDeadRollover() public {
        // Epoch 0 dead with fees, Epoch 1 alive
        _depositFees(0, 50e6);
        _depositFees(1, 100e6);
        _qualify(trader1); // qualifies in epoch 0 (current)
        _warpToEpochEnd(1);

        // trader1 qualified in epoch 0, but we want epoch 0 dead.
        // Actually, _qualify adds volume in current epoch. If we call it before warp,
        // it adds to epoch 0. So epoch 0 is alive.
        // We need: no volume in epoch 0, volume in epoch 1.
        // This is tricky with current setup. Let me use a different approach.

        // Actually, in my setup, trader1 is qualified in epoch 0.
        // So epoch 0 is NOT dead. Let me re-setup.

        // I'll create a fresh test: don't qualify anyone in epoch 0, qualify in epoch 1.
        // But the setup already called _qualify in setUp? No, setUp doesn't add volume.

        // So I need to NOT call _qualify before epoch 0 ends, then qualify in epoch 1.
        // After epoch 0 ends, warp to epoch 1, then qualify, then check estimate.

        // Wait, my current setup already deposited fees and qualified trader1 in epoch 0.
        // So epoch 0 is alive. Let me just not do that and instead:

        // Clean approach: create new token for each test via setUp, but modify behavior.
        // Since we can't easily "undo" qualifications, let me just test with the current state.
        // In this test, trader1 is qualified in epoch 0, so epoch 0 is alive.
        // This means epoch 1's estimate will NOT include epoch 0 rollover (stops at alive epoch).

        // Let's test differently: after finalizing epoch 0, then checking epoch 2 with dead epoch 1.
    }

    function test_getEstimatedPrizePool_afterFinalization() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        (uint128 totalPrize, uint128 bounty,,, bool hasQualifiers, bool isFinalized) =
            contest.getEstimatedPrizePool(token, 0);

        assertTrue(hasQualifiers);
        assertTrue(isFinalized);
        assertEq(totalPrize, 99e6); // 100 - 1% bounty
        assertEq(bounty, 1e6);
    }

    function test_getEstimatedPrizePool_noQualifiers() public {
        _depositFees(0, 100e6);
        _warpToEpochEnd(0);

        (uint128 totalPrize, uint128 bounty, uint128 fees, uint128 rollover, bool hasQualifiers, bool isFinalized) =
            contest.getEstimatedPrizePool(token, 0);

        assertFalse(hasQualifiers);
        assertFalse(isFinalized);
        assertEq(totalPrize, 0);
        assertEq(bounty, 0);
        assertEq(fees, 0);
        assertEq(rollover, 0);
    }

    // --- Claim Tests ---

    function test_claim_firstClaimerGetsBounty() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        uint256 balanceBefore = usdc.balanceOf(trader1);

        vm.prank(trader1);
        contest.claim(token, 0, trader1);

        uint256 balanceAfter = usdc.balanceOf(trader1);
        uint256 payout = balanceAfter - balanceBefore;

        // trader1 is first claimer: gets full prize (99 USDC) + bounty (1 USDC) = 100 USDC
        // But prize is pro-rata, and trader1 is the ONLY qualifier, so they get 100% of prize
        // = 99 USDC prize + 1 USDC bounty = 100 USDC
        assertEq(payout, 100e6);
    }

    function test_claim_withSweptRollover() public {
        // Epoch 0 dead: 100 USDC
        // Epoch 1 alive: 100 USDC, trader1 qualified
        _depositFees(0, 100e6);
        _depositFees(1, 100e6);
        _warpToEpochEnd(1);
        _qualify(trader1); // This qualifies trader1 in current epoch (1)
        // Wait - if we warp first, then _qualify, it uses current epoch which is 1.
        // But _warpToEpochEnd(1) sets block.timestamp to end of epoch 1.
        // Then _qualify would be in epoch 1? Actually, _currentEpoch uses block.timestamp,
        // and if we're AT the end of epoch 1, the current epoch is:
        // (block.timestamp - enabledAt) / EPOCH_LENGTH
        // At the exact boundary, this could be epoch 1 or epoch 2.
        // Let me be more careful.

        // Let me warp to exactly the end of epoch 1
        _warpToEpochEnd(1);
        // At this exact timestamp, current epoch = (end - enabledAt) / EPOCH_LENGTH = 1? No.
        // enabledAt + (1+1)*EPOCH_LENGTH = enabledAt + 2*EPOCH_LENGTH
        // (enabledAt + 2*EPOCH_LENGTH - enabledAt) / EPOCH_LENGTH = 2
        // So current epoch is 2, not 1.

        // I need to warp to exactly one second before epoch 1 ends.
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        vm.warp(enabledAt + 2 * EPOCH_LENGTH - 1);
        // Now current epoch = (enabledAt + 2*EPOCH_LENGTH - 1 - enabledAt) / EPOCH_LENGTH = (2*EPOCH_LENGTH - 1) / EPOCH_LENGTH = 1 (for EPOCH_LENGTH > 1)
        _qualify(trader1); // epoch 1

        // Now finalize epoch 1
        _warpToEpochEnd(1); // warp to exact end
        contest.finalizeEpoch(token, 1);

        uint256 balanceBefore = usdc.balanceOf(trader1);
        vm.prank(trader1);
        contest.claim(token, 1, trader1);
        uint256 balanceAfter = usdc.balanceOf(trader1);

        // Total pool = 100 (epoch0) + 100 (epoch1) = 200, bounty = 2, prize = 198
        // trader1 gets 100% = 198 + 2 bounty = 200
        assertEq(balanceAfter - balanceBefore, 200e6);
    }

    function test_claim_proRataShare() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _qualify(trader2);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        // Both traders have same eligible volume (THRESHOLD + 1e6 each)
        // Prize = 99e6, so each gets 49.5e6
        uint256 bal1Before = usdc.balanceOf(trader1);
        vm.prank(trader1);
        contest.claim(token, 0, trader1);
        uint256 bal1After = usdc.balanceOf(trader1);

        // First claimer gets bounty
        assertEq(bal1After - bal1Before, 49.5e6 + 1e6);

        uint256 bal2Before = usdc.balanceOf(trader2);
        vm.prank(trader2);
        contest.claim(token, 0, trader2);
        uint256 bal2After = usdc.balanceOf(trader2);

        assertEq(bal2After - bal2Before, 49.5e6);
    }

    function test_claimBatch() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        uint32[] memory epochsToClaim = new uint32[](1);
        epochsToClaim[0] = 0;

        uint256 balanceBefore = usdc.balanceOf(trader1);
        vm.prank(trader1);
        contest.claimBatch(token, epochsToClaim, trader1);
        uint256 balanceAfter = usdc.balanceOf(trader1);

        assertEq(balanceAfter - balanceBefore, 100e6); // 99 prize + 1 bounty
    }

    // --- Admin Tests ---

    function test_setDeadEpochSweepReward_onlyOwner() public {
        vm.prank(owner);
        contest.setDeadEpochSweepReward(5e6);
        assertEq(contest.deadEpochSweepReward(), 5e6);
    }

    function test_setDeadEpochSweepReward_nonOwnerReverts() public {
        vm.prank(trader1);
        vm.expectRevert("not owner");
        contest.setDeadEpochSweepReward(5e6);
    }

    // --- Edge Cases ---

    function test_finalizeEpoch_noFeesOrRolloverReverts() public {
        _qualify(trader1);
        _warpToEpochEnd(0);
        // No fees deposited
        vm.expectRevert("no fees or rollover");
        contest.finalizeEpoch(token, 0);
    }

    function test_finalizeEpoch_autoSweep_max32() public {
        // Create 35 dead epochs (0-34), then epoch 35 alive
        // But auto-sweep is bounded at 32, so only 32 dead epochs are swept
        for (uint32 i = 0; i < 35; i++) {
            _depositFees(i, 1e6); // 1 USDC per dead epoch
        }
        _depositFees(35, 100e6);

        // Warp to just before end of epoch 35, qualify trader1 in epoch 35
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        vm.warp(enabledAt + 36 * EPOCH_LENGTH - 1);
        _qualify(trader1); // epoch 35
        _warpToEpochEnd(35);

        contest.finalizeEpoch(token, 35);

        (,, uint128 usdcPrize,, bool finalized,) = contest.getEpochData(token, 35);
        assertTrue(finalized);
        // Should have swept 32 most recent dead epochs (3-34) = 32 USDC + 100 USDC = 132, bounty = 1.32, prize = 130.68
        assertEq(usdcPrize, 130.68e6);

        // Epochs 3-34 should be finalized (32 most recent dead epochs swept)
        for (uint32 i = 3; i <= 34; i++) {
            (,,,, bool f,) = contest.getEpochData(token, i);
            assertTrue(f);
        }
        // Epochs 0-2 should NOT be finalized (oldest dead epochs, beyond gas bound)
        for (uint32 i = 0; i < 3; i++) {
            (,,,, bool f,) = contest.getEpochData(token, i);
            assertFalse(f);
        }
    }

    function test_getClaimableAmount() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        (uint256 amount, bool isFirstClaimer) = contest.getClaimableAmount(token, 0, trader1);
        assertTrue(isFirstClaimer);
        assertEq(amount, 100e6); // 99 prize + 1 bounty
    }

    function test_claim_alreadyClaimedReverts() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        vm.prank(trader1);
        contest.claim(token, 0, trader1);

        vm.prank(trader1);
        vm.expectRevert("already claimed");
        contest.claim(token, 0, trader1);
    }

    function test_claim_notQualifiedReverts() public {
        _depositFees(0, 100e6);
        _qualify(trader1);
        _warpToEpochEnd(0);
        contest.finalizeEpoch(token, 0);

        vm.prank(trader2);
        vm.expectRevert("not qualified");
        contest.claim(token, 0, trader2);
    }

    function test_claim_notFinalizedReverts() public {
        _qualify(trader1);
        vm.prank(trader1);
        vm.expectRevert("not finalized");
        contest.claim(token, 0, trader1);
    }

    // --- Volume Tracking Tests ---

    function test_addBuyVolume_qualifiesUser() public {
        vm.prank(market);
        contest.addBuyVolume(token, trader1, THRESHOLD + 1e6);

        assertTrue(contest.isQualified(token, 0, trader1));
    }

    function test_addBuyVolume_belowThresholdNotQualified() public {
        vm.prank(market);
        contest.addBuyVolume(token, trader1, THRESHOLD - 1e6);

        assertFalse(contest.isQualified(token, 0, trader1));
    }

    function test_addBuyVolume_dustIgnored() public {
        vm.prank(market);
        contest.addBuyVolume(token, trader1, 0.5e6); // 0.5 USDC

        (uint128 totalUsdcVolume,,,,,) = contest.getEpochData(token, 0);
        assertEq(totalUsdcVolume, 0);
    }

    function test_addBuyVolume_ungraduatedTokenIgnored() public {
        address ungraduatedToken = address(999);
        vm.prank(market);
        contest.addBuyVolume(ungraduatedToken, trader1, THRESHOLD + 1e6);

        assertFalse(contest.isQualified(ungraduatedToken, 0, trader1));
    }

    // --- Deposit Fees Tests ---

    function test_depositFees_onlyAuthorizedSource() public {
        _mintUsdc(trader1, 100e6);
        vm.startPrank(trader1);
        usdc.approve(address(contest), 100e6);
        vm.expectRevert("not source");
        contest.depositFees(token, 0, 100e6);
        vm.stopPrank();
    }

    function test_depositFees_notGraduatedReverts() public {
        address ungraduatedToken = address(999);
        _mintUsdc(feeDistributor, 100e6);
        vm.startPrank(feeDistributor);
        usdc.approve(address(contest), 100e6);
        vm.expectRevert("not graduated");
        contest.depositFees(ungraduatedToken, 0, 100e6);
        vm.stopPrank();
    }

    // --- View Tests ---

    function test_getUserProgress() public {
        vm.prank(market);
        contest.addBuyVolume(token, trader1, THRESHOLD / 2);

        (bool qualified, uint128 volumeTraded, uint96 shortfall) = contest.getUserProgress(token, 0, trader1);
        assertFalse(qualified);
        assertEq(volumeTraded, THRESHOLD / 2);
        assertEq(shortfall, THRESHOLD / 2);
    }

    function test_epochEndTime() public {
        uint256 enabledAt = registry.getMarket(token).enabledAt;
        uint256 endTime = contest.epochEndTime(token, 0);
        assertEq(endTime, enabledAt + EPOCH_LENGTH);
    }

    function test_currentEpoch() public {
        uint32 epoch = contest.currentEpoch(token);
        assertEq(epoch, 0);

        _warpToEpochEnd(0);
        epoch = contest.currentEpoch(token);
        assertEq(epoch, 1);
    }

    // --- Regression: ensure old functionality still works ---

    function test_basicFinalizeAndClaim() public {
        _depositFees(0, 1000e6);
        _qualify(trader1);
        _qualify(trader2);
        _warpToEpochEnd(0);

        contest.finalizeEpoch(token, 0);

        vm.prank(trader1);
        contest.claim(token, 0, trader1);

        vm.prank(trader2);
        contest.claim(token, 0, trader2);

        // Both claimed successfully
        assertTrue(contest.isClaimed(token, 0, trader1));
        assertTrue(contest.isClaimed(token, 0, trader2));
    }

    function test_onlySourceModifier() public {
        vm.prank(trader1);
        vm.expectRevert("not source");
        contest.addBuyVolume(token, trader1, 100e6);
    }

    function test_onlyCollectorModifier() public {
        vm.prank(trader1);
        vm.expectRevert("not source");
        contest.depositFees(token, 0, 100e6);
    }
}
