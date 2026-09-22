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
import "./Contest.sol";
import "./UnifiedVault.sol";
import "./RiskOracle.sol";
import "./FeeDistributor.sol";
import "./OptimisticPriceOracle.sol";
import "./interfaces/ICampaign.sol";
import "./LendingManager.sol";

/**
 * @title KeeperRegistry
 * @notice Centralized keeper contract that batches all maintenance operations
 * @dev Triggered by Contest first claimer - gas paid by claimer who receives bounty
 * 
 * V3 CHANGES:
 * - Uses UnifiedVault instead of 5-contract stack
 * - Uses RiskOracle for risk tier checks
 * - Uses FeeDistributor for fee distribution (replaces InterestDistributor)
 * 
 * OPERATIONS HANDLED:
 * 1. FeeDistributor.distribute() - Distribute protocol fees
 * 2. OptimisticPriceOracle.finalizePrice() - Finalize unchallenged price assertions
 * 3. OptimisticPriceOracle.finalizeGovernanceVote() - Finalize completed votes
 * 4. UnifiedVault.accrueInterest() - Accrue interest on vault
 * 5. SingleRoundCampaign/MultiRoundCampaign - End expired campaigns
 * 6. Contest.finalizeEpoch() - Finalize contest epochs
 * 7. RiskOracle.checkCircuitBreaker() - Check circuit breaker conditions
 */
