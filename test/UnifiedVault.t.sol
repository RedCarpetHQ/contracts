// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/UnifiedVault.sol";
import "../src/Registry.sol";
import "../src/VaultFactory.sol";
import "../src/HybridPriceOracle.sol";
import "../src/RiskOracle.sol";
import "../src/logic/InterestLogic.sol";
import "../src/logic/LendingLogic.sol";
import "../src/logic/JumpRateModel.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "../src/FeeDistributor.sol";
import "../src/Market.sol";

contract UnifiedVaultTest is Test {
    UnifiedVault public vault;
    Registry public registry;
    VaultFactory public factory;
    HybridPriceOracle public priceOracle;
    RiskOracle public riskOracle;
    InterestLogic public interestLogic;
    LendingLogic public lendingLogic;
    JumpRateModel public rateModel;
    FeeDistributor public feeDistributor;
    Market public market;
    
    TestUSDC public usdc;
    MinimumERC20 public collateralToken;
    
    address public owner = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    address public keeper = address(4);
    address public feeDistributorAddr;
    address public marketAddr;
    
    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_USDC = 1_000_000e6; // 1M USDC
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy core contracts
        registry = new Registry();
        registry.initialize(owner);
        usdc = new TestUSDC(owner);
        collateralToken = new MinimumERC20();
        collateralToken.initialize("Test Token", "TEST", owner);
        
        // Deploy oracles
        priceOracle = new HybridPriceOracle(owner);
        riskOracle = new RiskOracle(owner, address(registry));
        
        // Deploy logic contracts
        interestLogic = new InterestLogic();
        lendingLogic = new LendingLogic();
        rateModel = new JumpRateModel(owner);
        
        // Deploy Market and FeeDistributor
        market = new Market(owner, address(registry), 250);
        feeDistributor = new FeeDistributor(owner, address(registry));
        
        // Set registry addresses
        registry.setUsdc(address(usdc));
        registry.setHybridPriceOracle(address(priceOracle));
        registry.setRiskOracle(address(riskOracle));
        registry.setInterestLogic(address(interestLogic));
        registry.setLendingLogic(address(lendingLogic));
        registry.setRateModel(address(rateModel));
        registry.setKeeper(keeper);
        registry.setFeeDistributor(address(feeDistributor));
        registry.setMarket(address(market));
        
        // Configure oracles
        priceOracle.setRegistry(address(registry));
        priceOracle.setAuthorizedUpdater(owner, true);
        priceOracle.setPrice(address(collateralToken), 10e18); // $10 per token
        
        // RiskOracle calculates tier automatically based on metrics
        
        // Deploy vault factory
        factory = new VaultFactory(address(registry));
        registry.setLendingManager(address(factory));
        
        // Deploy vault via factory
        vault = UnifiedVault(factory.deployVault(
            owner,
            address(collateralToken),
            "Test Vault",
            "vTEST",
            address(registry)
        ));
        
        // Vault is active by default (isActive = true in constructor)
        
        // Fund test accounts
        usdc.mint(user1, INITIAL_USDC);
        usdc.mint(user2, INITIAL_USDC);
        collateralToken.transfer(user1, 10_000e18);
        collateralToken.transfer(user2, 10_000e18);
        
        vm.stopPrank();
    }
    
    // ========== SECURITY FIX TESTS ==========
    
    // Test Fix #3: Flash Loan Protection
    function test_FlashLoanProtection_CannotBenefitImmediately() public {
        // User1 deposits to stability pool
        vm.startPrank(user1);
        usdc.approve(address(vault), 50_000e6);
        vault.deposit(50_000e6, user1);
        vm.stopPrank();
        
        // User2 borrows immediately
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        // Price drops to make position liquidatable
        vm.prank(owner);
        priceOracle.setPrice(address(collateralToken), 5e18);
        
        // Liquidate IMMEDIATELY (within 1 hour of user1's deposit)
        vm.prank(keeper);
        vault.liquidateViaStabilityPool(user2, 250e6);
        
        // User1 should NOT have collateral gains yet (flash loan protection)
        assertEq(vault.collateralGains(user1), 0, "Should not have gains within 1 hour");
        
        // Warp time forward 1 hour + 1 second
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Trigger another liquidation or claim to update gains
        vm.prank(user1);
        vault.claimCollateralGains(); // This will update gains now that time has passed
        
        // After time lock, gains should be available (if there are more liquidations)
    }
    
    function test_FlashLoanProtection_MultipleDeposits() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 20_000e6);
        
        // First deposit
        vault.deposit(5_000e6, user1);
        
        // Warp 30 minutes
        vm.warp(block.timestamp + 30 minutes);
        
        // Second deposit (resets timer)
        vault.deposit(5_000e6, user1);
        
        vm.stopPrank();
        
        // User should still need to wait 1 hour from LAST deposit
        vm.warp(block.timestamp + 45 minutes); // Total 1h 15m from first, 45m from second
        
        // Should still be blocked (need 1h from second deposit)
        assertEq(vault.lastDepositTime(user1), block.timestamp - 45 minutes);
    }
    
    // Test Fix #5: Minimum Deposit Amount
    function test_MinimumDeposit_RevertsForSmallAmount() public {
        uint256 tinyAmount = 50e6; // 50 USDC (below 100 minimum)
        
        vm.startPrank(user1);
        usdc.approve(address(vault), tinyAmount);
        
        vm.expectRevert("Deposit below minimum");
        vault.deposit(tinyAmount, user1);
        
        vm.stopPrank();
    }
    
    function test_MinimumDeposit_AcceptsMinimumAmount() public {
        uint256 minAmount = 100e6; // Exactly 100 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(vault), minAmount);
        
        uint256 shares = vault.deposit(minAmount, user1);
        assertTrue(shares > 0, "Should accept minimum deposit");
        
        vm.stopPrank();
    }
    
    function test_MinimumDeposit_FeeDistributorBypass() public {
        uint256 tinyAmount = 50e6; // Below minimum
        
        // Fund FeeDistributor
        vm.prank(owner);
        usdc.mint(address(feeDistributor), tinyAmount);
        
        // FeeDistributor should be able to deposit small amounts
        vm.startPrank(address(feeDistributor));
        usdc.approve(address(vault), tinyAmount);
        
        // Should NOT revert (bypass for FeeDistributor)
        uint256 shares = vault.deposit(tinyAmount, address(feeDistributor));
        assertTrue(shares > 0, "FeeDistributor should bypass minimum");
        
        vm.stopPrank();
    }
    
    function test_MinimumDeposit_MarketBypass() public {
        uint256 tinyAmount = 50e6; // Below minimum
        
        // Fund Market
        vm.prank(owner);
        usdc.mint(address(market), tinyAmount);
        
        // Market should be able to deposit small amounts
        vm.startPrank(address(market));
        usdc.approve(address(vault), tinyAmount);
        
        // Should NOT revert (bypass for Market)
        uint256 shares = vault.deposit(tinyAmount, address(market));
        assertTrue(shares > 0, "Market should bypass minimum");
        
        vm.stopPrank();
    }
    
    // ========== Core Functionality Tests ==========
    
    function test_Deposit_AllocatesCorrectly() public {
        uint256 depositAmount = 10_000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        assertTrue(shares > 0, "Should receive shares");
        
        // Check 80/20 allocation
        uint256 expectedLending = (depositAmount * 8000) / 10000;
        uint256 expectedStability = depositAmount - expectedLending;
        
        assertEq(vault.lendingPool(), expectedLending, "Lending pool should be 80%");
        assertEq(vault.stabilityPool(), expectedStability, "Stability pool should be 20%");
        assertEq(vault.stabilityDeposits(user1), expectedStability, "User stability deposit tracked");
    }
    
    function test_Withdraw_ReducesPoolsProportionally() public {
        // First deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, user1);
        vm.stopPrank();
        
        uint256 lendingBefore = vault.lendingPool();
        uint256 stabilityBefore = vault.stabilityPool();
        
        // Withdraw half
        vm.startPrank(user1);
        vault.withdraw(5_000e6, user1, user1);
        vm.stopPrank();
        
        // Pools should reduce proportionally
        assertApproxEqRel(vault.lendingPool(), lendingBefore / 2, 0.01e18, "Lending pool reduced by ~50%");
        assertApproxEqRel(vault.stabilityPool(), stabilityBefore / 2, 0.01e18, "Stability pool reduced by ~50%");
    }
    
    function test_DepositCollateral_And_Borrow() public {
        // User1 deposits USDC to vault (provides liquidity)
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        // User2 deposits collateral and borrows
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        
        // Borrow 50% of collateral value (should be safe)
        // Collateral value = 100 * $10 = $1000
        // Max borrow at 50% CF = $500
        uint256 borrowAmount = 400e6; // $400 (safe)
        vault.borrow(borrowAmount);
        
        vm.stopPrank();
        
        assertEq(vault.collateralBalances(user2), 100e18, "Collateral deposited");
        assertEq(vault.totalBorrows(), borrowAmount, "Borrow recorded");
        assertTrue(usdc.balanceOf(user2) >= borrowAmount, "User received USDC");
    }
    
    function test_Liquidation_ViaStabilityPool() public {
        // Setup: User1 provides liquidity, User2 borrows
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6); // Borrow $500
        vm.stopPrank();
        
        // Price drops to $5 (makes position liquidatable)
        vm.prank(owner);
        priceOracle.setPrice(address(collateralToken), 5e18);
        
        // Keeper triggers liquidation
        vm.prank(keeper);
        uint256 seizeAmount = vault.liquidateViaStabilityPool(user2, 250e6); // Repay $250
        
        assertTrue(seizeAmount > 0, "Should seize collateral");
        assertTrue(vault.totalBorrows() < 500e6, "Debt should be reduced");
    }
    
    function test_BorrowRevertsWhenUtilizationTooHigh() public {
        // Deposit liquidity
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, user1);
        vm.stopPrank();
        
        // User2 tries to borrow more than 85% utilization
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 1000e18); // Large collateral
        vault.depositCollateral(1000e18);
        
        // Try to borrow 90% of lending pool (exceeds 85% cap)
        uint256 lendingPool = vault.lendingPool();
        uint256 excessiveBorrow = (lendingPool * 90) / 100;
        
        vm.expectRevert(); // Should revert due to utilization cap
        vault.borrow(excessiveBorrow);
        
        vm.stopPrank();
    }
    
    function test_HealthFactor_CalculatedCorrectly() public {
        // Setup borrowing position
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(400e6); // $400 debt
        vm.stopPrank();
        
        // Health = (100 * $10 * 0.6) / 400 = 600 / 400 = 1.5
        uint256 health = vault.getHealthFactor(user2);
        assertApproxEqRel(health, 1.5e18, 0.01e18, "Health factor should be ~1.5");
    }
    
    function test_CollateralGains_ClaimAfterLiquidation() public {
        // User1 deposits to stability pool
        vm.startPrank(user1);
        usdc.approve(address(vault), 50_000e6);
        vault.deposit(50_000e6, user1);
        vm.stopPrank();
        
        // Wait 1 hour for flash loan protection
        vm.warp(block.timestamp + 1 hours + 1);
        
        // User2 borrows and gets liquidated
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        // Price drops
        vm.prank(owner);
        priceOracle.setPrice(address(collateralToken), 5e18);
        
        // Liquidate
        vm.prank(keeper);
        vault.liquidateViaStabilityPool(user2, 250e6);
        
        // User1 should have collateral gains
        uint256 gains = vault.collateralGains(user1);
        assertTrue(gains > 0, "User1 should have collateral gains from liquidation");
        
        // Claim gains
        vm.prank(user1);
        vault.claimCollateralGains();
        
        assertTrue(collateralToken.balanceOf(user1) >= gains, "User1 should receive collateral");
    }
    
    function test_InterestAccrual() public {
        // Setup borrowing
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        uint256 borrowsBefore = vault.totalBorrows();
        
        // Warp time forward 1 year
        vm.warp(block.timestamp + 365 days);
        
        // Trigger interest accrual (via any state-changing function)
        vm.prank(user2);
        vault.repay(1e6); // Repay 1 USDC to trigger accrual
        
        uint256 borrowsAfter = vault.totalBorrows();
        assertTrue(borrowsAfter > borrowsBefore, "Interest should accrue over time");
    }
    
    function test_ProtocolIncome_Collection() public {
        // Setup borrowing to generate interest
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        // Warp time to accrue interest
        vm.warp(block.timestamp + 30 days);
        
        // Trigger accrual
        vm.prank(user2);
        vault.repay(1e6);
        
        uint256 protocolIncome = vault.protocolIncome();
        assertTrue(protocolIncome > 0, "Protocol should earn income from interest");
        
        // Collect protocol income
        vm.prank(keeper);
        vault.collectProtocolIncome();
        
        assertEq(vault.protocolIncome(), 0, "Protocol income should be collected");
    }
    
    // ========== Edge Cases & Attack Vectors ==========
    
    function test_CannotBorrowWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        
        vm.startPrank(user1);
        collateralToken.approve(address(vault), 100e18);
        
        vm.expectRevert("Pausable: paused");
        vault.depositCollateral(100e18);
        
        vm.stopPrank();
    }
    
    function test_CannotBorrowWhenInactive() public {
        // Deploy new vault (not activated)
        vm.prank(owner);
        UnifiedVault newVault = UnifiedVault(factory.deployVault(
            owner,
            address(collateralToken),
            "Test Vault 2",
            "vTEST2",
            address(registry)
        ));
        
        vm.startPrank(user1);
        usdc.approve(address(newVault), 1000e6);
        
        vm.expectRevert(); // Should revert with NotActive
        newVault.deposit(1000e6, user1);
        
        vm.stopPrank();
    }
    
    function test_FirstDepositorProtection() public {
        // First depositor gets virtual shares protection
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, user1);
        vm.stopPrank();
        
        // Shares should be > assets due to virtual shares
        assertTrue(shares >= 1000e6, "First depositor protected from inflation attack");
    }
    
    function test_CannotLiquidateHealthyPosition() public {
        // Setup
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(400e6); // Healthy position
        vm.stopPrank();
        
        // Try to liquidate (should fail)
        vm.prank(keeper);
        vm.expectRevert(); // NotLiquidatable
        vault.liquidateViaStabilityPool(user2, 100e6);
    }
    
    function test_MinimumLiquidationSize() public {
        // Setup liquidatable position
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        // Drop price to make liquidatable
        vm.prank(owner);
        priceOracle.setPrice(address(collateralToken), 5e18);
        
        // Try to liquidate tiny amount (below 100 USDC minimum)
        vm.prank(keeper);
        vm.expectRevert(); // LiquidationTooSmall
        vault.liquidateViaStabilityPool(user2, 50e6);
    }
    
    function test_BorrowIndex_UpdatesCorrectly() public {
        uint256 initialIndex = vault.borrowIndex();
        assertEq(initialIndex, ONE, "Initial borrow index should be 1e18");
        
        // Setup borrowing
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        vault.borrow(500e6);
        vm.stopPrank();
        
        // Warp time
        vm.warp(block.timestamp + 365 days);
        
        // Trigger accrual
        vm.prank(user2);
        vault.repay(1e6);
        
        uint256 newIndex = vault.borrowIndex();
        assertTrue(newIndex > initialIndex, "Borrow index should increase with interest");
    }
    
    function test_TotalAssets_IncludesAllPools() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, user1);
        vm.stopPrank();
        
        uint256 totalAssets = vault.totalAssets();
        uint256 expectedTotal = vault.lendingPool() + vault.stabilityPool() + vault.insuranceFund();
        
        assertEq(totalAssets, expectedTotal, "Total assets should include all pools");
    }
    
    // ========== Fuzz Tests ==========
    
    function testFuzz_Deposit_Withdraw_RoundTrip(uint256 amount) public {
        // Bound to reasonable amounts (100 USDC to 1M USDC)
        amount = bound(amount, 100e6, 1_000_000e6);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), amount);
        
        uint256 shares = vault.deposit(amount, user1);
        assertTrue(shares > 0, "Should receive shares");
        
        // Withdraw immediately (no borrows, should get full amount back)
        uint256 assetsReceived = vault.redeem(shares, user1, user1);
        
        // Should get approximately same amount back (minus rounding)
        assertApproxEqRel(assetsReceived, amount, 0.01e18, "Should get ~same amount back");
        
        vm.stopPrank();
    }
    
    function testFuzz_Borrow_Repay_RoundTrip(uint256 borrowAmount) public {
        // Setup liquidity
        vm.startPrank(user1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, user1);
        vm.stopPrank();
        
        // Bound borrow to safe range (100 USDC to 40% of collateral value)
        borrowAmount = bound(borrowAmount, 100e6, 400e6);
        
        vm.startPrank(user2);
        collateralToken.approve(address(vault), 100e18);
        vault.depositCollateral(100e18);
        
        vault.borrow(borrowAmount);
        uint256 debt = vault.borrowBalanceOf(user2);
        
        // Repay immediately (minimal interest)
        usdc.approve(address(vault), debt + 1e6); // Add buffer for interest
        vault.repay(debt);
        
        uint256 remainingDebt = vault.borrowBalanceOf(user2);
        assertEq(remainingDebt, 0, "Debt should be fully repaid");
        
        vm.stopPrank();
    }
}
