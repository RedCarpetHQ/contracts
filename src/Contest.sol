// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

/**
 * @title Contest (epoch-based trading contest with buy-side volume tracking)
 * @notice
 * - Tracks buy-side USDC volume per user and epoch for graduated tokens
 * - Epoch starts when token graduates (from Registry.graduatedTime)
 * - Threshold gating: 15,000 USDC minimum to qualify
 * - Pro-rata rewards from collected trading fees
 * - First claimer bounty incentivizes fee collection
 * - Gas-optimized with shortfall buckets + bitmaps
 *
 * V3 CHANGES:
 * - Removed creator reward (now handled by FeeDistributor)
 * - All deposited fees go to traders (100%)
 * - Simplified finalization logic
 *
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Registry.sol";
import "./KeeperRegistry.sol";

contract Contest is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Admin ---
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    // Authorized volume sources (MasterHook, Market.sol, etc.)
    mapping(address => bool) public isSource;
    modifier onlySource() { require(isSource[msg.sender], "not source"); _; }

    // Authorized fee collectors (FeeCollector contract)
    mapping(address => bool) public isCollector;
    modifier onlyCollector() { require(isCollector[msg.sender], "not collector"); _; }

    // --- Core Dependencies ---
    Registry public immutable registry;

    // --- Config ---
    // Configurable epoch length (set via setEpochLength in multisig deployment)
    // Test default: 3 hours for fast iteration; production: 7 days
    uint32 public EPOCH_LENGTH = 3 hours; // production: 7 days
    uint96 public constant THRESHOLD = 15_000e6; // 15,000 USDC minimum to qualify (6 decimals)
    uint96 public constant MIN_TRADE = 1e6;   // 1 USDC (6 decimals)
    uint96 public constant FIRST_CLAIMER_BOUNTY_BPS = 100; // 1% bounty for first claimer
    // V3: CREATOR_REWARD_BPS removed - creator rewards handled by FeeDistributor

    // --- State ---
    
    struct EpochData {
        uint128 totalUsdcVolume;    // Σ buy-side USDC volume
        uint128 eligibleTotal;      // Σ eligible volumes (qualified users)
        uint128 usdcPrize;          // USDC prize pot for traders (100% of fees in V3)
        uint128 bounty;             // First claimer bounty (1% of trader prize)
        uint128 rolloverPrize;      // Rolled over from previous epoch if no qualifiers
        bool finalized;             // True after epoch ends
        address firstClaimer;       // First user to claim (gets bounty)
        // V3: creatorReward and creatorClaimed removed - handled by FeeDistributor
    }

    struct UserState {
        uint96 shortfall;           // >0 until threshold crossed
        uint128 eligible;           // Volume counted after crossing threshold
    }

    // token => epoch => data
    mapping(address => mapping(uint32 => EpochData)) public epochs;
    
    // token => epoch => user => state
    mapping(address => mapping(uint32 => mapping(address => UserState))) public users;

    // CRITICAL FIX (#2): Replace bitmaps with proper mappings to prevent collision attacks
    // Old bitmap approach only had 256 bit positions, causing guaranteed collisions with 65k+ users
    mapping(address => mapping(uint32 => mapping(address => bool))) private qualifiedMap;
    mapping(address => mapping(uint32 => mapping(address => bool))) private claimedMap;
    
    // CRITICAL FIX: Track fees per token per epoch
    mapping(address => mapping(uint32 => uint256)) public epochFees;
    
    // CRITICAL FIX (#3): Track if keeper tasks already run for epoch (prevents race condition)
    mapping(address => mapping(uint32 => bool)) public keeperTasksRun;

    // V3 REDESIGN: Gas rebate for sweeping all-dead epoch chains (edge case)
    uint128 public deadEpochSweepReward;

    // --- Events ---
    event SourceSet(address indexed src, bool allowed);
    event CollectorSet(address indexed collector, bool allowed);
    event TokenVaultSet(address indexed vault);
    event FeesDeposited(address indexed token, uint32 indexed epoch, uint256 amount, address indexed depositor);
    event Volume(
        address indexed token,
        uint32 indexed epoch,
        address indexed trader,
        uint128 usdcVol,
        bool qualifiedAfter
    );
    event Qualified(address indexed user, address indexed token, uint32 indexed epoch);
    event EpochFinalized(
        address indexed token,
        uint32 indexed epoch,
        uint128 honoPrize,
        uint128 rolloverPrize,
        uint128 eligibleTotal
    );
    event Claimed(
        address indexed user,
        address indexed token,
        uint32 indexed epoch,
        uint128 payout,
        bool isFirstClaimer,
        uint128 bounty
    );
    // V3: CreatorRewardClaimed event removed - creator rewards handled by FeeDistributor
    event RolloverApplied(address indexed token, uint32 indexed fromEpoch, uint32 indexed toEpoch, uint128 amount);
    event EpochMarkedDead(address indexed token, uint32 indexed epoch);
    event DeadEpochsSwept(address indexed token, uint32[] epochs, uint128 totalRollover, uint128 rewardPaid);
    event DeadEpochSweepRewardSet(uint128 reward);
    event EpochLengthUpdated(uint32 epochLength);

    constructor(
        address _owner,
        address _registry
    ) {
        require(_owner != address(0) && _registry != address(0), "zero addr");
        owner = _owner;
        registry = Registry(_registry);
        
        isSource[_owner] = true;
        isCollector[_owner] = true;
    }
    
    // --- Registry Address Helpers ---
    
    function _getUsdc() internal view returns (address) {
        return registry.usdc();
    }
    
    function _getKeeperRegistry() internal view returns (KeeperRegistry) {
        address addr = registry.keeperRegistry();
        return addr != address(0) ? KeeperRegistry(addr) : KeeperRegistry(address(0));
    }
    
    // V3: _getInterestDistributor removed - fees now handled by FeeDistributor
    
    // Public getter for USDC (for backward compatibility)
    function USDC() external view returns (address) {
        return _getUsdc();
    }

    // --- Admin ---
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        owner = newOwner;
    }

    function setSource(address src, bool allowed) external onlyOwner {
        isSource[src] = allowed;
        emit SourceSet(src, allowed);
    }

    function setCollector(address collector, bool allowed) external onlyOwner {
        isCollector[collector] = allowed;
        emit CollectorSet(collector, allowed);
    }

    function setDeadEpochSweepReward(uint128 reward) external onlyOwner {
        deadEpochSweepReward = reward;
        emit DeadEpochSweepRewardSet(reward);
    }

    /**
     * @notice Set epoch length (production configuration)
     * @dev Test default: 3 hours for fast iteration; production: 7 days
     *      Must be set before any token graduates to avoid epoch boundary issues
     * @param _epochLength Epoch length in seconds
     */
    function setEpochLength(uint32 _epochLength) external onlyOwner {
        require(_epochLength >= 1 hours && _epochLength <= 30 days, "Invalid epoch length");
        EPOCH_LENGTH = _epochLength;
        emit EpochLengthUpdated(_epochLength);
    }

    // NOTE: setInterestDistributor and setKeeperRegistry removed - now retrieved from Registry
    
    /**
     * @notice Deposit fees for a specific token and epoch
     * @dev Called by Market or other authorized sources when distributing fees
     * @param token Token address
     * @param epoch Epoch number
     * @param amount Amount of USDC fees to deposit
     */
    function depositFees(address token, uint32 epoch, uint256 amount) external onlySource {
        require(amount > 0, "zero amount");
        require(registry.isMarketOpen(token), "not graduated");
        
        epochFees[token][epoch] += amount;
        address usdc = _getUsdc();
        require(usdc != address(0), "USDC not set in Registry");
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        
        emit FeesDeposited(token, epoch, amount, msg.sender);
    }

    // --- Volume Recording ---

    /**
     * @notice Record buy-side USDC volume for current epoch
     * @dev Called by authorized sources (Market.sol, StableVault.sol)
     * @param token Graduated token address
     * @param trader User address
     * @param usdcVol USDC volume spent on buy (6 decimals)
     */
    function addBuyVolume(
        address token,
        address trader,
        uint128 usdcVol
    ) external onlySource {
        // Validate token market is open (graduated)
        if (!registry.isMarketOpen(token)) return; // Only track graduated tokens
        
        // Ignore dust trades
        if (usdcVol < MIN_TRADE) return;

        uint32 epoch = _currentEpoch(token);
        EpochData storage e = epochs[token][epoch];

        // Update pool-level volume (1 SSTORE)
        e.totalUsdcVolume += usdcVol;

        // Update user state (≤2 SSTOREs)
        UserState storage u = users[token][epoch][trader];
        
        if (!_isQualified(token, epoch, trader)) {
            // User not yet qualified
            uint96 s = u.shortfall;
            if (s == 0) {
                // First trade in epoch
                s = THRESHOLD;
                u.shortfall = s;
            }
            
            if (usdcVol >= s) {
                // Crosses threshold
                _setQualified(token, epoch, trader);
                u.shortfall = 0;
                
                uint128 excess = usdcVol - s;
                if (excess > 0) {
                    u.eligible += excess;
                    e.eligibleTotal += excess;
                }
                
                emit Qualified(trader, token, epoch);
                emit Volume(token, epoch, trader, usdcVol, true);
            } else {
                // Still below threshold
                u.shortfall = s - uint96(usdcVol);
                emit Volume(token, epoch, trader, usdcVol, false);
            }
        } else {
            // Already qualified - all volume counts
            u.eligible += usdcVol;
            e.eligibleTotal += usdcVol;
            emit Volume(token, epoch, trader, usdcVol, true);
        }
    }

    /**
     * @notice Finalize an epoch (can be called by anyone after epoch ends)
     * @dev V3 REDESIGN: Auto-sweeps prior consecutive dead epochs into prize pool
     *      First claimer bounty scales with swept rollover
     * @param token Graduated token address
     * @param epoch Epoch number
     */
    function finalizeEpoch(
        address token,
        uint32 epoch
    ) external {
        require(registry.isMarketOpen(token), "not graduated");
        uint256 graduatedTime = registry.getMarket(token).enabledAt;
        require(graduatedTime > 0, "invalid grad time");

        require(_epochEnded(token, epoch), "epoch live");

        EpochData storage e = epochs[token][epoch];
        require(!e.finalized, "already finalized");
        require(e.eligibleTotal > 0, "dead epoch - no qualifiers");

        // --- Auto-sweep prior consecutive dead epochs ---
        uint256 maxSweep = 32; // gas safety bound
        uint128 sweptRollover = 0;

        for (uint32 eid = epoch; eid > 0 && maxSweep > 0; eid--) {
            EpochData storage prior = epochs[token][eid - 1];
            if (prior.finalized) break;
            if (prior.eligibleTotal > 0) break; // stop at alive epoch

            // Dead epoch: consume its fees and rollover, mark finalized
            uint128 priorFees = uint128(epochFees[token][eid - 1]);
            if (priorFees > 0) {
                sweptRollover += priorFees;
                epochFees[token][eid - 1] = 0;
            }
            if (prior.rolloverPrize > 0) {
                sweptRollover += prior.rolloverPrize;
                prior.rolloverPrize = 0;
            }
            prior.finalized = true;
            maxSweep--;
            emit EpochMarkedDead(token, eid - 1);
        }

        // Compute prize from this epoch's fees + all swept rollover
        uint128 fees = uint128(epochFees[token][epoch]);
        require(fees > 0 || sweptRollover > 0, "no fees or rollover");

        uint128 traderPool = fees + sweptRollover;
        uint128 bounty = uint128((traderPool * FIRST_CLAIMER_BOUNTY_BPS) / 10000);

        e.usdcPrize = traderPool - bounty;
        e.bounty = bounty;
        e.finalized = true;

        emit EpochFinalized(token, epoch, e.usdcPrize, sweptRollover, e.eligibleTotal);
    }

    // --- Claims ---

    /**
     * @notice Claim pro-rata prize for an epoch
     * @param token Graduated token address
     * @param epoch Epoch number
     * @param to Recipient address
     */
    function claim(
        address token,
        uint32 epoch,
        address to
    ) external nonReentrant {
        EpochData storage e = epochs[token][epoch];
        require(e.finalized, "not finalized");
        require(_isQualified(token, epoch, msg.sender), "not qualified");
        require(!_isClaimed(token, epoch, msg.sender), "already claimed");

        UserState storage u = users[token][epoch][msg.sender];
        require(u.eligible > 0 && e.eligibleTotal > 0, "no share");

        // Calculate pro-rata share from usdcPrize
        uint256 totalPrize = uint256(e.usdcPrize);
        uint256 payout = (totalPrize * u.eligible) / e.eligibleTotal;

        // First claimer gets their share + the pre-allocated bounty
        bool isFirstClaimer = (e.firstClaimer == address(0));
        uint128 claimerBounty = 0;
        
        if (isFirstClaimer) {
            e.firstClaimer = msg.sender;
            claimerBounty = e.bounty;
            payout += claimerBounty;
            
            // TRIGGER ALL KEEPER TASKS (interest distribution, withdrawal queue, supply cap, etc.)
            // First claimer pays gas but receives bounty as compensation
            // All triggers consolidated in KeeperRegistry for single entry point
            // CRITICAL FIX (#3): Only run keeper tasks once per epoch (prevents race condition)
            KeeperRegistry _keeperRegistry = _getKeeperRegistry();
            if (address(_keeperRegistry) != address(0) && !keeperTasksRun[token][epoch]) {
                keeperTasksRun[token][epoch] = true;
                try _keeperRegistry.executeKeeperTasks(token, epoch) {} catch {}
            }
        }

        _setClaimed(token, epoch, msg.sender);

        // Transfer USDC
        IERC20(_getUsdc()).safeTransfer(to, payout);
        
        emit Claimed(msg.sender, token, epoch, uint128(payout), isFirstClaimer, claimerBounty);
    }

    /**
     * @notice Batch claim multiple epochs for a token
     * @dev FIX (L-NEW-1): Events emitted after transfer for consistency with claim()
     * @param token Graduated token address
     * @param epochsToClaim Array of epoch numbers
     * @param to Recipient address
     */
    function claimBatch(
        address token,
        uint32[] calldata epochsToClaim,
        address to
    ) external nonReentrant {
        uint256 totalPayout = 0;
        
        // Track claim data for events (emitted after transfer)
        uint256 claimCount = 0;
        uint32[] memory claimedEpochs = new uint32[](epochsToClaim.length);
        uint128[] memory payouts = new uint128[](epochsToClaim.length);
        bool[] memory wasFirstClaimer = new bool[](epochsToClaim.length);
        uint128[] memory bounties = new uint128[](epochsToClaim.length);
        
        for (uint256 i = 0; i < epochsToClaim.length; i++) {
            uint32 epoch = epochsToClaim[i];
            EpochData storage e = epochs[token][epoch];
            
            if (!e.finalized) continue;
            if (!_isQualified(token, epoch, msg.sender)) continue;
            if (_isClaimed(token, epoch, msg.sender)) continue;

            UserState storage u = users[token][epoch][msg.sender];
            if (u.eligible == 0 || e.eligibleTotal == 0) continue;

            // Calculate pro-rata share from usdcPrize
            uint256 payout = (uint256(e.usdcPrize) * u.eligible) / e.eligibleTotal;

            // First claimer gets their share + the pre-allocated bounty
            bool isFirstClaimer = (e.firstClaimer == address(0));
            uint128 claimerBounty = 0;
            
            if (isFirstClaimer) {
                e.firstClaimer = msg.sender;
                claimerBounty = e.bounty;
                payout += claimerBounty;
            }

            _setClaimed(token, epoch, msg.sender);
            totalPayout += payout;
            
            // FIX (L-14): Trigger keeper tasks for first claimer in batch
            // FIX (M-2): Check keeperTasksRun to prevent duplicate execution
            if (isFirstClaimer && !keeperTasksRun[token][epoch]) {
                keeperTasksRun[token][epoch] = true;
                KeeperRegistry _keeperRegistry = _getKeeperRegistry();
                if (address(_keeperRegistry) != address(0)) {
                    try _keeperRegistry.executeKeeperTasks(token, epoch) {} catch {}
                }
            }
            
            // Store claim data for event emission after transfer
            claimedEpochs[claimCount] = epoch;
            payouts[claimCount] = uint128(payout);
            wasFirstClaimer[claimCount] = isFirstClaimer;
            bounties[claimCount] = claimerBounty;
            claimCount++;
        }

        // Transfer first, then emit events (consistent with claim())
        if (totalPayout > 0) {
            IERC20(_getUsdc()).safeTransfer(to, totalPayout);
        }
        
        // FIX (L-NEW-1): Emit events after successful transfer
        for (uint256 i = 0; i < claimCount; i++) {
            emit Claimed(msg.sender, token, claimedEpochs[i], payouts[i], wasFirstClaimer[i], bounties[i]);
        }
    }

    // V3: claimCreatorReward and claimCreatorRewardBatch removed
    // Creator rewards are now handled by FeeDistributor.claimProducerReward()

    // --- Views ---

    /**
     * @notice Get current epoch for a token
     * @param token Graduated token address
     * @return Current epoch number (type(uint32).max if not graduated)
     */
    function currentEpoch(address token) external view returns (uint32) {
        return _currentEpoch(token);
    }
    
    /**
     * @notice Check if a token is graduated (market is open)
     * @dev FIX (L-4): Helper function to distinguish epoch 0 from non-graduated
     * @param token Token address
     * @return True if token is graduated
     */
    function isTokenGraduated(address token) external view returns (bool) {
        return registry.isMarketOpen(token);
    }

    /**
     * @notice Get epoch end timestamp
     * @param token Graduated token address
     * @param epoch Epoch number
     * @return Timestamp when epoch ends
     */
    function epochEndTime(address token, uint32 epoch) external view returns (uint256) {
        if (!registry.isMarketOpen(token)) return 0;
        uint256 graduatedTime = registry.getMarket(token).enabledAt;
        if (graduatedTime == 0) return 0;
        return graduatedTime + (uint256(epoch) + 1) * EPOCH_LENGTH;
    }

    /**
     * @notice Check if user is qualified for an epoch
     */
    function isQualified(address token, uint32 epoch, address user) external view returns (bool) {
        return _isQualified(token, epoch, user);
    }

    /**
     * @notice Check if user has claimed for an epoch
     */
    function isClaimed(address token, uint32 epoch, address user) external view returns (bool) {
        return _isClaimed(token, epoch, user);
    }

    /**
     * @notice Get user's claimable amount for an epoch
     * @return amount Claimable USDC amount (including potential bounty)
     * @return isFirstClaimer Whether user would be first claimer
     */
    function getClaimableAmount(
        address token,
        uint32 epoch,
        address user
    ) external view returns (uint256 amount, bool isFirstClaimer) {
        EpochData storage e = epochs[token][epoch];
        
        if (!e.finalized) return (0, false);
        if (!_isQualified(token, epoch, user)) return (0, false);
        if (_isClaimed(token, epoch, user)) return (0, false);

        UserState storage u = users[token][epoch][user];
        if (u.eligible == 0 || e.eligibleTotal == 0) return (0, false);

        amount = (uint256(e.usdcPrize) * u.eligible) / e.eligibleTotal;
        isFirstClaimer = (e.firstClaimer == address(0));
        
        if (isFirstClaimer) {
            amount += e.bounty;
        }
    }

    /**
     * @notice Get user's progress toward qualification
     * @return qualified Whether user is qualified
     * @return volumeTraded Total USDC volume traded
     * @return shortfall Remaining USDC needed to qualify (0 if qualified)
     */
    function getUserProgress(
        address token,
        uint32 epoch,
        address user
    ) external view returns (
        bool qualified,
        uint128 volumeTraded,
        uint96 shortfall
    ) {
        qualified = _isQualified(token, epoch, user);
        UserState storage u = users[token][epoch][user];
        
        if (qualified) {
            volumeTraded = u.eligible;
            shortfall = 0;
        } else {
            shortfall = u.shortfall == 0 ? THRESHOLD : u.shortfall;
            volumeTraded = THRESHOLD - shortfall;
        }
    }

    /**
     * @notice Get live epoch data including accumulated rewards
     * @param token Graduated token address
     * @param epoch Epoch number
     * @return totalUsdcVolume Total buy-side USDC volume in epoch
     * @return eligibleTotal Total eligible volume (qualified users only)
     * @return usdcPrize USDC prize pool for traders (100% of fees in V3)
     * @return rolloverPrize Rolled over prize from previous epoch
     * @return finalized Whether epoch has been finalized
     * @return qualifiedCount Approximate count of qualified users (not exact due to bitmap)
     */
    function getEpochData(
        address token,
        uint32 epoch
    ) external view returns (
        uint128 totalUsdcVolume,
        uint128 eligibleTotal,
        uint128 usdcPrize,
        uint128 rolloverPrize,
        bool finalized,
        uint256 qualifiedCount
    ) {
        EpochData storage e = epochs[token][epoch];
        
        totalUsdcVolume = e.totalUsdcVolume;
        eligibleTotal = e.eligibleTotal;
        usdcPrize = e.usdcPrize;
        rolloverPrize = e.rolloverPrize;
        finalized = e.finalized;
        
        // Note: qualifiedCount is not stored, would need to iterate bitmap
        // For gas efficiency, we return 0 here. Frontend can track this off-chain.
        qualifiedCount = 0;
    }

    // V3: getCreatorClaimableReward removed - creator rewards handled by FeeDistributor

    /**
     * @notice Get estimated prize pool for an epoch (before finalization)
     * @dev V3 REDESIGN: Reads flushed fees + unflushed fees from FeeDistributor + accumulated dead-epoch rollover
     * @param token Graduated token address
     * @param epoch Epoch number
     * @return totalPrize Estimated total prize after bounty deduction
     * @return bounty Estimated first claimer bounty (1% of pool)
     * @return fees Flushed fees for this epoch
     * @return accumulatedRollover Rollover from prior dead epochs + this epoch's rollover
     * @return hasQualifiers Whether this epoch has qualified users
     * @return isFinalized Whether epoch is already finalized
     */
    function getEstimatedPrizePool(
        address token,
        uint32 epoch
    ) external view returns (
        uint128 totalPrize,
        uint128 bounty,
        uint128 fees,
        uint128 accumulatedRollover,
        bool hasQualifiers,
        bool isFinalized
    ) {
        EpochData storage e = epochs[token][epoch];
        hasQualifiers = e.eligibleTotal > 0;
        isFinalized = e.finalized;

        if (!hasQualifiers) return (0, 0, 0, 0, false, isFinalized);

        if (isFinalized) {
            // Return actual finalized values
            totalPrize = e.usdcPrize;
            bounty = e.bounty;
            accumulatedRollover = 0;
            return (totalPrize, bounty, 0, 0, true, true);
        }

        // This epoch's own flushed fees
        uint128 _fees = uint128(epochFees[token][epoch]);
        fees = _fees;

        // Accumulate rollover from all consecutive dead epochs since last finalized
        uint128 deadRollover = 0;
        for (uint32 eid = epoch; eid > 0; eid--) {
            EpochData storage prior = epochs[token][eid - 1];
            if (prior.finalized) break;
            if (prior.eligibleTotal > 0) break;

            deadRollover += uint128(epochFees[token][eid - 1]);
            deadRollover += prior.rolloverPrize;
        }

        accumulatedRollover = e.rolloverPrize + deadRollover;
        uint128 totalPool = _fees + accumulatedRollover;
        uint128 _bounty = totalPool > 0
            ? uint128((totalPool * FIRST_CLAIMER_BOUNTY_BPS) / 10000)
            : 0;

        totalPrize = totalPool - _bounty;
        bounty = _bounty;
    }

    /**
     * @notice Sweep dead epochs and pay gas rebate to caller
     * @dev V3 REDESIGN: Handles all-dead-epoch chains where no alive epoch exists to claim from.
     *      Caller receives `deadEpochSweepReward` USDC as gas compensation.
     * @param token Graduated token address
     * @param deadEpochs Array of epoch numbers to mark as dead
     */
    function sweepDeadEpochs(address token, uint32[] calldata deadEpochs) external {
        require(registry.isMarketOpen(token), "not graduated");
        uint256 graduatedTime = registry.getMarket(token).enabledAt;
        require(graduatedTime > 0, "invalid grad time");

        uint128 totalRollover = 0;

        for (uint256 i = 0; i < deadEpochs.length; i++) {
            uint32 epoch = deadEpochs[i];
            require(_epochEnded(token, epoch), "epoch live");

            EpochData storage e = epochs[token][epoch];
            if (e.finalized) continue;
            if (e.eligibleTotal > 0) continue; // skip alive epochs

            uint128 fees = uint128(epochFees[token][epoch]);
            if (fees > 0) {
                totalRollover += fees;
                epochFees[token][epoch] = 0;
            }
            if (e.rolloverPrize > 0) {
                totalRollover += e.rolloverPrize;
                e.rolloverPrize = 0;
            }
            e.finalized = true;
            emit EpochMarkedDead(token, epoch);
        }

        // Pay gas rebate from Contest's own USDC balance
        uint128 rewardPaid = 0;
        if (totalRollover > 0 && deadEpochSweepReward > 0) {
            address usdc = _getUsdc();
            IERC20(usdc).safeTransfer(msg.sender, deadEpochSweepReward);
            rewardPaid = deadEpochSweepReward;
        }

        emit DeadEpochsSwept(token, deadEpochs, totalRollover, rewardPaid);
    }

    // --- Public View Functions ---

    /**
     * @notice Get current epoch for a token
     * @dev FIX (L-4): Returns 0 for non-graduated tokens for backward compatibility
     *      Use isTokenGraduated() to check if token is graduated before interpreting epoch 0
     * @param token Token address
     * @return Current epoch number (0 if not graduated OR if in first epoch)
     */
    function getCurrentEpoch(address token) public view returns (uint32) {
        uint32 epoch = _currentEpoch(token);
        // Return 0 for non-graduated tokens (backward compatibility)
        return epoch == type(uint32).max ? 0 : epoch;
    }

    // --- Internals ---

    /**
     * @notice Get current epoch for a token
     * @dev FIX (L-4): Returns type(uint32).max for non-graduated tokens to distinguish from epoch 0
     *      Epoch 0 is valid for the first 7 days after graduation
     * @param token Token address
     * @return epoch Current epoch number, or type(uint32).max if not graduated
     */
    function _currentEpoch(address token) private view returns (uint32) {
        if (!registry.isMarketOpen(token)) return type(uint32).max; // FIX (L-4): Distinguish from epoch 0
        uint256 graduatedTime = registry.getMarket(token).enabledAt;
        if (graduatedTime == 0) return type(uint32).max; // FIX (L-4): Distinguish from epoch 0
        return uint32((block.timestamp - graduatedTime) / EPOCH_LENGTH);
    }

    function _epochEnded(address token, uint32 epoch) private view returns (bool) {
        if (!registry.isMarketOpen(token)) return false;
        uint256 graduatedTime = registry.getMarket(token).enabledAt;
        if (graduatedTime == 0) return false;
        
        uint256 epochEnd = graduatedTime + (uint256(epoch) + 1) * EPOCH_LENGTH;
        return block.timestamp >= epochEnd;
    }

    // CRITICAL FIX (#2): Replaced bitmap helpers with direct mapping access
    // Old bitmap approach had only 256 bit positions = guaranteed collisions
    
    function _isQualified(address token, uint32 epoch, address user) private view returns (bool) {
        return qualifiedMap[token][epoch][user];
    }

    function _setQualified(address token, uint32 epoch, address user) private {
        qualifiedMap[token][epoch][user] = true;
    }

    function _isClaimed(address token, uint32 epoch, address user) private view returns (bool) {
        return claimedMap[token][epoch][user];
    }

    function _setClaimed(address token, uint32 epoch, address user) private {
        claimedMap[token][epoch][user] = true;
    }
}