contract KeeperRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // --- Dependencies ---
    Registry public registry;
    // NOTE: All other dependencies removed - now retrieved from Registry
    
    // --- Configuration ---
    uint256 public constant MAX_WITHDRAWALS_PER_CALL = 3;
    uint256 public constant MAX_LIQUIDATIONS_PER_CALL = 5;
    uint256 public constant MAX_CAMPAIGNS_PER_CALL = 3;
    
    // --- Tracking ---
    mapping(address => uint256) public lastKeeperRun; // token => timestamp
    uint256 public totalKeeperRuns;
    
    // --- Events ---
    event KeeperTasksExecuted(
        address indexed token,
        uint32 indexed epoch,
        address indexed executor,
        uint256 withdrawalsProcessed,
        uint256 liquidationsProcessed,
        uint256 timestamp
    );
    event DependencySet(string name, address addr);
    event KeeperTaskFailed(string task, address token, string reason);
    
    // --- Errors ---
    error OnlyContest();
    error ZeroAddress();
    
    constructor(address _owner, address _registry) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    // --- Registry Helper Functions ---
    
    function _getContest() internal view returns (Contest) {
        address addr = registry.contest();
        return addr != address(0) ? Contest(addr) : Contest(address(0));
    }
    
    function _getRiskOracle() internal view returns (RiskOracle) {
        address addr = registry.riskOracle();
        return addr != address(0) ? RiskOracle(addr) : RiskOracle(address(0));
    }
    
    function _getFeeDistributor() internal view returns (FeeDistributor) {
        address addr = registry.feeDistributor();
        return addr != address(0) ? FeeDistributor(addr) : FeeDistributor(address(0));
    }
    
    function _getOptimisticOracle() internal view returns (OptimisticPriceOracle) {
        address addr = registry.optimisticPriceOracle();
        return addr != address(0) ? OptimisticPriceOracle(addr) : OptimisticPriceOracle(address(0));
    }
    
    function _getSingleRoundCampaign() internal view returns (ICampaign) {
        address addr = registry.campaign();
        return addr != address(0) ? ICampaign(addr) : ICampaign(address(0));
    }
    
    function _getMultiRoundCampaign() internal view returns (IMultiRoundCampaign) {
        address addr = registry.multiRoundCampaign();
        return addr != address(0) ? IMultiRoundCampaign(addr) : IMultiRoundCampaign(address(0));
    }
    
    function _getLendingManager() internal view returns (LendingManager) {
        address addr = registry.lendingManager();
        return addr != address(0) ? LendingManager(addr) : LendingManager(address(0));
    }
    
    // V3: InterestDistributor replaced by FeeDistributor (see _getFeeDistributor above)
    
    // --- Admin Functions ---
    
    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        registry = Registry(_registry);
        emit DependencySet("Registry", _registry);
    }
    
    // NOTE: All other setters removed - now retrieved from Registry
    
    // --- Main Keeper Function ---
    
    /**
     * @notice Execute all keeper tasks for a token
     * @dev Called by Contest.claim() for first claimer
     * @param token The graduated token address
     * @param epoch The contest epoch being claimed
     */
    function executeKeeperTasks(address token, uint32 epoch) external nonReentrant {
        // Only Contest can call this (triggered by first claimer)
        Contest _contest = _getContest();
        if (msg.sender != address(_contest)) revert OnlyContest();
        
        // 1. V3: Fee distribution happens automatically via FeeDistributor when fees are received
        // No keeper action needed - Market and UnifiedVault call distributeFees directly
        
        // 2. V3: Accrue interest on UnifiedVault
        _accrueVaultInterest(token);
        
        // 3. Finalize OptimisticPriceOracle assertions
        _finalizeOptimisticPrice(token);
        
        // 5. Finalize Contest epoch (if not already finalized)
        _finalizeContestEpoch(token, epoch);
        
        // 6. Check and trigger circuit breaker if needed (RiskOracle)
        _checkCircuitBreaker(token);
        
        // Update tracking
        lastKeeperRun[token] = block.timestamp;
        totalKeeperRuns++;
        
        // FIX (L-8): Use msg.sender instead of tx.origin for better security
        // tx.origin can be manipulated in contract-to-contract calls
        // msg.sender is the Contest contract which tracks the actual first claimer
        emit KeeperTasksExecuted(
            token,
            epoch,
            msg.sender, // The Contest contract (tracks first claimer internally)
            0, // V3: withdrawals handled by UnifiedVault
            0, // V3: liquidations handled by external liquidators
            block.timestamp
        );
    }
    
    /**
     * @notice Execute global keeper tasks (not token-specific)
     * @dev Can be called by anyone, but typically by Contest first claimer
     */
    function executeGlobalTasks() external nonReentrant {
        // Only Contest or owner can call
        Contest _contest = _getContest();
        if (msg.sender != address(_contest) && msg.sender != owner()) revert OnlyContest();
        
        // 1. End expired campaigns
        _endExpiredCampaigns();
    }
    
    // --- Internal Task Functions ---
    
    /**
     * @notice Get per-token infrastructure from Registry
     * @param token Campaign token address
     * @return infra LendingInfrastructure struct
     */
    function _getTokenInfrastructure(address token) internal view returns (Registry.LendingInfrastructure memory infra) {
        if (address(registry) == address(0)) return infra;
        return registry.getLendingInfrastructure(token);
    }
    
    // V3: Fee distribution is automatic - no keeper action needed
    
    /**
     * @notice Accrue interest on UnifiedVault (V3)
     */
    function _accrueVaultInterest(address token) internal {
        if (address(registry) == address(0)) return;
        
        address vault = registry.getUnifiedVault(token);
        if (vault == address(0)) return;
        
        try UnifiedVault(vault).triggerAccrueInterest() {
            // Success
        } catch {
            emit KeeperTaskFailed("accrueInterest", token, "Failed");
        }
    }
    
    /**
     * @notice Finalize optimistic price assertion if ready
     */
    function _finalizeOptimisticPrice(address token) internal {
        OptimisticPriceOracle _optimisticOracle = _getOptimisticOracle();
        if (address(_optimisticOracle) == address(0)) return;
        
        try _optimisticOracle.finalizePrice(token) {
            // Success
        } catch {
            // May fail if no assertion, disputed, or not ready - that's OK
        }
        
        // Also try to finalize governance vote if one exists
        try _optimisticOracle.finalizeGovernanceVote(token) {
            // Success
        } catch {
            // May fail if no vote or not ready - that's OK
        }
    }
    
    // V3: Bad debt coverage is handled internally by UnifiedVault
    
    /**
     * @notice Finalize contest epoch if not already finalized
     */
    function _finalizeContestEpoch(address token, uint32 epoch) internal {
        Contest _contest = _getContest();
        if (address(_contest) == address(0)) return;
        
        try _contest.finalizeEpoch(token, epoch) {
            // Success
        } catch {
            // May already be finalized - that's OK
        }
    }
    
    /**
     * @notice Check and trigger circuit breaker if conditions are met (V3)
     */
    function _checkCircuitBreaker(address token) internal {
        RiskOracle _riskOracle = _getRiskOracle();
        if (address(_riskOracle) == address(0)) return;
        
        try _riskOracle.checkCircuitBreaker(token) {
            // Success - circuit breaker checked (may or may not have triggered)
        } catch {
            emit KeeperTaskFailed("checkCircuitBreaker", token, "Failed");
        }
    }
    
    /**
     * @notice End expired campaigns
     */
    function _endExpiredCampaigns() internal {
        if (address(registry) == address(0)) return;
        
        // Get all tokens and check for expired campaigns
        address[] memory tokens = registry.getAllTokens();
        uint256 processed = 0;
        
        for (uint256 i = 0; i < tokens.length && processed < MAX_CAMPAIGNS_PER_CALL; i++) {
            address token = tokens[i];
            Registry.CampaignData memory data = registry.getCampaign(token);
            
            // Check if campaign is active, past end time, AND floor met (successful)
            // Failed campaigns don't need keeper - refunds are auto-available
            uint8 status = registry.getCampaignStatus(token);
            if ((status == 1 || status == 2) && 
                block.timestamp > data.endTime && 
                data.totalRaised >= data.floor) {
                
                // Route to correct campaign contract based on type
                if (registry.isMultiRoundCampaign(token)) {
                    IMultiRoundCampaign _multiRound = _getMultiRoundCampaign();
                    if (address(_multiRound) != address(0)) {
                        try _multiRound.publicFinalizeMultiRound(token) {
                            processed++;
                        } catch {
                            // May fail for various reasons - continue
                        }
                    }
                } else {
                    ICampaign _singleRound = _getSingleRoundCampaign();
                    if (address(_singleRound) != address(0)) {
                        try _singleRound.publicFinalizeCampaign(token) {
                            processed++;
                        } catch {
                            // May fail for various reasons - continue
                        }
                    }
                }
            }
        }
    }
    
    // --- View Functions ---
    
    /**
     * @notice Check if keeper tasks are needed for a token
     * @param token Token address
     * @return needsKeeper Whether keeper tasks should be run
     * @return reason Human-readable reason
     */
    function needsKeeperTasks(address token) external view returns (bool needsKeeper, string memory reason) {
        // V3: Check if vault needs interest accrual
        if (address(registry) != address(0)) {
            address vault = registry.getUnifiedVault(token);
            if (vault != address(0)) {
                // Check if interest needs accruing (simplified check)
                return (true, "Interest may need accruing");
            }
        }
        
        // Check if optimistic price can be finalized
        OptimisticPriceOracle _optimisticOracle = _getOptimisticOracle();
        if (address(_optimisticOracle) != address(0)) {
            try _optimisticOracle.getAssertion(token) returns (
                address proposer,
                uint256,
                uint256 deadline,
                bool disputed,
                bool resolved,
                bool
            ) {
                if (proposer != address(0) && !resolved && !disputed && block.timestamp > deadline) {
                    return (true, "Price assertion ready to finalize");
                }
            } catch {}
        }
        
        return (false, "No tasks needed");
    }
    
    /**
     * @notice Get keeper statistics
     */
    function getKeeperStats() external view returns (
        uint256 totalRuns,
        uint256 lastGlobalRun
    ) {
        totalRuns = totalKeeperRuns;
        lastGlobalRun = lastKeeperRun[address(0)];
    }
}
