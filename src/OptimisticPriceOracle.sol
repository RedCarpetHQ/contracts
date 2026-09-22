// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./HybridPriceOracle.sol";
import "./MinimumERC20.sol";
import "./Registry.sol";

/**
 * @title OptimisticPriceOracle
 * @notice UMA-style optimistic oracle for trustless off-chain price feeds
 * @dev Allows anyone to propose prices with bond, 2-hour challenge window, governance dispute resolution
 */
contract OptimisticPriceOracle is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    uint256 public constant ONE = 1e18;
    
    // Price assertion structure
    struct PriceAssertion {
        address proposer;
        address challenger;
        uint256 proposedPrice;
        uint256 bond;
        uint256 timestamp;
        uint256 challengeDeadline;
        bool disputed;
        bool resolved;
        bool accepted;  // true if accepted, false if rejected
    }
    
    // Governance vote structure
    struct GovernanceVote {
        uint256 votesFor;      // Votes supporting the assertion
        uint256 votesAgainst;  // Votes challenging the assertion
        uint256 deadline;
        uint256 snapshotId;    // CRITICAL FIX (#11): Snapshot ID for vote weight
        bool finalized;
        mapping(address => bool) hasVoted;
    }
    
    // Configuration
    uint256 public challengeWindow = 5 minutes; // production 48 hours;
    uint256 public bondAmount = 1000e6; // 1000 USDC
    uint256 public voteDuration = 30 minutes; // production 7 days;
    uint256 public minQuorumBps = 1000; // 10% of total supply
    
    Registry public registry; // Registry to lookup per-asset governance token and other addresses
    
    // Storage
    mapping(address => PriceAssertion) public assertions;
    mapping(address => GovernanceVote) public votes;
    mapping(address => uint256) public lastFinalizedPrice;
    mapping(address => uint256) public lastFinalizedTime;
    
    // Events
    event PriceProposed(address indexed asset, uint256 price, address indexed proposer, uint256 deadline);
    event PriceDisputed(address indexed asset, address indexed challenger);
    event VoteCast(address indexed asset, address indexed voter, bool support, uint256 weight);
    event PriceFinalized(address indexed asset, uint256 price, bool accepted);
    event BondSlashed(address indexed slashed, address indexed recipient, uint256 amount);
    event ConfigUpdated(uint256 challengeWindow, uint256 bondAmount, uint256 voteDuration);
    event QuorumNotReached(address indexed asset, uint256 totalVotes, uint256 quorumRequired); // FIX (M-11)
    
    constructor(
        address _owner,
        address _registry
    ) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    // --- Registry Address Helpers ---
    
    function _getBondToken() internal view returns (IERC20) {
        address addr = registry.usdc();
        return addr != address(0) ? IERC20(addr) : IERC20(address(0));
    }
    
    function _getPriceOracle() internal view returns (IPriceOracle) {
        address addr = registry.hybridPriceOracle();
        return addr != address(0) ? IPriceOracle(addr) : IPriceOracle(address(0));
    }
    
    /**
     * @notice Propose a new price for an asset
     * @param asset Token address
     * @param price Proposed price (scaled to 1e18)
     */
    function proposePrice(address asset, uint256 price) external nonReentrant {
        require(price > 0, "Invalid price");
        
        PriceAssertion storage assertion = assertions[asset];
        
        // Check if there's an active assertion
        if (assertion.timestamp > 0 && !assertion.resolved) {
            require(block.timestamp > assertion.challengeDeadline, "Active assertion exists");
            
            // Auto-finalize expired assertion if not disputed
            if (!assertion.disputed) {
                _finalizeAssertion(asset);
            }
        }
        
        // Take bond from proposer
        IERC20 _bondToken = _getBondToken();
        require(address(_bondToken) != address(0), "Bond token not set in Registry");
        _bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        
        // Create new assertion
        assertions[asset] = PriceAssertion({
            proposer: msg.sender,
            challenger: address(0),
            proposedPrice: price,
            bond: bondAmount,
            timestamp: block.timestamp,
            challengeDeadline: block.timestamp + challengeWindow,
            disputed: false,
            resolved: false,
            accepted: false
        });
        
        emit PriceProposed(asset, price, msg.sender, block.timestamp + challengeWindow);
    }
    
    /**
     * @notice Dispute a proposed price
     * @param asset Token address
     */
    function disputePrice(address asset) external nonReentrant {
        PriceAssertion storage assertion = assertions[asset];
        
        require(assertion.timestamp > 0, "No active assertion");
        require(!assertion.resolved, "Already resolved");
        require(!assertion.disputed, "Already disputed");
        require(block.timestamp <= assertion.challengeDeadline, "Challenge window closed");
        
        // Take bond from challenger
        IERC20 _bondToken = _getBondToken();
        require(address(_bondToken) != address(0), "Bond token not set in Registry");
        _bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        
        assertion.disputed = true;
        assertion.challenger = msg.sender;
        
        // Initiate governance vote
        _initiateGovernanceVote(asset);
        
        emit PriceDisputed(asset, msg.sender);
    }
    
    /**
     * @notice Finalize a price assertion after challenge window
     * @param asset Token address
     */
    function finalizePrice(address asset) external nonReentrant {
        _finalizeAssertion(asset);
    }
    
    /**
     * @notice Internal function to finalize assertion
     */
    function _finalizeAssertion(address asset) internal {
        PriceAssertion storage assertion = assertions[asset];
        
        require(assertion.timestamp > 0, "No assertion");
        require(!assertion.resolved, "Already resolved");
        require(block.timestamp > assertion.challengeDeadline, "Challenge window open");
        require(!assertion.disputed, "Price disputed - use governance");
        
        // Accept the price
        assertion.resolved = true;
        assertion.accepted = true;
        
        // Update oracle (cast to HybridPriceOracle which has setPrice)
        IPriceOracle _priceOracle = _getPriceOracle();
        require(address(_priceOracle) != address(0), "Price oracle not set in Registry");
        HybridPriceOracle(address(_priceOracle)).setPrice(asset, assertion.proposedPrice);
        
        // Return bond to proposer
        IERC20 _bondToken = _getBondToken();
        require(address(_bondToken) != address(0), "Bond token not set in Registry");
        _bondToken.safeTransfer(assertion.proposer, assertion.bond);
        
        // Track finalized price
        lastFinalizedPrice[asset] = assertion.proposedPrice;
        lastFinalizedTime[asset] = block.timestamp;
        
        emit PriceFinalized(asset, assertion.proposedPrice, true);
    }
    
    /**
     * @notice Initiate governance vote for disputed price
     */
    function _initiateGovernanceVote(address asset) internal {
        GovernanceVote storage vote = votes[asset];
        vote.votesFor = 0;
        vote.votesAgainst = 0;
        vote.deadline = block.timestamp + voteDuration;
        vote.finalized = false;
        
        // CRITICAL FIX (#11): Create snapshot to freeze voting weights
        // This prevents vote manipulation via token transfers during voting
        // Use the asset token itself for governance (each token governs its own price)
        vote.snapshotId = MinimumERC20(asset).snapshot();
    }
    
    /**
     * @notice Cast vote on disputed price
     * @param asset Token address
     * @param support True to support assertion, false to reject
     */
    function castVote(address asset, bool support) external nonReentrant {
        PriceAssertion storage assertion = assertions[asset];
        GovernanceVote storage vote = votes[asset];
        
        require(assertion.disputed, "Not disputed");
        require(!assertion.resolved, "Already resolved");
        require(!vote.finalized, "Vote finalized");
        require(block.timestamp <= vote.deadline, "Vote ended");
        require(!vote.hasVoted[msg.sender], "Already voted");
        
        // CRITICAL FIX (#11): Get voting weight from SNAPSHOT, not current balance
        // This prevents vote manipulation via token transfers
        // Use the asset token itself for governance
        uint256 weight = MinimumERC20(asset).balanceOfAt(msg.sender, vote.snapshotId);
        require(weight > 0, "No voting power at snapshot");
        
        vote.hasVoted[msg.sender] = true;
        
        if (support) {
            vote.votesFor += weight;
        } else {
            vote.votesAgainst += weight;
        }
        
        emit VoteCast(asset, msg.sender, support, weight);
    }
    
    /**
     * @notice Finalize governance vote and resolve dispute
     * @param asset Token address
     */
    function finalizeGovernanceVote(address asset) external nonReentrant {
        PriceAssertion storage assertion = assertions[asset];
        GovernanceVote storage vote = votes[asset];
        
        require(assertion.disputed, "Not disputed");
        require(!assertion.resolved, "Already resolved");
        require(!vote.finalized, "Already finalized");
        require(block.timestamp > vote.deadline, "Vote ongoing");
        
        vote.finalized = true;
        assertion.resolved = true;
        
        // Check quorum using snapshot total supply (use asset token)
        uint256 totalVotes = vote.votesFor + vote.votesAgainst;
        uint256 totalSupply = MinimumERC20(asset).totalSupplyAt(vote.snapshotId);
        uint256 quorum = totalSupply * minQuorumBps / 10000;
        
        bool quorumReached = totalVotes >= quorum;
        bool assertionAccepted = quorumReached && vote.votesFor > vote.votesAgainst;
        
        assertion.accepted = assertionAccepted;
        
        // Get addresses from Registry
        IPriceOracle _priceOracle = _getPriceOracle();
        IERC20 _bondToken = _getBondToken();
        require(address(_bondToken) != address(0), "Bond token not set in Registry");
        
        if (assertionAccepted) {
            // Assertion accepted - update oracle, return bond to proposer, slash challenger
            require(address(_priceOracle) != address(0), "Price oracle not set in Registry");
            HybridPriceOracle(address(_priceOracle)).setPrice(asset, assertion.proposedPrice);
            _bondToken.safeTransfer(assertion.proposer, assertion.bond * 2); // Proposer gets both bonds
            
            lastFinalizedPrice[asset] = assertion.proposedPrice;
            lastFinalizedTime[asset] = block.timestamp;
            
            emit BondSlashed(assertion.challenger, assertion.proposer, assertion.bond);
        } else if (quorumReached) {
            // Assertion rejected with quorum - return bond to challenger, slash proposer
            _bondToken.safeTransfer(assertion.challenger, assertion.bond * 2); // Challenger gets both bonds
            
            emit BondSlashed(assertion.proposer, assertion.challenger, assertion.bond);
        } else {
            // FIX (M-11): Quorum NOT reached - return bonds to BOTH parties
            // This prevents griefing where bonds get stuck forever
            _bondToken.safeTransfer(assertion.proposer, assertion.bond);
            _bondToken.safeTransfer(assertion.challenger, assertion.bond);
            
            emit QuorumNotReached(asset, totalVotes, quorum);
        }
        
        emit PriceFinalized(asset, assertion.proposedPrice, assertionAccepted);
    }
    
    /**
     * @notice Get current price assertion for asset
     */
    function getAssertion(address asset) external view returns (
        address proposer,
        uint256 proposedPrice,
        uint256 deadline,
        bool disputed,
        bool resolved,
        bool accepted
    ) {
        PriceAssertion memory assertion = assertions[asset];
        return (
            assertion.proposer,
            assertion.proposedPrice,
            assertion.challengeDeadline,
            assertion.disputed,
            assertion.resolved,
            assertion.accepted
        );
    }
    
    /**
     * @notice Get governance vote status
     */
    function getVoteStatus(address asset) external view returns (
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 deadline,
        bool finalized,
        bool quorumReached
    ) {
        GovernanceVote storage vote = votes[asset];
        uint256 totalVotes = vote.votesFor + vote.votesAgainst;
        // Use asset token's total supply at snapshot for quorum calculation
        uint256 totalSupply = vote.snapshotId > 0 
            ? MinimumERC20(asset).totalSupplyAt(vote.snapshotId)
            : IERC20(asset).totalSupply();
        uint256 quorum = totalSupply * minQuorumBps / 10000;
        
        return (
            vote.votesFor,
            vote.votesAgainst,
            vote.deadline,
            vote.finalized,
            totalVotes >= quorum
        );
    }
    
    /**
     * @notice Check if user has voted
     */
    function hasVoted(address asset, address voter) external view returns (bool) {
        return votes[asset].hasVoted[voter];
    }
    
    /**
     * @notice Get last finalized price
     */
    function getLastFinalizedPrice(address asset) external view returns (uint256 price, uint256 timestamp) {
        return (lastFinalizedPrice[asset], lastFinalizedTime[asset]);
    }
    
    /**
     * @notice Check if asset has an active dispute
     * @dev Used by RiskOracle for risk assessment
     * @param asset Token address
     * @return True if there's an active unresolved dispute
     */
    function hasActiveDispute(address asset) external view returns (bool) {
        PriceAssertion memory assertion = assertions[asset];
        return assertion.disputed && !assertion.resolved;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update configuration parameters
     */
    function updateConfig(
        uint256 _challengeWindow,
        uint256 _bondAmount,
        uint256 _voteDuration,
        uint256 _minQuorumBps
    ) external onlyOwner {
        require(_challengeWindow >= 1 hours && _challengeWindow <= 24 hours, "Invalid challenge window");
        require(_bondAmount >= 100e6, "Bond too low");
        require(_voteDuration >= 12 hours && _voteDuration <= 7 days, "Invalid vote duration");
        require(_minQuorumBps >= 100 && _minQuorumBps <= 5000, "Invalid quorum");
        
        challengeWindow = _challengeWindow;
        bondAmount = _bondAmount;
        voteDuration = _voteDuration;
        minQuorumBps = _minQuorumBps;
        
        emit ConfigUpdated(_challengeWindow, _bondAmount, _voteDuration);
    }
    
    // NOTE: setPriceOracle removed - now retrieved from Registry
    
    /**
     * @notice Update registry
     */
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    // Fix 10: emergencyWithdraw removed - users should withdraw their own tokens
    // Contract owner has no right to pull user tokens (bonds)
    // Users can withdraw their bonds after assertion resolution via normal flow
}
