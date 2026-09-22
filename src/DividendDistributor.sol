// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Registry.sol";
import "./MinimumERC20.sol";

/**
 * @title DividendDistributor
 * @notice Allows token creators to distribute USDC dividends to token holders based on snapshots
 * @dev Supports multiple dividend rounds with claim-based distribution
 * @dev Uses ERC20Snapshot to prevent double-claims and include vault depositors
 */
contract DividendDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Registry contract (single source of truth for all addresses)
    Registry public immutable registry;

    // Dividend round structure
    struct DividendRound {
        uint256 totalAmount;        // Total USDC to distribute
        uint256 snapshotId;         // ERC20Snapshot ID for this round
        uint256 snapshotTimestamp;  // When the snapshot was taken
        uint256 totalSupplySnapshot; // Total supply at snapshot
        mapping(address => bool) claimed; // Whether user has claimed
        uint256 totalClaimed;       // Total amount claimed so far
        bool active;                // Whether round is active and accepting claims
    }

    // Token => Round ID => Dividend Round
    mapping(address => mapping(uint256 => DividendRound)) public dividendRounds;
    
    // Token => Current round ID
    mapping(address => uint256) public currentRoundId;

    // Events
    event DividendRoundCreated(
        address indexed token,
        uint256 indexed roundId,
        uint256 totalAmount,
        uint256 snapshotTimestamp
    );
    
    event DividendRoundActivated(
        address indexed token,
        uint256 indexed roundId,
        uint256 snapshotId,
        uint256 totalSupplySnapshot
    );
    
    event DividendClaimed(
        address indexed token,
        uint256 indexed roundId,
        address indexed claimer,
        uint256 amount
    );
    
    event EmergencyWithdrawal(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
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

    /**
     * @notice Check if caller is authorized to create dividends for a token
     * @dev Uses centralized Registry access control
     */
    modifier onlyAuthorizedDistributor(address token) {
        require(
            registry.isAuthorizedDividendDistributor(token, msg.sender),
            "Not authorized"
        );
        _;
    }

    /**
     * @notice Whitelist/unwhitelist an address to distribute dividends for a token
     * @dev DEPRECATED: Use Registry.authorizeDividendDistributor() instead
     * @dev This function now forwards to Registry for centralized access control
     * @param token The token address
     * @param distributor The address to whitelist
     * @param whitelisted Whether to whitelist or not
     */
    function setWhitelist(
        address token,
        address distributor,
        bool whitelisted
    ) external {
        // Forward to Registry for centralized management
        registry.authorizeDividendDistributor(token, distributor, whitelisted);
    }

    /**
     * @notice Create a new dividend round, deposit USDC, and activate immediately
     * @dev FIX (#6): Rounds are now activated on creation to prevent stuck funds
     * @param token The token to distribute dividends for
     * @param amount The total USDC amount to distribute
     * @return roundId The ID of the created round
     */
    function createDividendRound(
        address token,
        uint256 amount
    ) external onlyAuthorizedDistributor(token) nonReentrant returns (uint256 roundId) {
        require(amount > 0, "Amount must be > 0");
        
        // Verify token is registered
        (address creator,,,,,,,,,,,,) = registry.campaigns(token);
        require(creator != address(0), "Token not registered");
        
        // Transfer USDC from sender
        _usdc().safeTransferFrom(msg.sender, address(this), amount);
        
        // Increment round ID
        roundId = ++currentRoundId[token];
        
        // Create snapshot immediately - this freezes all balances at this moment
        uint256 snapshotId = MinimumERC20(token).snapshot();
        require(snapshotId > 0, "Snapshot creation failed");
        
        // Get total supply at snapshot
        uint256 totalSupply = MinimumERC20(token).totalSupplyAt(snapshotId);
        require(totalSupply > 0, "Invalid total supply");
        
        // Initialize round as active
        DividendRound storage round = dividendRounds[token][roundId];
        round.totalAmount = amount;
        round.snapshotId = snapshotId;
        round.snapshotTimestamp = block.timestamp;
        round.totalSupplySnapshot = totalSupply;
        round.totalClaimed = 0;
        round.active = true;
        
        emit DividendRoundCreated(token, roundId, amount, block.timestamp);
        emit DividendRoundActivated(token, roundId, snapshotId, totalSupply);
    }

    /**
     * @notice Claim dividends for a specific round
     * @dev Uses snapshot balance to prevent double-claims via token transfers
     * @dev Users can claim even if they've transferred tokens after snapshot
     * @param token The token address
     * @param roundId The dividend round ID
     */
    function claimDividend(
        address token,
        uint256 roundId
    ) external nonReentrant {
        DividendRound storage round = dividendRounds[token][roundId];
        require(round.active, "Round not active");
        require(!round.claimed[msg.sender], "Already claimed");
        
        // Read balance AT SNAPSHOT TIME - prevents double-claims
        // This is the balance the user had when the snapshot was taken
        uint256 holderBalance = MinimumERC20(token).balanceOfAt(msg.sender, round.snapshotId);
        require(holderBalance > 0, "No token balance at snapshot");
        
        // Calculate dividend amount based on snapshot balance
        uint256 dividendAmount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
        require(dividendAmount > 0, "No dividend to claim");
        
        // Mark as claimed
        round.claimed[msg.sender] = true;
        round.totalClaimed += dividendAmount;
        
        // Transfer USDC
        _usdc().safeTransfer(msg.sender, dividendAmount);
        
        emit DividendClaimed(token, roundId, msg.sender, dividendAmount);
    }

    /**
     * @notice Claim dividends for multiple rounds at once
     * @dev Uses snapshot balance for each round to prevent double-claims
     * @param token The token address
     * @param roundIds Array of round IDs to claim
     */
    function claimDividendBatch(
        address token,
        uint256[] calldata roundIds
    ) external nonReentrant {
        uint256 totalDividend = 0;
        
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 roundId = roundIds[i];
            DividendRound storage round = dividendRounds[token][roundId];
            
            // Skip if not active or already claimed
            if (!round.active || round.claimed[msg.sender]) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(msg.sender, round.snapshotId);
            if (holderBalance == 0) {
                continue;
            }
            
            // Calculate dividend amount based on snapshot balance
            uint256 dividendAmount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
            if (dividendAmount == 0) {
                continue;
            }
            
            // Mark as claimed
            round.claimed[msg.sender] = true;
            round.totalClaimed += dividendAmount;
            totalDividend += dividendAmount;
            
            emit DividendClaimed(token, roundId, msg.sender, dividendAmount);
        }
        
        require(totalDividend > 0, "No dividends to claim");
        
        // Transfer total USDC
        _usdc().safeTransfer(msg.sender, totalDividend);
    }

    /**
     * @notice Claim ALL unclaimed dividends for a token with pagination
     * @dev Fix 14: Added pagination to prevent gas limit issues with many rounds
     * @param token The token address
     * @param startRound Starting round ID (1-indexed, use 1 for first round)
     * @param maxRounds Maximum number of rounds to process (0 = all remaining)
     */
    function claimAllDividends(address token, uint256 startRound, uint256 maxRounds) external nonReentrant {
        uint256 maxRoundId = currentRoundId[token];
        require(maxRoundId > 0, "No dividend rounds exist");
        require(startRound > 0 && startRound <= maxRoundId, "Invalid start round");
        
        uint256 totalDividend = 0;
        uint256 endRound = maxRounds == 0 ? maxRoundId : startRound + maxRounds - 1;
        if (endRound > maxRoundId) endRound = maxRoundId;
        
        for (uint256 roundId = startRound; roundId <= endRound; roundId++) {
            DividendRound storage round = dividendRounds[token][roundId];
            
            // Skip if not active or already claimed
            if (!round.active || round.claimed[msg.sender]) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(msg.sender, round.snapshotId);
            if (holderBalance == 0) {
                continue;
            }
            
            // Calculate dividend amount based on snapshot balance
            uint256 dividendAmount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
            if (dividendAmount == 0) {
                continue;
            }
            
            // Mark as claimed
            round.claimed[msg.sender] = true;
            round.totalClaimed += dividendAmount;
            totalDividend += dividendAmount;
            
            emit DividendClaimed(token, roundId, msg.sender, dividendAmount);
        }
        
        require(totalDividend > 0, "No dividends to claim");
        
        // Transfer total USDC
        _usdc().safeTransfer(msg.sender, totalDividend);
    }
    
    /**
     * @notice Convenience function to claim all dividends from round 1
     * @dev Calls claimAllDividends with startRound=1 and maxRounds=50 (safe default)
     * @param token The token address
     */
    function claimAllDividendsSimple(address token) external nonReentrant {
        uint256 maxRoundId = currentRoundId[token];
        require(maxRoundId > 0, "No dividend rounds exist");
        
        uint256 totalDividend = 0;
        uint256 endRound = maxRoundId > 50 ? 50 : maxRoundId; // Limit to 50 rounds for gas safety
        
        for (uint256 roundId = 1; roundId <= endRound; roundId++) {
            DividendRound storage round = dividendRounds[token][roundId];
            
            // Skip if not active or already claimed
            if (!round.active || round.claimed[msg.sender]) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(msg.sender, round.snapshotId);
            if (holderBalance == 0) {
                continue;
            }
            
            // Calculate dividend amount based on snapshot balance
            uint256 dividendAmount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
            if (dividendAmount == 0) {
                continue;
            }
            
            // Mark as claimed
            round.claimed[msg.sender] = true;
            round.totalClaimed += dividendAmount;
            totalDividend += dividendAmount;
            
            emit DividendClaimed(token, roundId, msg.sender, dividendAmount);
        }
        
        require(totalDividend > 0, "No dividends to claim");
        
        // Transfer total USDC
        _usdc().safeTransfer(msg.sender, totalDividend);
    }

    /**
     * @notice Get claimable dividend amount for a holder in a specific round
     * @dev Uses snapshot balance to show accurate claimable amount
     * @param token The token address
     * @param roundId The dividend round ID
     * @param holder The holder address
     * @return amount The claimable dividend amount
     */
    function getClaimableAmount(
        address token,
        uint256 roundId,
        address holder
    ) external view returns (uint256 amount) {
        DividendRound storage round = dividendRounds[token][roundId];
        
        if (!round.active || round.claimed[holder]) {
            return 0;
        }
        
        // Read balance at snapshot time
        uint256 holderBalance = MinimumERC20(token).balanceOfAt(holder, round.snapshotId);
        if (holderBalance == 0 || round.totalSupplySnapshot == 0) {
            return 0;
        }
        
        amount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
    }

    /**
     * @notice Get total claimable dividend amount across multiple rounds
     * @dev Uses snapshot balance for each round to show accurate claimable amounts
     * @param token The token address
     * @param holder The holder address
     * @param fromRound Starting round ID
     * @param toRound Ending round ID (inclusive)
     * @return totalAmount Total claimable amount
     */
    function getTotalClaimableAmount(
        address token,
        address holder,
        uint256 fromRound,
        uint256 toRound
    ) external view returns (uint256 totalAmount) {
        for (uint256 roundId = fromRound; roundId <= toRound; roundId++) {
            DividendRound storage round = dividendRounds[token][roundId];
            
            if (!round.active || round.claimed[holder]) {
                continue;
            }
            
            if (round.totalSupplySnapshot == 0) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(holder, round.snapshotId);
            if (holderBalance == 0) {
                continue;
            }
            
            totalAmount += (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
        }
    }

    /**
     * @notice Check if a holder has claimed for a specific round
     * @param token The token address
     * @param roundId The dividend round ID
     * @param holder The holder address
     * @return claimed Whether the holder has claimed
     */
    function hasClaimed(
        address token,
        uint256 roundId,
        address holder
    ) external view returns (bool claimed) {
        return dividendRounds[token][roundId].claimed[holder];
    }

    /**
     * @notice Get dividend round information
     * @param token The token address
     * @param roundId The dividend round ID
     * @return totalAmount Total USDC amount
     * @return snapshotTimestamp Snapshot timestamp
     * @return totalSupplySnapshot Total supply at snapshot
     * @return totalClaimed Total amount claimed
     * @return active Whether round is active and accepting claims
     */
    function getDividendRoundInfo(
        address token,
        uint256 roundId
    ) external view returns (
        uint256 totalAmount,
        uint256 snapshotTimestamp,
        uint256 totalSupplySnapshot,
        uint256 totalClaimed,
        bool active
    ) {
        DividendRound storage round = dividendRounds[token][roundId];
        return (
            round.totalAmount,
            round.snapshotTimestamp,
            round.totalSupplySnapshot,
            round.totalClaimed,
            round.active
        );
    }

    /**
     * @notice Get detailed information about unclaimed dividends for a holder
     * @dev Uses snapshot balance for each round to show accurate claimable amounts
     * @param token The token address
     * @param holder The holder address
     * @return roundIds Array of unclaimed round IDs
     * @return amounts Array of claimable amounts per round
     * @return totalAmount Total claimable amount across all rounds
     */
    function getUnclaimedDividends(
        address token,
        address holder
    ) external view returns (
        uint256[] memory roundIds,
        uint256[] memory amounts,
        uint256 totalAmount
    ) {
        uint256 maxRoundId = currentRoundId[token];
        
        // First pass: count unclaimed rounds
        uint256 unclaimedCount = 0;
        for (uint256 roundId = 1; roundId <= maxRoundId; roundId++) {
            DividendRound storage round = dividendRounds[token][roundId];
            
            if (!round.active || round.claimed[holder]) {
                continue;
            }
            
            if (round.totalSupplySnapshot == 0) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(holder, round.snapshotId);
            uint256 amount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
            if (amount > 0) {
                unclaimedCount++;
            }
        }
        
        // Second pass: populate arrays
        roundIds = new uint256[](unclaimedCount);
        amounts = new uint256[](unclaimedCount);
        uint256 index = 0;
        
        for (uint256 roundId = 1; roundId <= maxRoundId; roundId++) {
            DividendRound storage round = dividendRounds[token][roundId];
            
            if (!round.active || round.claimed[holder]) {
                continue;
            }
            
            if (round.totalSupplySnapshot == 0) {
                continue;
            }
            
            // Read balance at snapshot time for this round
            uint256 holderBalance = MinimumERC20(token).balanceOfAt(holder, round.snapshotId);
            uint256 amount = (round.totalAmount * holderBalance) / round.totalSupplySnapshot;
            if (amount > 0) {
                roundIds[index] = roundId;
                amounts[index] = amount;
                totalAmount += amount;
                index++;
            }
        }
    }

    // CRITICAL FIX (M-6): Minimum claim period before emergency withdrawal
    // FIX (H-6): Extended to 90 days to give holders more time to claim
    // Configurable: test default 2 hours for fast iteration; production: 90 days
    uint256 public MIN_CLAIM_PERIOD = 2 hours; // production: 90 days
    
    /**
     * @notice Emergency withdrawal function for token creator
     * @dev Allows creator to withdraw ONLY their token's unclaimed dividends in case of emergency
     *      CRITICAL FIX (M-6): Added minimum claim period to prevent immediate theft
     * @param token The token address
     * @param recipient Address to receive the USDC
     * @param roundId The dividend round ID to withdraw from
     */
    function emergencyWithdraw(
        address token,
        address recipient,
        uint256 roundId
    ) external nonReentrant {
        require(
            registry.isCampaignCreator(token, msg.sender),
            "Only token creator"
        );
        require(recipient != address(0), "Invalid recipient");
        
        DividendRound storage round = dividendRounds[token][roundId];
        require(round.totalAmount > 0, "Round does not exist");
        require(round.active, "Round not active");
        
        // CRITICAL FIX (M-6): Enforce minimum claim period before emergency withdrawal
        require(
            block.timestamp >= round.snapshotTimestamp + MIN_CLAIM_PERIOD,
            "Claim period not elapsed"
        );
        
        // Calculate unclaimed amount for this specific round
        uint256 unclaimed = round.totalAmount - round.totalClaimed;
        require(unclaimed > 0, "No unclaimed dividends");
        
        // Mark all as claimed to prevent double withdrawal
        round.totalClaimed = round.totalAmount;
        
        // Transfer USDC
        _usdc().safeTransfer(recipient, unclaimed);
        
        emit EmergencyWithdrawal(token, recipient, unclaimed);
    }

    /**
     * @notice Set minimum claim period (production configuration)
     * @dev Test default: 2 hours for fast iteration; production: 90 days
     *      Only Registry owner (multisig) can set this
     * @param _minClaimPeriod Minimum claim period in seconds
     */
    function setMinClaimPeriod(uint256 _minClaimPeriod) external {
        require(msg.sender == registry.owner(), "Only registry owner");
        require(_minClaimPeriod >= 1 hours && _minClaimPeriod <= 365 days, "Invalid claim period");
        MIN_CLAIM_PERIOD = _minClaimPeriod;
        emit MinClaimPeriodUpdated(_minClaimPeriod);
    }

    event MinClaimPeriodUpdated(uint256 minClaimPeriod);
}
