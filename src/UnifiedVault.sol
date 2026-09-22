// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Registry.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./interfaces/ILogicContracts.sol";
import "./interfaces/IRiskOracleViews.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IMarket.sol";

/**
 * @title UnifiedVault
 * @notice Single ERC4626 vault per token - handles lending, stability pool, and insurance
 * @dev Replaces 5 contracts (UnifiedVaultV2, VaultLedgerV2, StableVaultV2, StabilityPoolV2, SafetyModuleV2)
 * 
 * Key Features:
 * - Native ERC4626 (no overrides needed for withdraw/redeem)
 * - Holds ALL USDC for this token
 * - Internal allocation: 80% lending, 20% stability (insurance funded by interest)
 * - Risk-tiered interest splits (GREEN/YELLOW/RED)
 * - Auto-liquidation via stability pool
 * - Auto-sell seized collateral via Market
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract UnifiedVault is ERC4626, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========== CONSTANTS ==========
    uint256 public constant ONE = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Allocation ratios (basis points)
    uint256 public constant LENDING_RATIO = 8000;   // 80%
    uint256 public constant STABILITY_RATIO = 2000; // 20%
    uint256 public constant MAX_BPS = 10000;
    
    // Risk tiers
    uint8 public constant TIER_GREEN = 0;
    uint8 public constant TIER_YELLOW = 1;
    uint8 public constant TIER_RED = 2;
    
    // Interest splits per tier (protocol%, insurance%, lender%)
    // GREEN:  4% protocol, 6% insurance, 90% lenders
    // YELLOW: 6% protocol, 9% insurance, 85% lenders
    // RED:    10% protocol, 15% insurance, 75% lenders
    
    // Utilization caps
    uint256 public constant MAX_UTILIZATION = 85e16; // 85% hard cap
    uint256 public constant OPTIMAL_UTILIZATION = 70e16; // 70% target
    
    // Virtual shares for first depositor protection
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;
    
    // Stability pool constants
    uint256 public constant MIN_LIQUIDATION_SIZE = 100e6; // 100 USDC minimum
    
    // Risk-based deposit cap constants
    uint256 public constant MIN_LENDING_LIQUIDITY = 10_000e6; // 10k USDC minimum for borrowing
    
    // ========== STATE VARIABLES ==========
    
    // Core references
    IERC20 public immutable collateralToken;
    Registry public registry;
    
    // Internal pools (accounting only - all USDC held in this contract)
    uint256 public lendingPool;      // 80% of deposits - available for borrowing
    uint256 public stabilityPool;    // 20% of deposits - for auto-liquidations
    uint256 public insuranceFund;    // Funded by interest, not deposits
    
    // Lending state
    uint256 public totalBorrows;
    uint256 public borrowIndex;
    uint40 public lastAccrual;
    uint256 public protocolIncome;   // Accumulated protocol income (sent to FeeDistributor)
    
    // Risk parameters (can be adjusted by RiskOracle recommendations)
    uint256 public collateralFactor = 5e17;  // 50% for GREEN
    uint256 public liquidationThreshold = 6e17; // 60% for GREEN
    uint256 public liquidationBonus = 1e17;  // 10% bonus
    uint256 public protocolLiqFee = 2e16;    // 2% protocol fee on liquidations
    
    // User balances
    mapping(address => uint256) public collateralBalances;
    
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }
    mapping(address => BorrowSnapshot) public accountBorrows;
    
    // Stability pool state
    uint256 public totalCollateral;  // Seized collateral held
    uint256 public P = ONE;          // Product for loss accounting
    uint256 public S;                // Sum for collateral gain accounting
    uint256 public currentEpoch;
    uint256 public currentScale;
    
    struct StabilitySnapshot {
        uint256 P;
        uint256 S;
        uint256 epoch;
        uint256 scale;
    }
    mapping(address => StabilitySnapshot) public stabilitySnapshots;
    mapping(address => uint256) public collateralGains;
    mapping(address => uint256) public stabilityDeposits; // Track user's stability pool share
    
    // SECURITY FIX: Flash loan protection - track last deposit time
    mapping(address => uint256) public lastDepositTime;
    // Configurable: test default 5 minutes for fast iteration; production: 1 hour
    uint256 public MIN_DEPOSIT_DURATION = 5 minutes; // production: 1 hours
    
    // SECURITY FIX: Minimum deposit amount (prevents precision loss attacks)
    uint256 public constant MIN_DEPOSIT_AMOUNT = 100e6; // 100 USDC minimum
    
    // Activation control
    bool public isActive;
    
    // ========== EVENTS ==========
    
    // Lending events
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 newDebt);
    event Repay(address indexed payer, address indexed borrower, uint256 amount, uint256 remainingDebt);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 repayAmount,
        uint256 seizeAmount,
        bool viaStabilityPool
    );
    event InterestAccrued(uint256 interestAccumulated, uint256 newBorrowIndex, uint256 newTotalBorrows);
    event ProtocolIncomeCollected(uint256 amount);
    event BadDebtCovered(uint256 shortfall, uint256 fromInsurance);
    
    // Stability pool events
    event StabilityLiquidation(
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 remainingStability
    );
    event CollateralGainClaimed(address indexed user, uint256 amount);
    event CollateralListedForSale(uint256 indexed offerId, uint256 amount, uint256 price);
    event CollateralSold(uint256 usdcReceived);
    
    // Producer Exit events
    event InsuranceFundSwept(address indexed recipient, uint256 amount);
    
    // FeeDistributor events
    event InsuranceFundDeposit(address indexed depositor, uint256 amount);
    
    // Pool allocation events
    event PoolsAllocated(uint256 toLending, uint256 toStability);
    event PoolsReduced(uint256 fromLending, uint256 fromStability);
    
    // ========== ERRORS ==========
    
    error NotActive();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientLiquidity();
    error UtilizationTooHigh();
    error Undercollateralized();
    error NotLiquidatable();
    error LiquidationTooSmall();
    error NotAuthorized();
    error DepositCapExceeded();
    error BorrowCapExceeded();
    error BelowMinLendingLiquidity();
    error OracleFailure();
    
    // ========== CONSTRUCTOR ==========
    
    constructor(
        address _owner,
        address _collateralToken,
        string memory _name,
        string memory _symbol,
        address _registry
    ) ERC4626(IERC20(_getUsdcFromRegistry(_registry))) ERC20(_name, _symbol) {
        require(_owner != address(0), "Invalid owner");
        require(_collateralToken != address(0), "Invalid collateral token");
        require(_registry != address(0), "Invalid registry");
        
        _transferOwnership(_owner);
        collateralToken = IERC20(_collateralToken);
        registry = Registry(_registry);
        
        borrowIndex = ONE;
        lastAccrual = uint40(block.timestamp);
        isActive = true;
    }
    
    // Helper function to get USDC from Registry during construction
    function _getUsdcFromRegistry(address _registry) private view returns (address) {
        address usdc = Registry(_registry).usdc();
        require(usdc != address(0), "USDC not set in Registry");
        return usdc;
    }
    
    // ========== MODIFIERS ==========
    
    modifier onlyActive() {
        if (!isActive) revert NotActive();
        _;
    }
    
    modifier accrueInterest() {
        _accrueInterest();
        _;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function setActive(bool _isActive) external onlyOwner {
        isActive = _isActive;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    function updateRiskParameters(
        uint256 _collateralFactor,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus
    ) external onlyOwner {
        require(_collateralFactor <= ONE, "CF too high");
        require(_liquidationThreshold <= ONE, "LT too high");
        require(_liquidationThreshold > _collateralFactor, "LT must > CF");
        
        collateralFactor = _collateralFactor;
        liquidationThreshold = _liquidationThreshold;
        liquidationBonus = _liquidationBonus;
    }

    /**
     * @notice Set minimum deposit duration (flash loan protection)
     * @dev Test default: 5 minutes for fast iteration; production: 1 hour
     * @param _minDepositDuration Minimum time between deposit and withdraw in seconds
     */
    function setMinDepositDuration(uint256 _minDepositDuration) external onlyOwner {
        require(_minDepositDuration >= 1 minutes && _minDepositDuration <= 7 days, "Invalid duration");
        MIN_DEPOSIT_DURATION = _minDepositDuration;
        emit MinDepositDurationUpdated(_minDepositDuration);
    }

    event MinDepositDurationUpdated(uint256 minDepositDuration);
    
    // ========== ERC4626 OVERRIDES ==========
    
    function deposit(uint256 assets, address receiver) 
        public 
        override 
        nonReentrant 
        whenNotPaused 
        onlyActive
        returns (uint256 shares) 
    {
        // SECURITY FIX: Minimum deposit check (bypass for FeeDistributor and Market)
        address feeDistributor = registry.feeDistributor();
        address market = registry.market();
        if (msg.sender != feeDistributor && msg.sender != market) {
            require(assets >= MIN_DEPOSIT_AMOUNT, "Deposit below minimum");
        }
        
        // Check deposit cap
        if (assets > maxDeposit(receiver)) revert DepositCapExceeded();
        
        shares = super.deposit(assets, receiver);
        
        // Internal allocation (80/20 split)
        uint256 toLending = (assets * LENDING_RATIO) / MAX_BPS;
        uint256 toStability = assets - toLending;
        
        lendingPool += toLending;
        stabilityPool += toStability;
        
        // Track user's stability pool share for collateral gains
        stabilityDeposits[receiver] += toStability;
        _updateStabilitySnapshot(receiver);
        
        // SECURITY FIX: Track deposit time for flash loan protection
        lastDepositTime[receiver] = block.timestamp;
        
        emit PoolsAllocated(toLending, toStability);
    }
    
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        onlyActive
        returns (uint256 assets)
    {
        // SECURITY FIX: Minimum deposit check (bypass for FeeDistributor and Market)
        address feeDistributor = registry.feeDistributor();
        address market = registry.market();
        assets = previewMint(shares);
        if (msg.sender != feeDistributor && msg.sender != market) {
            require(assets >= MIN_DEPOSIT_AMOUNT, "Deposit below minimum");
        }
        
        // Check mint cap
        if (shares > maxMint(receiver)) revert DepositCapExceeded();
        
        assets = super.mint(shares, receiver);
        
        // Internal allocation (80/20 split)
        uint256 toLending = (assets * LENDING_RATIO) / MAX_BPS;
        uint256 toStability = assets - toLending;
        
        lendingPool += toLending;
        stabilityPool += toStability;
        
        stabilityDeposits[receiver] += toStability;
        _updateStabilitySnapshot(receiver);
        
        // SECURITY FIX: Track deposit time for flash loan protection
        lastDepositTime[receiver] = block.timestamp;
        
        emit PoolsAllocated(toLending, toStability);
    }
    
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // Check liquidity
        uint256 available = _getAvailableLiquidity();
        if (assets > available) revert InsufficientLiquidity();
        
        shares = super.withdraw(assets, receiver, owner);
        
        // Reduce internal pools proportionally
        _reducePoolsProportionally(assets, owner);
    }
    
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = previewRedeem(shares);
        
        // Check liquidity
        uint256 available = _getAvailableLiquidity();
        if (assets > available) revert InsufficientLiquidity();
        
        assets = super.redeem(shares, receiver, owner);
        
        // Reduce internal pools proportionally
        _reducePoolsProportionally(assets, owner);
    }
    
    function _reducePoolsProportionally(uint256 assets, address user) internal {
        uint256 totalPools = lendingPool + stabilityPool;
        if (totalPools == 0) return;
        
        // FIX (#2): Update user's collateral gains BEFORE reducing their stability deposit
        // This ensures users don't lose unclaimed gains when withdrawing
        _updateUserCollateralGains(user);
        
        uint256 fromLending = (assets * lendingPool) / totalPools;
        uint256 fromStability = assets - fromLending;
        
        // Ensure we don't underflow
        if (fromLending > lendingPool) {
            fromLending = lendingPool;
            fromStability = assets - fromLending;
        }
        if (fromStability > stabilityPool) {
            fromStability = stabilityPool;
            fromLending = assets - fromStability;
        }
        
        lendingPool -= fromLending;
        stabilityPool -= fromStability;
        
        // Update user's stability deposit tracking
        if (stabilityDeposits[user] >= fromStability) {
            stabilityDeposits[user] -= fromStability;
        } else {
            stabilityDeposits[user] = 0;
        }
        
        emit PoolsReduced(fromLending, fromStability);
    }
    
    // Virtual shares for first depositor protection
    function _convertToShares(uint256 assets, Math.Rounding rounding) 
        internal view override returns (uint256) 
    {
        return assets.mulDiv(
            totalSupply() + VIRTUAL_SHARES, 
            totalAssets() + VIRTUAL_ASSETS, 
            rounding
        );
    }
    
    function _convertToAssets(uint256 shares, Math.Rounding rounding) 
        internal view override returns (uint256) 
    {
        return shares.mulDiv(
            totalAssets() + VIRTUAL_ASSETS, 
            totalSupply() + VIRTUAL_SHARES, 
            rounding
        );
    }
    
    function totalAssets() public view override returns (uint256) {
        // Total USDC = pools + insurance - borrowed
        return lendingPool + stabilityPool + insuranceFund;
    }
    
    /**
     * @notice Maximum deposit allowed based on risk tier cap
     * @dev Returns 0 if vault is inactive, paused, or at/over cap
     */
    // Fallback cap when oracle is not set (conservative default)
    uint256 public constant FALLBACK_SUPPLY_CAP = 1_000_000e6; // 1M USDC
    
    function maxDeposit(address) public view override returns (uint256) {
        if (!isActive || paused()) return 0;
        
        address riskOracle = registry.riskOracle();
        if (riskOracle == address(0)) {
            // No oracle = use conservative fallback cap
            uint256 current = totalAssets();
            if (current >= FALLBACK_SUPPLY_CAP) return 0;
            return FALLBACK_SUPPLY_CAP - current;
        }
        
        try IRiskOracle(riskOracle).getRecommendedSupplyCap(address(collateralToken)) returns (uint256 cap) {
            uint256 current = totalAssets();
            if (current >= cap) return 0;
            return cap - current;
        } catch {
            // Oracle failure = fail closed (no deposits allowed)
            return 0;
        }
    }
    
    /**
     * @notice Maximum shares that can be minted based on risk tier cap
     */
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return _convertToShares(maxAssets, Math.Rounding.Down);
    }
    
    // ========== LENDING FUNCTIONS ==========
    
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused onlyActive {
        if (amount == 0) revert ZeroAmount();
        
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalances[msg.sender] += amount;
        
        emit DepositCollateral(msg.sender, amount);
    }
    
    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused onlyActive accrueInterest {
        if (amount == 0) revert ZeroAmount();
        if (amount > collateralBalances[msg.sender]) revert InsufficientBalance();
        
        collateralBalances[msg.sender] -= amount;
        
        // Check health factor after withdrawal
        uint256 health = _getAccountHealth(msg.sender);
        if (health < ONE) revert Undercollateralized();
        
        collateralToken.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }
    
    function borrow(uint256 amount) external nonReentrant whenNotPaused onlyActive accrueInterest {
        if (amount == 0) revert ZeroAmount();
        
        // Check minimum lending liquidity (dynamic, proportional to campaign size)
        address riskOracle = registry.riskOracle();
        uint256 minLiquidity = riskOracle != address(0) 
            ? IRiskOracle(riskOracle).getMinLendingLiquidity(address(collateralToken))
            : MIN_LENDING_LIQUIDITY; // Fallback to 10k if no oracle
        
        if (lendingPool < minLiquidity) revert BelowMinLendingLiquidity();
        
        // Check available liquidity in lending pool
        if (amount > lendingPool) revert InsufficientLiquidity();
        
        // Check risk-based borrow cap and borrowing allowed status
        _checkBorrowAllowed(amount);
        
        // Block borrows when oracle price is unreliable (stale/low volume)
        // Defense-in-depth: RiskOracle RED tier also blocks, but this catches edge cases
        {
            (, bool priceReliable) = _getCollateralPrice();
            if (!priceReliable) revert OracleFailure();
        }
        
        // Check utilization cap
        uint256 newTotalBorrows = totalBorrows + amount;
        uint256 newUtilization = (newTotalBorrows * ONE) / (lendingPool + totalBorrows);
        if (newUtilization > MAX_UTILIZATION) revert UtilizationTooHigh();
        
        // Update borrow snapshot
        BorrowSnapshot storage snapshot = accountBorrows[msg.sender];
        uint256 currentDebt = _borrowBalanceStored(msg.sender);
        
        snapshot.principal = currentDebt + amount;
        snapshot.interestIndex = borrowIndex;
        
        totalBorrows += amount;
        lendingPool -= amount;
        
        // Check health factor
        uint256 health = _getAccountHealth(msg.sender);
        if (health < ONE) revert Undercollateralized();
        
        // Transfer USDC to borrower
        IERC20(asset()).safeTransfer(msg.sender, amount);
        
        emit Borrow(msg.sender, amount, snapshot.principal);
    }
    
    function repay(uint256 amount) external nonReentrant whenNotPaused accrueInterest {
        _repay(msg.sender, msg.sender, amount);
    }
    
    function repayFor(address borrower, uint256 amount) external nonReentrant whenNotPaused accrueInterest {
        _repay(msg.sender, borrower, amount);
    }
    
    function _repay(address payer, address borrower, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        
        uint256 currentDebt = _borrowBalanceStored(borrower);
        if (currentDebt == 0) revert ZeroAmount();
        
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        
        // Transfer USDC from payer
        IERC20(asset()).safeTransferFrom(payer, address(this), repayAmount);
        
        // Update state
        BorrowSnapshot storage snapshot = accountBorrows[borrower];
        snapshot.principal = currentDebt - repayAmount;
        snapshot.interestIndex = borrowIndex;
        
        totalBorrows -= repayAmount;
        lendingPool += repayAmount;
        
        emit Repay(payer, borrower, repayAmount, snapshot.principal);
    }
    
    // ========== LIQUIDATION FUNCTIONS ==========
    
    function liquidate(address borrower, uint256 repayAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        accrueInterest 
        returns (uint256 seizeAmount) 
    {
        if (repayAmount < MIN_LIQUIDATION_SIZE) revert LiquidationTooSmall();
        if (_getAccountHealth(borrower) >= ONE) revert NotLiquidatable();
        
        uint256 currentDebt = _borrowBalanceStored(borrower);
        uint256 actualRepay = repayAmount > currentDebt ? currentDebt : repayAmount;
        
        // Use external logic contract for liquidation calculation
        // Liquidation proceeds even with unreliable (decayed) price — protects lenders
        (uint256 collateralPrice, ) = _getCollateralPrice();
        (seizeAmount, actualRepay) = _getLendingLogic().calculateLiquidation(
            actualRepay,
            liquidationBonus,
            collateralPrice,
            collateralBalances[borrower]
        );
        
        // Execute liquidation
        _executeLiquidation(borrower, actualRepay, seizeAmount, false);
    }
    
    function _executeLiquidation(
        address borrower, 
        uint256 repayAmount, 
        uint256 seizeAmount,
        bool viaStabilityPool
    ) internal {
        uint256 protocolFee = (seizeAmount * protocolLiqFee) / ONE;
        uint256 liquidatorAmount = seizeAmount - protocolFee;
        
        // Update borrower state
        uint256 currentDebt = _borrowBalanceStored(borrower);
        accountBorrows[borrower].principal = currentDebt - repayAmount;
        accountBorrows[borrower].interestIndex = borrowIndex;
        collateralBalances[borrower] -= seizeAmount;
        
        totalBorrows -= repayAmount;
        
        if (viaStabilityPool) {
            // FIX (#1): Capture stabilityPool BEFORE deduction for correct gain calculation
            uint256 stabilityPoolBeforeDeduction = stabilityPool;
            stabilityPool -= repayAmount;
            lendingPool += repayAmount;
            totalCollateral += seizeAmount;
            _updateStabilityPoolState(stabilityPoolBeforeDeduction, seizeAmount);
        } else {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), repayAmount);
            lendingPool += repayAmount;
            collateralToken.safeTransfer(msg.sender, liquidatorAmount);
            totalCollateral += protocolFee;
        }
        
        emit Liquidate(viaStabilityPool ? address(this) : msg.sender, borrower, repayAmount, seizeAmount, viaStabilityPool);
    }
    
    /**
     * @notice Liquidate using stability pool funds
     * @dev Called internally or by keeper when stability pool has funds
     */
    function liquidateViaStabilityPool(address borrower, uint256 repayAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        accrueInterest 
        returns (uint256 seizeAmount) 
    {
        // Only keeper or owner can trigger stability pool liquidations
        if (msg.sender != _getKeeper() && msg.sender != owner()) revert NotAuthorized();
        if (repayAmount < MIN_LIQUIDATION_SIZE) revert LiquidationTooSmall();
        if (_getAccountHealth(borrower) >= ONE) revert NotLiquidatable();
        
        // Cap at stability pool and current debt
        uint256 actualRepay = repayAmount;
        if (actualRepay > stabilityPool) actualRepay = stabilityPool;
        uint256 currentDebt = _borrowBalanceStored(borrower);
        if (actualRepay > currentDebt) actualRepay = currentDebt;
        
        // Use external logic contract for liquidation calculation
        // Liquidation proceeds even with unreliable (decayed) price — protects lenders
        (uint256 collateralPrice, ) = _getCollateralPrice();
        (seizeAmount, actualRepay) = _getLendingLogic().calculateLiquidation(
            actualRepay,
            liquidationBonus,
            collateralPrice,
            collateralBalances[borrower]
        );
        
        // Execute liquidation via stability pool
        _executeLiquidation(borrower, actualRepay, seizeAmount, true);
        emit StabilityLiquidation(borrower, actualRepay, seizeAmount, stabilityPool);
    }
    
    // ========== STABILITY POOL FUNCTIONS ==========
    
    /**
     * @notice Update stability pool state after liquidation
     * @dev FIX (#1): Now receives pre-deduction stabilityPool value for correct calculation
     * @param stabilityPoolPreDeduction The stabilityPool value BEFORE the repayAmount was deducted
     * @param collateralGained Amount of collateral seized in liquidation
     */
    function _updateStabilityPoolState(uint256 stabilityPoolPreDeduction, uint256 collateralGained) internal {
        if (stabilityPoolPreDeduction == 0) return;
        
        // Update S (collateral gain per unit) - use pre-deduction value as denominator
        // This correctly distributes gains to all stability depositors at time of liquidation
        uint256 collateralGainPerUnit = (collateralGained * ONE) / stabilityPoolPreDeduction;
        S += collateralGainPerUnit;
        
        // P doesn't change since USDC moves internally (no loss to depositors)
    }
    
    function _updateStabilitySnapshot(address user) internal {
        stabilitySnapshots[user] = StabilitySnapshot({
            P: P,
            S: S,
            epoch: currentEpoch,
            scale: currentScale
        });
    }
    
    function claimCollateralGains() external nonReentrant {
        _updateUserCollateralGains(msg.sender);
        
        uint256 gain = collateralGains[msg.sender];
        if (gain == 0) revert ZeroAmount();
        
        collateralGains[msg.sender] = 0;
        totalCollateral -= gain;
        
        collateralToken.safeTransfer(msg.sender, gain);
        
        emit CollateralGainClaimed(msg.sender, gain);
    }
    
    function _updateUserCollateralGains(address user) internal {
        if (stabilityDeposits[user] == 0) return;
        
        // SECURITY FIX: Flash loan protection - users must wait before benefiting from liquidations
        if (block.timestamp < lastDepositTime[user] + MIN_DEPOSIT_DURATION) {
            return; // Skip gains update if deposit too recent
        }
        
        StabilitySnapshot storage snapshot = stabilitySnapshots[user];
        uint256 userDeposit = stabilityDeposits[user];
        
        // Calculate pending collateral gain
        if (S > snapshot.S) {
            uint256 pendingGain = (userDeposit * (S - snapshot.S)) / ONE;
            if (pendingGain > 0) {
                collateralGains[user] += pendingGain;
            }
        }
        
        // Update snapshot
        _updateStabilitySnapshot(user);
    }
    
    /**
     * @notice Auto-sell seized collateral via Market by filling existing buy offers
     * @dev FIX (#4): Iterates through buy offers and fills them to convert collateral to USDC
     *      Remainder stays in totalCollateral for next keeper run
     * @param maxAmount Maximum amount of collateral to sell
     * @return sold Amount of collateral actually sold
     * @return usdcReceived Amount of USDC received
     */
    function autoSellCollateral(uint256 maxAmount) external nonReentrant returns (uint256 sold, uint256 usdcReceived) {
        address keeper = _getKeeper();
        if (msg.sender != keeper && msg.sender != owner()) revert NotAuthorized();
        
        if (maxAmount > totalCollateral) maxAmount = totalCollateral;
        if (maxAmount == 0) return (0, 0);
        
        address market = _getMarket();
        require(market != address(0), "Market not set");
        
        // Get current price for minimum acceptable price (5% discount)
        (uint256 price, ) = _getCollateralPrice();
        uint256 minAcceptablePrice = (price * 95) / 100;
        
        // Get token offers from Market
        uint256[] memory offerIds = IMarketView(market).getTokenOffers(address(collateralToken));
        uint256 len = offerIds.length;
        
        if (len == 0) return (0, 0);
        
        uint256 remaining = maxAmount;
        uint256 usdcBefore = IERC20(asset()).balanceOf(address(this));
        
        // Approve Market for collateral transfer
        collateralToken.approve(market, maxAmount);
        
        // Iterate from end (most recent offers) to find buy offers
        uint256 checked = 0;
        uint256 maxToCheck = 50; // Gas limit
        
        for (uint256 i = len; i > 0 && remaining > 0 && checked < maxToCheck; i--) {
            uint256 offerId = offerIds[i - 1];
            checked++;
            
            // Get offer details
            (
                , // offerId
                , // token
                , // paymentToken
                uint8 offerType,
                , // creator
                uint256 tokenAmount,
                uint256 pricePerToken,
                uint256 filledAmount,
                , // escrowedAmount
                uint8 status,
                , // createdAt
                  // isBuyback
            ) = IMarketView(market).offers(offerId);
            
            // Skip if not a buy offer, not open, or price too low
            if (offerType != 1 || status != 1) continue; // 1 = OFFER_BUY, 1 = STATUS_OPEN
            if (pricePerToken < minAcceptablePrice) continue;
            
            uint256 offerRemaining = tokenAmount - filledAmount;
            if (offerRemaining == 0) continue;
            
            // Calculate how much to fill
            uint256 toFill = remaining > offerRemaining ? offerRemaining : remaining;
            
            // Fill the buy offer (we are the seller)
            try IMarketFill(market).fillBuyOffer(offerId, toFill) {
                remaining -= toFill;
            } catch {
                // If fill fails, continue to next offer
                continue;
            }
        }
        
        // Reset approval
        collateralToken.approve(market, 0);
        
        // Calculate actual amounts
        sold = maxAmount - remaining;
        usdcReceived = IERC20(asset()).balanceOf(address(this)) - usdcBefore;
        
        // Update state
        if (sold > 0) {
            totalCollateral -= sold;
            // Add USDC to stability pool (replenishes liquidity)
            stabilityPool += usdcReceived;
            emit CollateralSold(usdcReceived);
        }
    }
    
    
    // ========== INTEREST ACCRUAL ==========
    
    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrual;
        
        if (elapsed == 0 || totalBorrows == 0) {
            lastAccrual = uint40(block.timestamp);
            return;
        }
        
        // CRITICAL GAS OPTIMIZATION: Cache risk tier to avoid duplicate external calls
        // _getRiskTier() was called twice (lines 825 & 839), each triggering expensive RiskOracle calls
        uint8 tier = _getRiskTier();
        
        // Use external logic contract for interest calculation with tier-aware rate
        uint256 borrowRatePerSecond = _getRateModel().getBorrowRatePerSecond(_getUtilization(), tier);
        (uint256 interestAccumulated, uint256 newBorrowIndex) = _getInterestLogic().calculateInterest(
            totalBorrows,
            borrowRatePerSecond,
            elapsed,
            borrowIndex
        );
        
        // Use external logic contract for interest distribution (reuse cached tier)
        (uint256 toProtocol, uint256 toInsurance, ) = _getInterestLogic().distributeInterest(
            interestAccumulated,
            tier
        );
        
        protocolIncome += toProtocol;
        insuranceFund += toInsurance;
        totalBorrows += interestAccumulated;
        borrowIndex = newBorrowIndex;
        lastAccrual = uint40(block.timestamp);
        
        emit InterestAccrued(interestAccumulated, borrowIndex, totalBorrows);
    }
    
    // ========== FEE DISTRIBUTOR FUNCTIONS ==========
    
    /**
     * @notice Deposit directly to insurance fund (only FeeDistributor can call)
     * @dev Used when normal deposit fails due to capacity limits
     *      Insurance fund doesn't mint shares - it's protocol-owned buffer
     * @param amount Amount of USDC to deposit to insurance fund
     */
    function depositToInsuranceFund(uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender == _getFeeDistributor(), "Only FeeDistributor");
        if (amount == 0) revert ZeroAmount();
        
        // Transfer USDC from FeeDistributor
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        
        // Add directly to insurance fund
        insuranceFund += amount;
        
        emit InsuranceFundDeposit(msg.sender, amount);
    }
    
    // ========== PROTOCOL INCOME COLLECTION ==========
    
    /**
     * @notice Collect protocol income (called by FeeDistributor)
     * @return collected Amount of USDC collected
     */
    function collectProtocolIncome() external nonReentrant returns (uint256 collected) {
        address feeDistributor = _getFeeDistributor();
        require(msg.sender == feeDistributor || msg.sender == owner(), "Not authorized");
        
        _accrueInterest();
        
        collected = protocolIncome;
        if (collected > 0) {
            protocolIncome = 0;
            IERC20(asset()).safeTransfer(msg.sender, collected);
            emit ProtocolIncomeCollected(collected);
        }
    }
    
    // ========== PRODUCER EXIT ==========
    
    /**
     * @notice Sweep insurance fund to recipient (called by FeeDistributor during Producer Exit)
     * @dev Only FeeDistributor can call this function
     * @param recipient Address to receive the insurance fund
     * @return swept Amount of USDC swept
     */
    function sweepInsuranceFund(address recipient) external nonReentrant returns (uint256 swept) {
        require(msg.sender == _getFeeDistributor(), "Not authorized");
        // Defense-in-depth: ensure no outstanding borrows before sweeping
        require(totalBorrows == 0, "Outstanding borrows");
        
        swept = insuranceFund;
        if (swept > 0) {
            insuranceFund = 0;
            IERC20(asset()).safeTransfer(recipient, swept);
            emit InsuranceFundSwept(recipient, swept);
        }
    }
    
    // ========== BAD DEBT COVERAGE ==========
    
    /**
     * @notice Cover bad debt using insurance fund
     * @param shortfall Amount of bad debt to cover
     */
    function coverBadDebt(uint256 shortfall) external nonReentrant {
        address keeper = _getKeeper();
        require(msg.sender == keeper || msg.sender == owner(), "Not authorized");
        
        uint256 fromInsurance = shortfall > insuranceFund ? insuranceFund : shortfall;
        
        if (fromInsurance > 0) {
            insuranceFund -= fromInsurance;
            // Bad debt is written off by reducing totalBorrows
            totalBorrows -= fromInsurance;
        }
        
        emit BadDebtCovered(shortfall, fromInsurance);
    }
    
    function getBadDebt() external view returns (uint256) {
        uint256 assets = lendingPool + stabilityPool + insuranceFund;
        return totalBorrows > assets ? totalBorrows - assets : 0;
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    function _borrowBalanceStored(address account) internal view returns (uint256) {
        BorrowSnapshot storage snapshot = accountBorrows[account];
        if (snapshot.principal == 0) return 0;
        return (snapshot.principal * borrowIndex) / snapshot.interestIndex;
    }
    
    function _getAccountHealth(address account) internal view returns (uint256) {
        uint256 debt = _borrowBalanceStored(account);
        if (debt == 0) return type(uint256).max;
        
        uint256 collateral = collateralBalances[account];
        if (collateral == 0) return 0;
        
        (uint256 price, ) = _getCollateralPrice();
        uint256 collateralValue = (collateral * price) / ONE;
        uint256 maxBorrow = (collateralValue * liquidationThreshold) / ONE;
        
        return (maxBorrow * ONE) / debt;
    }
    
    function _getUtilization() internal view returns (uint256) {
        uint256 totalLiquidity = lendingPool + totalBorrows;
        if (totalLiquidity == 0) return 0;
        return (totalBorrows * ONE) / totalLiquidity;
    }
    
    /**
     * @notice Get current utilization rate (public for RiskOracle)
     * @return Utilization scaled 1e18 (0 to 1e18)
     */
    function getUtilization() external view returns (uint256) {
        return _getUtilization();
    }
    
    /**
     * @notice Get current borrow rate per second
     * @return Borrow rate scaled 1e18
     */
    function getBorrowRate() external view returns (uint256) {
        uint8 tier = _getRiskTier();
        return _getRateModel().getBorrowRatePerSecond(_getUtilization(), tier);
    }
    
    /**
     * @notice Get borrow balance for an account (includes accrued interest)
     * @param account Borrower address
     * @return Current borrow balance
     */
    function borrowBalanceOf(address account) external view returns (uint256) {
        return _borrowBalanceStored(account);
    }
    
    /**
     * @notice Get health factor for an account
     * @param account Borrower address
     * @return Health factor scaled 1e18 (< 1e18 means liquidatable)
     */
    function getHealthFactor(address account) external view returns (uint256) {
        return _getAccountHealth(account);
    }
    
    function _getAvailableLiquidity() internal view returns (uint256) {
        return lendingPool + stabilityPool + insuranceFund;
    }
    
    /**
     * @notice Public function to accrue interest (can be called by keeper)
     */
    function triggerAccrueInterest() external {
        _accrueInterest();
    }
    
    function getPoolBalances() external view returns (
        uint256 lending,
        uint256 stability,
        uint256 insurance,
        uint256 borrows
    ) {
        return (lendingPool, stabilityPool, insuranceFund, totalBorrows);
    }
    
    function getUserPosition(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 health,
        uint256 stabilityDeposit,
        uint256 pendingCollateralGain
    ) {
        collateral = collateralBalances[user];
        debt = _borrowBalanceStored(user);
        health = _getAccountHealth(user);
        stabilityDeposit = stabilityDeposits[user];
        pendingCollateralGain = collateralGains[user];
    }
    
    // ========== INTERNAL HELPERS ==========
    
    function _getCollateralPrice() internal view returns (uint256 price, bool reliable) {
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle == address(0)) revert OracleFailure();
        
        (price, reliable) = IPriceOracle(priceOracle).getPrice(address(collateralToken));
        if (price == 0) revert OracleFailure();
        // Returns actual price (including decayed) and reliability flag
        // Callers decide behavior: borrow blocks on unreliable, liquidation proceeds
    }
    
    function _getRiskTier() internal view returns (uint8) {
        address riskOracle = registry.riskOracle();
        if (riskOracle == address(0)) return TIER_GREEN;
        
        try IRiskOracle(riskOracle).getRiskTier(address(collateralToken)) returns (uint8 tier) {
            return tier;
        } catch {
            return TIER_GREEN;
        }
    }
    
    /**
     * @notice Check if borrowing is allowed based on risk tier and caps
     * @dev Reverts if borrowing is blocked or would exceed borrow cap
     */
    function _checkBorrowAllowed(uint256 amount) internal view {
        address riskOracle = registry.riskOracle();
        if (riskOracle == address(0)) return; // No oracle = no restrictions
        
        // Check if borrowing is allowed for this token (RED tier blocks borrowing)
        try IRiskOracle(riskOracle).isBorrowingAllowed(address(collateralToken)) returns (bool allowed) {
            if (!allowed) revert BorrowCapExceeded();
        } catch {
            // Oracle failure = fail closed (block borrowing)
            revert OracleFailure();
        }
        
        // Check if totalAssets exceeds supply cap (explicit block per doc section 4)
        try IRiskOracle(riskOracle).getRecommendedSupplyCap(address(collateralToken)) returns (uint256 supplyCap) {
            if (totalAssets() > supplyCap) revert BorrowCapExceeded();
        } catch {
            // Oracle failure = fail closed (block borrowing)
            revert OracleFailure();
        }
        
        // Check borrow cap
        try IRiskOracle(riskOracle).getRecommendedBorrowCap(address(collateralToken)) returns (uint256 borrowCap) {
            if (totalBorrows + amount > borrowCap) revert BorrowCapExceeded();
        } catch {
            // Oracle failure = fail closed (block borrowing)
            revert OracleFailure();
        }
    }
    
    function _getRateModel() internal view returns (IRateModel) {
        address rateModel = registry.rateModel();
        require(rateModel != address(0), "Rate model not set");
        return IRateModel(rateModel);
    }
    
    function _getFeeDistributor() internal view returns (address) {
        return registry.feeDistributor();
    }
    
    function _getKeeper() internal view returns (address) {
        return registry.keeper();
    }
    
    function _getMarket() internal view returns (address) {
        return registry.market();
    }
    
    function _getInterestLogic() internal view returns (IInterestLogic) {
        address logic = registry.interestLogic();
        require(logic != address(0), "InterestLogic not set");
        return IInterestLogic(logic);
    }
    
    function _getLendingLogic() internal view returns (ILendingLogic) {
        address logic = registry.lendingLogic();
        require(logic != address(0), "LendingLogic not set");
        return ILendingLogic(logic);
    }
    
}
