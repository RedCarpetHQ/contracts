// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Registry.sol";
import "./interfaces/IContest.sol";
import "./interfaces/IUnifiedVault.sol";
import "./interfaces/ILendingInterfaces.sol";

/**
 * @title FeeDistributor
 * @notice Central contract for distributing all protocol fees
 * @dev Receives fees from Market (trading) and UnifiedVaults (interest)
 *      Distributes according to fixed split:
 *      - 40% → FEE_SAFE_ADDRESS (protocol treasury)
 *      - 40% → Contest (trading competition)
 *      - 10% → UnifiedVault (protocol's allocation)
 *      - 10% → Producer (token creator)
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract FeeDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== CONSTANTS ==========
    
    // Fee split percentages (basis points)
    uint256 public constant FEE_SAFE_BPS = 4000;    // 40%
    uint256 public constant CONTEST_BPS = 4000;      // 40%
    uint256 public constant VAULT_BPS = 1000;        // 10%
    uint256 public constant PRODUCER_BPS = 1000;     // 10%
    uint256 public constant MAX_BPS = 10000;
    
    // Producer Exit constants
    uint256 public constant EXIT_THRESHOLD = 10e6;  // 10 USDC (6 decimals)
    uint256 public constant EXIT_FEE_BPS = 2500;    // 25% fee on exit reward
    
    // ========== STATE VARIABLES ==========
    
    Registry public registry;
    
    // Fee tracking per token
    struct TokenFeeData {
        uint256 totalFeesReceived;
        uint256 toFeeSafe;
        uint256 toContest;
        uint256 toVault;
        uint256 toProducer;
        uint256 producerClaimed;
    }
    mapping(address => TokenFeeData) public tokenFees;
    
    // Pending contest fees per token per epoch
    mapping(address => mapping(uint32 => uint256)) public pendingContestFees;
    
    // Track max epoch seen per token (for Producer Exit sweep)
    mapping(address => uint32) public maxEpochSeen;
    
    // Creator fee payments per token per epoch
    struct CreatorFeePayment {
        uint32 epoch;
        uint256 amount;
        uint256 timestamp;
        address recipient;
    }
    mapping(address => CreatorFeePayment[]) public creatorFeePayments;
    
    // Pending creator fees per token per epoch (accumulated until epoch end)
    mapping(address => mapping(uint32 => uint256)) public pendingCreatorFees;
    
    // Pending vault deposits per token (for retry on failure)
    mapping(address => uint256) public pendingVaultDeposits;
    
    // Insurance fund deposits per token (when normal deposit fails due to capacity)
    mapping(address => uint256) public insuranceFundDeposits;
    
    // Protocol vault shares per token (for Producer Exit feature)
    mapping(address => uint256) public protocolVaultShares;
    
    // Total stats
    uint256 public totalFeesDistributed;
    
    // ========== EVENTS ==========
    
    event FeesReceived(address indexed token, address indexed source, uint256 amount);
    event FeesDistributed(
        address indexed token,
        uint256 amount,
        uint256 toFeeSafe,
        uint256 toContest,
        uint256 toVault,
        uint256 toProducer
    );
    event ContestFeesDeposited(address indexed token, uint32 indexed epoch, uint256 amount);
    event ProducerRewardClaimed(address indexed token, address indexed producer, uint256 amount);
    event CreatorFeePaid(address indexed token, uint32 indexed epoch, address indexed recipient, uint256 amount);
    event VaultAllocationDeposited(address indexed token, address indexed vault, uint256 amount);
    event ExitRewardClaimed(address indexed token, address indexed producer, uint256 amount);
    event ProtocolSharesWithdrawn(address indexed token, uint256 shares, uint256 assets, address indexed recipient);
    event VaultDepositRetried(address indexed token, uint256 amount, bool success);
    event PendingVaultDepositRecorded(address indexed token, uint256 amount);
    event InsuranceFundDepositMade(address indexed token, address indexed vault, uint256 amount);
    
    // ========== ERRORS ==========
    
    error NotAuthorized();
    error ZeroAmount();
    error NothingToClaim();
    error InvalidAddress();
    error OutstandingBorrows();
    error SupplyNotBurned();
    error InsufficientShares();
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _owner, address _registry) {
        require(_owner != address(0), "Invalid owner");
        require(_registry != address(0), "Invalid registry");
        
        _transferOwnership(_owner);
        registry = Registry(_registry);
    }

    /**
     * @notice Get USDC token from Registry (single source of truth)
     * @return USDC token interface
     */
    function usdc() public view returns (IERC20) {
        address usdcAddress = registry.usdc();
        require(usdcAddress != address(0), "USDC not set in Registry");
        return IERC20(usdcAddress);
    }

    /**
     * @dev Internal helper to get USDC from Registry
     */
    function _usdc() internal view returns (IERC20) {
        address usdcAddress = registry.usdc();
        require(usdcAddress != address(0), "USDC not set in Registry");
        return IERC20(usdcAddress);
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    // ========== FEE DISTRIBUTION ==========
    
    /**
     * @notice Receive and distribute fees for a token
     * @dev Called by Market (trading fees) or UnifiedVault (protocol income)
     * @param token Campaign token address
     * @param amount USDC amount to distribute
     */
    function distributeFees(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        
        // Verify caller is authorized (Market or UnifiedVault for this token)
        if (!_isAuthorizedSource(msg.sender, token)) revert NotAuthorized();
        
        // Transfer USDC from caller
        _usdc().safeTransferFrom(msg.sender, address(this), amount);
        
        emit FeesReceived(token, msg.sender, amount);
        
        // Calculate splits
        uint256 toFeeSafe = (amount * FEE_SAFE_BPS) / MAX_BPS;
        uint256 toContest = (amount * CONTEST_BPS) / MAX_BPS;
        uint256 toVault = (amount * VAULT_BPS) / MAX_BPS;
        uint256 toProducer = amount - toFeeSafe - toContest - toVault; // Remainder to avoid rounding issues
        
        // Update tracking
        TokenFeeData storage data = tokenFees[token];
        data.totalFeesReceived += amount;
        data.toFeeSafe += toFeeSafe;
        data.toContest += toContest;
        data.toVault += toVault;
        data.toProducer += toProducer;
        
        totalFeesDistributed += amount;
        
        // 1. Transfer to Fee Safe (immediate)
        address feeSafe = registry.feeSafe();
        if (feeSafe != address(0) && toFeeSafe > 0) {
            _usdc().safeTransfer(feeSafe, toFeeSafe);
        }
        
        // 2. Track contest fees for current epoch (deposited via flushToContest)
        address contest = registry.contest();
        uint32 currentEpoch = 0;
        if (contest != address(0) && toContest > 0) {
            // Get current epoch for this token
            try IContest(contest).getCurrentEpoch(token) returns (uint32 epoch) {
                currentEpoch = epoch;
                pendingContestFees[token][epoch] += toContest;
                // Track max epoch for sweep
                if (epoch > maxEpochSeen[token]) {
                    maxEpochSeen[token] = epoch;
                }
            } catch {
                // If token not graduated yet, hold fees
                pendingContestFees[token][0] += toContest;
            }
        }
        
        // Track pending creator fees for current epoch
        if (toProducer > 0) {
            pendingCreatorFees[token][currentEpoch] += toProducer;
        }
        
        // Auto-pay creator fees for any completed epochs (first transaction after epoch end)
        if (currentEpoch > 0) {
            _tryPayPreviousEpochCreatorFees(token, currentEpoch);
        }
        
        // 3. Deposit to UnifiedVault - FeeDistributor owns the shares for Producer Exit
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault != address(0) && toVault > 0) {
            _usdc().approve(infra.unifiedVault, toVault);
            uint256 sharesBefore = IERC20(infra.unifiedVault).balanceOf(address(this));
            try IUnifiedVault(infra.unifiedVault).deposit(toVault, address(this)) {
                uint256 sharesReceived = IERC20(infra.unifiedVault).balanceOf(address(this)) - sharesBefore;
                protocolVaultShares[token] += sharesReceived;
                _usdc().approve(infra.unifiedVault, 0);
                emit VaultAllocationDeposited(token, infra.unifiedVault, toVault);
            } catch {
                // If normal deposit fails (capacity limit), deposit to insurance fund instead
                _usdc().approve(infra.unifiedVault, 0);
                _usdc().approve(infra.unifiedVault, toVault);
                try IUnifiedVault(infra.unifiedVault).depositToInsuranceFund(toVault) {
                    _usdc().approve(infra.unifiedVault, 0);
                    insuranceFundDeposits[token] += toVault;
                    emit InsuranceFundDepositMade(token, infra.unifiedVault, toVault);
                } catch {
                    // If insurance deposit also fails (paused), track as pending
                    _usdc().approve(infra.unifiedVault, 0);
                    pendingVaultDeposits[token] += toVault;
                    emit PendingVaultDepositRecorded(token, toVault);
                }
            }
        }
        
        emit FeesDistributed(token, amount, toFeeSafe, toContest, toVault, toProducer);
    }
    
    /**
     * @notice Flush pending contest fees to Contest contract
     * @dev Can be called by anyone to push fees to Contest
     * @param token Campaign token address
     * @param epoch Epoch number
     */
    function flushToContest(address token, uint32 epoch) external nonReentrant {
        uint256 pending = pendingContestFees[token][epoch];
        if (pending == 0) return;
        
        address contest = registry.contest();
        if (contest == address(0)) return;
        
        pendingContestFees[token][epoch] = 0;
        
        _usdc().approve(contest, pending);
        try IContest(contest).depositFees(token, epoch, pending) {
            _usdc().approve(contest, 0); // Reset approval
            emit ContestFeesDeposited(token, epoch, pending);
        } catch {
            // If deposit fails, restore pending
            _usdc().approve(contest, 0);
            pendingContestFees[token][epoch] = pending;
        }
    }
    
    /**
     * @notice Batch flush contest fees for multiple epochs
     * @param token Campaign token address
     * @param epochs Array of epoch numbers
     */
    function flushToContestBatch(address token, uint32[] calldata epochs) external nonReentrant {
        address contest = registry.contest();
        if (contest == address(0)) return;
        
        for (uint256 i = 0; i < epochs.length; i++) {
            uint32 epoch = epochs[i];
            uint256 pending = pendingContestFees[token][epoch];
            if (pending == 0) continue;
            
            pendingContestFees[token][epoch] = 0;
            
            _usdc().approve(contest, pending);
            try IContest(contest).depositFees(token, epoch, pending) {
                _usdc().approve(contest, 0);
                emit ContestFeesDeposited(token, epoch, pending);
            } catch {
                _usdc().approve(contest, 0);
                pendingContestFees[token][epoch] = pending;
            }
        }
    }
    
    // ========== CREATOR REWARDS ==========
    
    /**
     * @notice Internal function to try paying creator fees for the previous epoch
     * @dev Called automatically during distributeFees, fails silently if no fees or invalid state
     * @param token Campaign token address
     * @param currentEpoch Current epoch number
     */
    function _tryPayPreviousEpochCreatorFees(address token, uint32 currentEpoch) internal {
        if (currentEpoch == 0) return;
        
        // Try to pay fees for the previous epoch (currentEpoch - 1)
        uint32 previousEpoch = currentEpoch - 1;
        uint256 pending = pendingCreatorFees[token][previousEpoch];
        
        // If no pending fees, nothing to do
        if (pending == 0) return;
        
        // Get campaign data
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        if (campaign.fundsRecipient == address(0)) return;
        
        // Clear pending and update tracking
        pendingCreatorFees[token][previousEpoch] = 0;
        TokenFeeData storage data = tokenFees[token];
        data.producerClaimed += pending;
        
        // Record payment
        creatorFeePayments[token].push(CreatorFeePayment({
            epoch: previousEpoch,
            amount: pending,
            timestamp: block.timestamp,
            recipient: campaign.fundsRecipient
        }));
        
        // Transfer to fundsRecipient
        _usdc().safeTransfer(campaign.fundsRecipient, pending);
        
        emit CreatorFeePaid(token, previousEpoch, campaign.fundsRecipient, pending);
    }
    
    /**
     * @notice Pay creator fees for a completed epoch to fundsRecipient
     * @dev Can be called by anyone after epoch ends (similar to flushToContest)
     * @param token Campaign token address
     * @param epoch Epoch number
     */
    function payCreatorFees(address token, uint32 epoch) external nonReentrant {
        uint256 pending = pendingCreatorFees[token][epoch];
        if (pending == 0) return;
        
        // Verify epoch has ended
        address contest = registry.contest();
        if (contest != address(0)) {
            try IContest(contest).getCurrentEpoch(token) returns (uint32 currentEpoch) {
                require(epoch < currentEpoch, "Epoch not ended");
            } catch {
                revert("Token not graduated");
            }
        } else {
            revert("Contest not set");
        }
        
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        require(campaign.fundsRecipient != address(0), "Invalid recipient");
        
        // Clear pending and update tracking
        pendingCreatorFees[token][epoch] = 0;
        TokenFeeData storage data = tokenFees[token];
        data.producerClaimed += pending;
        
        // Record payment
        creatorFeePayments[token].push(CreatorFeePayment({
            epoch: epoch,
            amount: pending,
            timestamp: block.timestamp,
            recipient: campaign.fundsRecipient
        }));
        
        // Transfer to fundsRecipient
        _usdc().safeTransfer(campaign.fundsRecipient, pending);
        
        emit CreatorFeePaid(token, epoch, campaign.fundsRecipient, pending);
    }
    
    /**
     * @notice Batch pay creator fees for multiple epochs
     * @param token Campaign token address
     * @param epochs Array of epoch numbers
     */
    function payCreatorFeesBatch(address token, uint32[] calldata epochs) external nonReentrant {
        address contest = registry.contest();
        require(contest != address(0), "Contest not set");
        
        uint32 currentEpoch;
        try IContest(contest).getCurrentEpoch(token) returns (uint32 epoch) {
            currentEpoch = epoch;
        } catch {
            revert("Token not graduated");
        }
        
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        require(campaign.fundsRecipient != address(0), "Invalid recipient");
        
        TokenFeeData storage data = tokenFees[token];
        
        for (uint256 i = 0; i < epochs.length; i++) {
            uint32 epoch = epochs[i];
            
            // Skip if epoch not ended or no pending fees
            if (epoch >= currentEpoch) continue;
            
            uint256 pending = pendingCreatorFees[token][epoch];
            if (pending == 0) continue;
            
            // Clear pending and update tracking
            pendingCreatorFees[token][epoch] = 0;
            data.producerClaimed += pending;
            
            // Record payment
            creatorFeePayments[token].push(CreatorFeePayment({
                epoch: epoch,
                amount: pending,
                timestamp: block.timestamp,
                recipient: campaign.fundsRecipient
            }));
            
            // Transfer to fundsRecipient
            _usdc().safeTransfer(campaign.fundsRecipient, pending);
            
            emit CreatorFeePaid(token, epoch, campaign.fundsRecipient, pending);
        }
    }
    
    // ========== PRODUCER EXIT ==========
    
    /**
     * @notice Producer claims exit reward after burning token supply to dust
     * @dev Redeems protocol vault shares, sweeps contest fees, sweeps insurance fund
     * @param token Campaign token address
     */
    function claimExitReward(address token) external nonReentrant {
        // 1. Verify caller is producer
        Registry.CampaignData memory campaign = registry.getCampaign(token);
        require(msg.sender == campaign.creator, "Not producer");
        
        // 2. Check no outstanding borrows
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) revert InvalidAddress();
        (,, , uint256 borrows) = IUnifiedVault(infra.unifiedVault).getPoolBalances();
        if (borrows > 0) revert OutstandingBorrows();
        
        // 3. Check token supply is effectively zero (< $10 value)
        uint256 supply = IERC20(token).totalSupply();
        address priceOracle = registry.hybridPriceOracle();
        require(priceOracle != address(0), "No price oracle");
        (uint256 price, ) = IPriceOracle(priceOracle).getPrice(token);
        // marketCap = (supply * price) / 1e18
        // supply: 6 decimals (campaign token), price: 18 decimals (scaled to 1e18)
        // result: USDC (6 decimals)
        uint256 marketCap = (supply * price) / 1e18;
        if (marketCap >= EXIT_THRESHOLD) revert SupplyNotBurned();
        
        uint256 totalReward = 0;
        
        // 4. Redeem protocol vault shares
        uint256 shares = protocolVaultShares[token];
        if (shares > 0) {
            protocolVaultShares[token] = 0;
            uint256 redeemed = IUnifiedVault(infra.unifiedVault).redeem(shares, address(this), address(this));
            totalReward += redeemed;
        }
        
        // 5. Sweep pending contest fees (all epochs 0-100)
        uint256 contestSweep = _sweepAllContestFees(token);
        totalReward += contestSweep;
        
        // 6. Sweep insurance fund from vault
        uint256 insuranceSweep = IUnifiedVault(infra.unifiedVault).sweepInsuranceFund(address(this));
        totalReward += insuranceSweep;
        
        // 7. Apply 25% fee and transfer to producer
        if (totalReward > 0) {
            uint256 fee = (totalReward * EXIT_FEE_BPS) / MAX_BPS;
            uint256 producerAmount = totalReward - fee;
            
            // Transfer fee to Fee Safe
            address feeSafe = registry.feeSafe();
            if (feeSafe != address(0) && fee > 0) {
                _usdc().safeTransfer(feeSafe, fee);
            }
            
            // Transfer remaining to fundsRecipient (consistent with campaign withdrawals)
            if (producerAmount > 0) {
                _usdc().safeTransfer(campaign.fundsRecipient, producerAmount);
            }
        }
        
        // 8. Disable market
        registry.disableMarket(token);
        
        emit ExitRewardClaimed(token, campaign.fundsRecipient, totalReward);
    }
    
    /**
     * @notice Sweep all pending contest fees for a token (internal helper)
     * @param token Campaign token address
     * @return swept Total USDC swept
     */
    function _sweepAllContestFees(address token) internal returns (uint256 swept) {
        // Sweep all epochs up to max seen for this token
        uint32 maxEpoch = maxEpochSeen[token];
        for (uint32 epoch = 0; epoch <= maxEpoch; epoch++) {
            uint256 pending = pendingContestFees[token][epoch];
            if (pending > 0) {
                pendingContestFees[token][epoch] = 0;
                swept += pending;
            }
        }
    }
    
    /**
     * @notice ProtocolSafe can withdraw protocol shares if needed (emergency)
     * @param token Campaign token address
     * @param shares Number of shares to withdraw
     * @param recipient Address to receive the redeemed USDC
     */
    function withdrawProtocolShares(address token, uint256 shares, address recipient) external nonReentrant {
        require(msg.sender == registry.protocolSafe(), "Not protocol safe");
        if (shares > protocolVaultShares[token]) revert InsufficientShares();
        
        protocolVaultShares[token] -= shares;
        
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) revert InvalidAddress();
        
        uint256 assets = IUnifiedVault(infra.unifiedVault).redeem(shares, recipient, address(this));
        
        emit ProtocolSharesWithdrawn(token, shares, assets, recipient);
    }
    
    /**
     * @notice Get protocol vault shares for a token
     * @param token Campaign token address
     * @return shares Number of vault shares owned by FeeDistributor for this token
     */
    function getProtocolVaultShares(address token) external view returns (uint256) {
        return protocolVaultShares[token];
    }
    
    /**
     * @notice Retry failed vault deposits
     * @dev Can be called by anyone to retry pending deposits
     * @param token Campaign token address
     */
    function retryVaultDeposit(address token) external nonReentrant {
        uint256 pending = pendingVaultDeposits[token];
        if (pending == 0) revert ZeroAmount();
        
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) revert InvalidAddress();
        
        // Clear pending before external call (CEI pattern)
        pendingVaultDeposits[token] = 0;
        
        _usdc().approve(infra.unifiedVault, pending);
        uint256 sharesBefore = IERC20(infra.unifiedVault).balanceOf(address(this));
        
        try IUnifiedVault(infra.unifiedVault).deposit(pending, address(this)) {
            uint256 sharesReceived = IERC20(infra.unifiedVault).balanceOf(address(this)) - sharesBefore;
            protocolVaultShares[token] += sharesReceived;
            _usdc().approve(infra.unifiedVault, 0);
            emit VaultDepositRetried(token, pending, true);
            emit VaultAllocationDeposited(token, infra.unifiedVault, pending);
        } catch {
            // If still fails, restore pending amount
            _usdc().approve(infra.unifiedVault, 0);
            pendingVaultDeposits[token] = pending;
            emit VaultDepositRetried(token, pending, false);
        }
    }
    
    // ========== PROTOCOL INCOME COLLECTION ==========
    
    /**
     * @notice Collect protocol income from a UnifiedVault
     * @dev Pulls protocol income from vault and distributes it
     * @param token Campaign token address
     */
    function collectProtocolIncome(address token) external nonReentrant {
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault == address(0)) revert InvalidAddress();
        
        // Collect from vault
        uint256 collected = IUnifiedVault(infra.unifiedVault).collectProtocolIncome();
        
        if (collected > 0) {
            // Distribute the collected income
            _distributeInternal(token, collected);
        }
    }
    
    /**
     * @notice Batch collect protocol income from multiple vaults
     * @param tokens Array of token addresses
     */
    function collectProtocolIncomeBatch(address[] calldata tokens) external nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
            if (infra.unifiedVault == address(0)) continue;
            
            try IUnifiedVault(infra.unifiedVault).collectProtocolIncome() returns (uint256 collected) {
                if (collected > 0) {
                    _distributeInternal(token, collected);
                }
            } catch {}
        }
    }
    
    /**
     * @notice Internal distribution (already has USDC)
     */
    function _distributeInternal(address token, uint256 amount) internal {
        // Calculate splits
        uint256 toFeeSafe = (amount * FEE_SAFE_BPS) / MAX_BPS;
        uint256 toContest = (amount * CONTEST_BPS) / MAX_BPS;
        uint256 toVault = (amount * VAULT_BPS) / MAX_BPS;
        uint256 toProducer = amount - toFeeSafe - toContest - toVault;
        
        // Update tracking
        TokenFeeData storage data = tokenFees[token];
        data.totalFeesReceived += amount;
        data.toFeeSafe += toFeeSafe;
        data.toContest += toContest;
        data.toVault += toVault;
        data.toProducer += toProducer;
        
        totalFeesDistributed += amount;
        
        // Transfer to Fee Safe
        address feeSafe = registry.feeSafe();
        if (feeSafe != address(0) && toFeeSafe > 0) {
            _usdc().safeTransfer(feeSafe, toFeeSafe);
        }
        
        // Track contest fees
        address contest = registry.contest();
        uint32 currentEpoch = 0;
        if (contest != address(0) && toContest > 0) {
            try IContest(contest).getCurrentEpoch(token) returns (uint32 epoch) {
                currentEpoch = epoch;
                pendingContestFees[token][epoch] += toContest;
            } catch {
                pendingContestFees[token][0] += toContest;
            }
        }
        
        // Track pending creator fees for current epoch
        if (toProducer > 0) {
            pendingCreatorFees[token][currentEpoch] += toProducer;
        }
        
        // Vault allocation - FeeDistributor owns the shares for Producer Exit
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault != address(0) && toVault > 0) {
            _usdc().approve(infra.unifiedVault, toVault);
            uint256 sharesBefore = IERC20(infra.unifiedVault).balanceOf(address(this));
            try IUnifiedVault(infra.unifiedVault).deposit(toVault, address(this)) {
                uint256 sharesReceived = IERC20(infra.unifiedVault).balanceOf(address(this)) - sharesBefore;
                protocolVaultShares[token] += sharesReceived;
                _usdc().approve(infra.unifiedVault, 0);
                emit VaultAllocationDeposited(token, infra.unifiedVault, toVault);
            } catch {
                // If normal deposit fails (capacity limit), deposit to insurance fund instead
                _usdc().approve(infra.unifiedVault, 0);
                _usdc().approve(infra.unifiedVault, toVault);
                try IUnifiedVault(infra.unifiedVault).depositToInsuranceFund(toVault) {
                    _usdc().approve(infra.unifiedVault, 0);
                    insuranceFundDeposits[token] += toVault;
                    emit InsuranceFundDepositMade(token, infra.unifiedVault, toVault);
                } catch {
                    // If insurance deposit also fails (paused), track as pending
                    _usdc().approve(infra.unifiedVault, 0);
                    pendingVaultDeposits[token] += toVault;
                    emit PendingVaultDepositRecorded(token, toVault);
                }
            }
        }
        
        emit FeesDistributed(token, amount, toFeeSafe, toContest, toVault, toProducer);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    function _isAuthorizedSource(address source, address token) internal view returns (bool) {
        // Market is authorized for all tokens
        if (source == registry.market()) return true;
        
        // UnifiedVault is authorized for its token
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (source == infra.unifiedVault) return true;
        
        return false;
    }
    
    function getTokenFeeData(address token) external view returns (
        uint256 totalReceived,
        uint256 toFeeSafe,
        uint256 toContest,
        uint256 toVault,
        uint256 toProducer,
        uint256 producerClaimed,
        uint256 producerClaimable
    ) {
        TokenFeeData storage data = tokenFees[token];
        totalReceived = data.totalFeesReceived;
        toFeeSafe = data.toFeeSafe;
        toContest = data.toContest;
        toVault = data.toVault;
        toProducer = data.toProducer;
        producerClaimed = data.producerClaimed;
        producerClaimable = data.toProducer - data.producerClaimed;
    }
    
    function getPendingContestFees(address token, uint32 epoch) external view returns (uint256) {
        return pendingContestFees[token][epoch];
    }
    
    function getProducerClaimable(address token) external view returns (uint256) {
        TokenFeeData storage data = tokenFees[token];
        return data.toProducer - data.producerClaimed;
    }
    
    /**
     * @notice Get pending creator fees for a specific epoch
     * @param token Campaign token address
     * @param epoch Epoch number
     * @return pending Pending USDC amount for this epoch
     */
    function getPendingCreatorFees(address token, uint32 epoch) external view returns (uint256) {
        return pendingCreatorFees[token][epoch];
    }
    
    /**
     * @notice Get creator fee payment history with pagination
     * @param token Campaign token address
     * @param offset Starting index
     * @param limit Maximum number of records to return
     * @return payments Array of payment records
     * @return total Total number of payments for this token
     */
    function getCreatorFeePayments(
        address token,
        uint256 offset,
        uint256 limit
    ) external view returns (
        CreatorFeePayment[] memory payments,
        uint256 total
    ) {
        CreatorFeePayment[] storage allPayments = creatorFeePayments[token];
        total = allPayments.length;
        
        if (offset >= total) {
            return (new CreatorFeePayment[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        uint256 resultLength = end - offset;
        payments = new CreatorFeePayment[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            payments[i] = allPayments[offset + i];
        }
    }
    
    /**
     * @notice Get total creator fees paid for a token
     * @param token Campaign token address
     * @return totalPaid Total USDC paid to creator
     */
    function getTotalCreatorFeesPaid(address token) external view returns (uint256 totalPaid) {
        TokenFeeData storage data = tokenFees[token];
        return data.producerClaimed;
    }
    
    /**
     * @notice Get current epoch's pending creator fees (live amount)
     * @param token Campaign token address
     * @return currentEpoch Current epoch number
     * @return pendingAmount Pending fees for current epoch
     */
    function getCurrentEpochCreatorFees(address token) external view returns (
        uint32 currentEpoch,
        uint256 pendingAmount
    ) {
        address contest = registry.contest();
        if (contest != address(0)) {
            try IContest(contest).getCurrentEpoch(token) returns (uint32 epoch) {
                currentEpoch = epoch;
                pendingAmount = pendingCreatorFees[token][epoch];
            } catch {
                currentEpoch = 0;
                pendingAmount = pendingCreatorFees[token][0];
            }
        }
    }
    
    /**
     * @notice Get protocol's allocation info for a token (for frontend reporting to producer)
     * @param token Campaign token address
     * @return vaultShares Number of vault shares owned by FeeDistributor
     * @return vaultSharesValue Current USDC value of vault shares
     * @return insuranceDeposits Total USDC deposited to insurance fund (when normal deposit failed)
     * @return insuranceFundBalance Current insurance fund balance in vault
     * @return pendingDeposits Pending deposits that couldn't be made (vault paused)
     */
    function getProtocolAllocationInfo(address token) external view returns (
        uint256 vaultShares,
        uint256 vaultSharesValue,
        uint256 insuranceDeposits,
        uint256 insuranceFundBalance,
        uint256 pendingDeposits
    ) {
        vaultShares = protocolVaultShares[token];
        insuranceDeposits = insuranceFundDeposits[token];
        pendingDeposits = pendingVaultDeposits[token];
        
        Registry.LendingInfrastructure memory infra = registry.getLendingInfrastructure(token);
        if (infra.unifiedVault != address(0)) {
            // Get current value of shares
            if (vaultShares > 0) {
                vaultSharesValue = IUnifiedVault(infra.unifiedVault).convertToAssets(vaultShares);
            }
            // Get current insurance fund balance from vault
            (, , insuranceFundBalance, ) = IUnifiedVault(infra.unifiedVault).getPoolBalances();
        }
    }
    
    /**
     * @notice Preview fee split for a given amount
     */
    function previewFeeSplit(uint256 amount) external pure returns (
        uint256 toFeeSafe,
        uint256 toContest,
        uint256 toVault,
        uint256 toProducer
    ) {
        toFeeSafe = (amount * FEE_SAFE_BPS) / MAX_BPS;
        toContest = (amount * CONTEST_BPS) / MAX_BPS;
        toVault = (amount * VAULT_BPS) / MAX_BPS;
        toProducer = amount - toFeeSafe - toContest - toVault;
    }
}
