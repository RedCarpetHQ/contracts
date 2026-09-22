// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/HybridPriceOracle.sol";
import "../src/Registry.sol";
import "../src/TestUSDC.sol";

contract HybridPriceOracleTest is Test {
    HybridPriceOracle public oracle;
    Registry public registry;
    
    address public owner = address(1);
    address public updater = address(2);
    address public token = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Registry via UUPS proxy (proper upgradeable pattern)
        Registry registryImpl = new Registry();
        bytes memory registryInitData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = Registry(address(registryProxy));
        
        oracle = new HybridPriceOracle(owner);
        oracle.setRegistry(address(registry));
        oracle.setAuthorizedUpdater(updater, true);
        
        vm.stopPrank();
    }
    
    // ========== Authorization Tests ==========
    
    function test_SetAuthorizedUpdater() public {
        vm.prank(owner);
        oracle.setAuthorizedUpdater(address(4), true);
        assertTrue(oracle.authorizedUpdaters(address(4)));
    }
    
    function test_RevokeAuthorizedUpdater() public {
        vm.prank(owner);
        oracle.setAuthorizedUpdater(updater, false);
        assertFalse(oracle.authorizedUpdaters(updater));
    }
    
    function test_OnlyOwnerCanAuthorize() public {
        vm.prank(address(999));
        vm.expectRevert();
        oracle.setAuthorizedUpdater(address(4), true);
    }
    
    // ========== Price Update Tests ==========
    
    function test_UpdatePrice_VWAP() public {
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        (uint256 price, bool reliable) = oracle.getPrice(token);
        assertEq(price, 10e18);
        assertTrue(reliable);
    }
    
    function test_UpdatePrice_RejectsExcessiveDeviation() public {
        // Set initial price
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Wait minimum interval
        vm.warp(block.timestamp + 5 minutes + 1);
        
        // Try to update with 30% deviation (should be clamped to 20%, not rejected)
        vm.prank(updater);
        oracle.updatePrice(token, 13e18, 1000e6);
        
        // Price should have moved toward 12e18 (clamped to +20% of 10e18 = 12e18)
        // then EMA blended with alpha = 1000/11000 ≈ 9.09%
        // newPrice = 0.0909 * 12e18 + 0.9091 * 10e18 ≈ 10.1818e18
        (uint256 price,) = oracle.getPrice(token);
        assertTrue(price > 10e18 && price < 12e18, "Price should move toward clamped value");
        assertApproxEqRel(price, 10.1818e18, 0.01e18, "Price should be EMA blended with clamped price");
        
        // Consecutive rejections should be incremented
        assertEq(oracle.getConsecutiveRejections(token), 1, "Rejection counter should increment");
    }
    
    function test_UpdatePrice_EnforcesMinimumInterval() public {
        // First update
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Try immediate update (should fail with minimum interval check)
        vm.prank(updater);
        vm.expectRevert("Update too frequent");
        oracle.updatePrice(token, 10.5e18, 1000e6);
        
        // Wait 5 minutes + 1 second
        vm.warp(block.timestamp + 5 minutes + 1);
        
        // Should succeed now (will be EMA blended, not exact 11e18)
        vm.prank(updater);
        oracle.updatePrice(token, 11e18, 1000e6);
        
        (uint256 price,) = oracle.getPrice(token);
        // VWAP uses EMA, so price will be between 10 and 11
        assertTrue(price > 10e18 && price < 11e18, "Price should be EMA blended");
    }
    
    function test_UpdatePrice_OnlyAuthorized() public {
        vm.prank(address(999));
        vm.expectRevert("Not authorized");
        oracle.updatePrice(token, 10e18, 1000e6);
    }
    
    // ========== Price Decay Tests ==========
    
    function test_PriceDecay_Phase1() public {
        // Set initial price (10 USDC = 10e6 in 6 decimals, scaled to 1e18 internally)
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Warp 7 days (Phase 1: 2% per day)
        vm.warp(block.timestamp + 7 days);
        
        (uint256 price, bool reliable) = oracle.getPrice(token);
        
        // Price should decay: 10e18 * (1 - 0.02)^7 ≈ 8.68e18
        // Allow 2% tolerance for decay calculation
        assertApproxEqRel(price, 8.68e18, 0.02e18);
        assertFalse(reliable); // Decayed price is not reliable
    }
    
    function test_PriceDecay_Phase2() public {
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Warp 20 days (Phase 1 + Phase 2)
        vm.warp(block.timestamp + 20 days);
        
        (uint256 price,) = oracle.getPrice(token);
        
        // Should be significantly decayed
        assertTrue(price < 8e18);
        assertTrue(price > 5e17); // Above 5% floor
    }
    
    function test_PriceDecay_Floor() public {
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Warp 60+ days (max decay)
        vm.warp(block.timestamp + 70 days);
        
        (uint256 price,) = oracle.getPrice(token);
        
        // Should hit 5% floor: 5% of 10e18 = 0.5e18
        assertApproxEqRel(price, 0.5e18, 0.01e18); // Allow 1% tolerance
    }
    
    // ========== Token Configuration Tests ==========
    
    function test_ConfigureToken() public {
        vm.prank(owner);
        oracle.configureToken(
            token,
            4 hours,      // staleThreshold
            1000e6,       // minVolume24h
            10000e6       // targetVolume
        );
        
        (uint256 staleThreshold, uint256 minVolume24h, uint256 targetVolume,) = oracle.tokenConfigs(token);
        assertEq(staleThreshold, 4 hours);
        assertEq(minVolume24h, 1000e6);
        assertEq(targetVolume, 10000e6);
    }
    
    function test_ConfigureToken_CustomValues() public {
        vm.prank(owner);
        oracle.configureToken(
            token,
            2 hours,      // staleThreshold
            500e6,        // minVolume24h
            5000e6        // targetVolume
        );
        
        (uint256 staleThreshold, uint256 minVolume24h, uint256 targetVolume,) = oracle.tokenConfigs(token);
        assertEq(staleThreshold, 2 hours);
        assertEq(minVolume24h, 500e6);
        assertEq(targetVolume, 5000e6);
    }
    
    // ========== Edge Cases ==========
    
    function test_GetPrice_UninitializedToken() public {
        (uint256 price, bool reliable) = oracle.getPrice(address(999));
        assertEq(price, 0); // Returns 0 for uninitialized tokens
        assertFalse(reliable);
    }
    
    function test_SetPrice_DirectSet() public {
        vm.prank(owner);
        oracle.setPrice(token, 15e18);
        
        (uint256 price,) = oracle.getPrice(token);
        assertEq(price, 15e18);
    }
    
    function test_Volume24h_Tracking() public {
        vm.startPrank(updater);
        
        // First update
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Wait 1 hour and update again
        vm.warp(block.timestamp + 1 hours);
        oracle.updatePrice(token, 10.1e18, 500e6);
        
        vm.stopPrank();
        
        (,,uint256 volume24h,,) = oracle.vwapData(token);
        assertEq(volume24h, 1500e6); // Cumulative volume
    }
    
    function test_Volume24h_Reset() public {
        vm.startPrank(updater);
        
        oracle.updatePrice(token, 10e18, 1000e6);
        
        // Warp 25 hours (past 24h window)
        vm.warp(block.timestamp + 25 hours);
        oracle.updatePrice(token, 10.1e18, 500e6);
        
        vm.stopPrank();
        
        (,,uint256 volume24h,,) = oracle.vwapData(token);
        assertEq(volume24h, 500e6); // Reset to new volume
    }
    
    // ========== Clamping Tests ==========

    function test_Clamp_UpwardConvergence() public {
        // Set initial price at $1
        vm.prank(updater);
        oracle.updatePrice(token, 1e18, 1000e6);

        // Simulate 20 trades at $14.89 every 5 min — EMA should converge upward
        // With alpha = 1000/11000 ≈ 9.09% and 20% clamp, each step moves ~1.82%
        // After 20 steps: 1 × (1.0182)^20 ≈ 1.43
        vm.startPrank(updater);
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 301);
            oracle.updatePrice(token, 14.89e18, 1000e6);
        }
        vm.stopPrank();

        // After 20 clamped updates, EMA should be significantly above $1
        (uint256 price, , , , ) = oracle.vwapData(token);
        assertGt(price, 1.3e18);
        // Consecutive rejections should be 20 (all were clamped)
        assertEq(oracle.getConsecutiveRejections(token), 20);
    }

    function test_Clamp_DownwardConvergence() public {
        // Set initial price at $15
        vm.prank(updater);
        oracle.updatePrice(token, 15e18, 1000e6);

        // Simulate 20 trades at $1 every 5 min — EMA should converge downward
        // With alpha = 9.09% and 20% clamp, each step moves ~1.82% down
        // After 20 steps: 15 × (0.9818)^20 ≈ 10.39
        vm.startPrank(updater);
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 301);
            oracle.updatePrice(token, 1e18, 1000e6);
        }
        vm.stopPrank();

        // After 20 clamped updates, EMA should be significantly below $15
        (uint256 price, , , , ) = oracle.vwapData(token);
        assertLt(price, 11e18);
        // Consecutive rejections should be 20 (all were clamped)
        assertEq(oracle.getConsecutiveRejections(token), 20);
    }

    function test_Clamp_RejectionCounterResets() public {
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);

        // Clamped update (30% deviation)
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        oracle.updatePrice(token, 13e18, 1000e6);
        assertEq(oracle.getConsecutiveRejections(token), 1, "Should have 1 rejection");

        // Normal update (within 20% deviation of current EMA) — should reset counter
        // After the clamped update, EMA moved slightly above 10e18
        (uint256 emaPrice, , , , ) = oracle.vwapData(token);
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        // Update with a price within 20% of current EMA
        oracle.updatePrice(token, emaPrice * 110 / 100, 1000e6); // 10% deviation from EMA
        assertEq(oracle.getConsecutiveRejections(token), 0, "Rejection counter should reset on normal update");
    }

    function test_Clamp_ReliabilityAfterMaxRejections() public {
        vm.prank(updater);
        oracle.updatePrice(token, 1e18, 1000e6);

        // Do 10+ clamped updates to exceed MAX_CONSECUTIVE_REJECTIONS
        vm.startPrank(updater);
        for (uint256 i = 0; i < 11; i++) {
            vm.warp(block.timestamp + 5 minutes + 1);
            oracle.updatePrice(token, 100e18, 1000e6); // Extreme deviation, always clamped
        }
        vm.stopPrank();

        // Price should be unreliable due to consecutive rejections
        (, bool reliable) = oracle.getPrice(token);
        assertFalse(reliable, "Price should be unreliable after 10+ consecutive rejections");

        // Now do a normal update (within 20% of current EMA)
        (uint256 currentPrice, , , , ) = oracle.vwapData(token);
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        oracle.updatePrice(token, currentPrice * 110 / 100, 1000e6); // 10% deviation

        // Should be reliable again
        (, bool reliableAfter) = oracle.getPrice(token);
        assertTrue(reliableAfter, "Price should be reliable after normal update resets counter");
    }

    function test_Clamp_LastUpdateAlwaysAdvances() public {
        vm.prank(updater);
        oracle.updatePrice(token, 1e18, 1000e6);

        (, uint256 lastUpdateBefore, , , ) = oracle.vwapData(token);

        // Clamped update
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        oracle.updatePrice(token, 100e18, 1000e6);

        (, uint256 lastUpdateAfter, , , ) = oracle.vwapData(token);
        assertTrue(lastUpdateAfter > lastUpdateBefore, "lastUpdate must advance even on clamped update");

        // Staleness should be small (not growing)
        uint256 staleness = oracle.getPriceStaleness(token);
        assertTrue(staleness < 1 hours, "Staleness should be small after clamped update");
    }

    function test_Clamp_VolumeAccumulatesOnClamp() public {
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);

        // Clamped update
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        oracle.updatePrice(token, 100e18, 500e6);

        (,,uint256 volume24h,,) = oracle.vwapData(token);
        assertEq(volume24h, 1500e6, "Volume should accumulate even on clamped updates");
    }

    function test_Clamp_Exactly20PercentNotClamped() public {
        // Deviation exactly at 20% boundary should NOT be clamped (uses > not >=)
        vm.prank(updater);
        oracle.updatePrice(token, 10e18, 1000e6);

        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(updater);
        oracle.updatePrice(token, 12e18, 1000e6); // Exactly 20% deviation

        assertEq(oracle.getConsecutiveRejections(token), 0, "20% deviation should not be clamped");
    }

    // ========== Fuzz Tests ==========
    
    function testFuzz_PriceUpdate(uint256 price, uint256 volume) public {
        price = bound(price, 0.01e18, 100e18); // $0.01 to $100 (reduced to avoid overflow)
        volume = bound(volume, 100e6, 1_000_000e6); // 100 to 1M USDC
        
        vm.prank(updater);
        oracle.updatePrice(token, price, volume);
        
        (uint256 returnedPrice, bool reliable) = oracle.getPrice(token);
        // First update sets price exactly
        assertEq(returnedPrice, price);
        assertTrue(reliable);
    }
    
    function testFuzz_PriceDecay(uint256 initialPrice, uint256 daysElapsed) public {
        initialPrice = bound(initialPrice, 1e18, 100e18);
        daysElapsed = bound(daysElapsed, 0, 60);
        
        vm.prank(updater);
        oracle.updatePrice(token, initialPrice, 1000e6);
        
        vm.warp(block.timestamp + daysElapsed * 1 days);
        
        (uint256 decayedPrice,) = oracle.getPrice(token);
        
        // Decayed price should be <= initial price
        assertTrue(decayedPrice <= initialPrice);
        
        // Should be >= 5% floor
        assertTrue(decayedPrice >= (initialPrice * 5) / 100);
    }
}
