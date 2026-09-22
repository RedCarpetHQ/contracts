// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Registry.sol";
import "./interfaces/IMinimumERC20.sol";
import "./interfaces/ICampaign.sol";

/**
 * @title SurveySnapshot
 * @notice Allows surveyors to snapshot token holders based on balance or purchase conditions
 * @dev Two modes:
 *      1. Query only - returns list of addresses matching criteria (off-chain use)
 *      2. Snapshot - stores snapshot on-chain for verification
 * 
 * Use cases:
 * - Snapshot holders with 100-500 tokens for notification targeting
 * - Query purchasers who bought 500-1000 tokens via campaign
 */
contract SurveySnapshot is Ownable, ReentrancyGuard {
    Registry public registry;
    
    // Snapshot data
    struct Snapshot {
        address token;
        address surveyor;
        uint256 minBalance;
        uint256 maxBalance;
        uint256 tokenSnapshotId;    // ERC20Snapshot ID (0 if using current balance)
        uint256 createdAt;
        bool isPurchaseQuery;       // true = query purchases, false = query balances
        string surveyId;            // Off-chain survey ID for linking
    }
    
    // Storage
    mapping(uint256 => Snapshot) public snapshots;
    mapping(uint256 => address[]) public snapshotAddresses;
    uint256 public snapshotCount;
    
    // Events
    event SnapshotCreated(
        uint256 indexed snapshotId,
        address indexed token,
        address indexed surveyor,
        uint256 minBalance,
        uint256 maxBalance,
        bool isPurchaseQuery,
        uint256 addressCount,
        string surveyId
    );
    
    constructor(address _owner, address _registry) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    /**
     * @notice Authorize a surveyor for a specific token
     * @dev DEPRECATED: Use Registry.setSurveyor() instead
     * @dev This function now forwards to Registry for centralized access control
     */
    function authorizeSurveyor(address token, address surveyor, bool authorized) external {
        // Forward to Registry for centralized management
        registry.setSurveyor(token, surveyor, authorized);
    }
    
    /**
     * @notice Check if address is authorized surveyor
     * @dev Uses centralized Registry access control
     */
    function isSurveyor(address token, address account) public view returns (bool) {
        return registry.isAuthorizedSurveyor(token, account) || account == owner();
    }
    
    modifier onlySurveyor(address token) {
        require(isSurveyor(token, msg.sender), "Not authorized surveyor");
        _;
    }
    
    /**
     * @notice Create a snapshot of holders with balance in range (stores on-chain)
     * @param token Campaign token address
     * @param minBalance Minimum balance (inclusive)
     * @param maxBalance Maximum balance (inclusive, 0 = no max)
     * @param addresses Array of addresses to check (from subgraph)
     * @param surveyId Off-chain survey ID for linking
     * @return snapshotId The created snapshot ID
     */
    function createBalanceSnapshot(
        address token,
        uint256 minBalance,
        uint256 maxBalance,
        address[] calldata addresses,
        string calldata surveyId
    ) external onlySurveyor(token) nonReentrant returns (uint256 snapshotId) {
        require(token != address(0), "Invalid token");
        require(minBalance > 0 || maxBalance > 0, "Must specify range");
        
        // Create ERC20 snapshot for point-in-time balances
        uint256 tokenSnapshotId = IMinimumERC20(token).snapshot();
        
        snapshotId = snapshotCount++;
        
        // Filter addresses that match criteria
        uint256 matchCount = 0;
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 balance = IMinimumERC20(token).balanceOfAt(addresses[i], tokenSnapshotId);
            if (_matchesRange(balance, minBalance, maxBalance)) {
                snapshotAddresses[snapshotId].push(addresses[i]);
                matchCount++;
            }
        }
        
        snapshots[snapshotId] = Snapshot({
            token: token,
            surveyor: msg.sender,
            minBalance: minBalance,
            maxBalance: maxBalance,
            tokenSnapshotId: tokenSnapshotId,
            createdAt: block.timestamp,
            isPurchaseQuery: false,
            surveyId: surveyId
        });
        
        emit SnapshotCreated(
            snapshotId,
            token,
            msg.sender,
            minBalance,
            maxBalance,
            false,
            matchCount,
            surveyId
        );
    }
    
    /**
     * @notice Create a snapshot of purchasers with total purchase in range
     * @param token Campaign token address
     * @param minPurchase Minimum total purchase (inclusive)
     * @param maxPurchase Maximum total purchase (inclusive, 0 = no max)
     * @param addresses Array of addresses to check (from subgraph)
     * @param surveyId Off-chain survey ID for linking
     * @return snapshotId The created snapshot ID
     */
    function createPurchaseSnapshot(
        address token,
        uint256 minPurchase,
        uint256 maxPurchase,
        address[] calldata addresses,
        string calldata surveyId
    ) external onlySurveyor(token) nonReentrant returns (uint256 snapshotId) {
        require(token != address(0), "Invalid token");
        require(minPurchase > 0 || maxPurchase > 0, "Must specify range");
        
        address campaignContract = _getCampaignContractForToken(token);
        require(campaignContract != address(0), "Campaign contract not set");
        
        snapshotId = snapshotCount++;
        
        // Filter addresses that match criteria
        uint256 matchCount = 0;
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 purchased = ICampaign(campaignContract).getUserPurchase(token, addresses[i]);
            if (_matchesRange(purchased, minPurchase, maxPurchase)) {
                snapshotAddresses[snapshotId].push(addresses[i]);
                matchCount++;
            }
        }
        
        snapshots[snapshotId] = Snapshot({
            token: token,
            surveyor: msg.sender,
            minBalance: minPurchase,
            maxBalance: maxPurchase,
            tokenSnapshotId: 0, // Not using ERC20 snapshot
            createdAt: block.timestamp,
            isPurchaseQuery: true,
            surveyId: surveyId
        });
        
        emit SnapshotCreated(
            snapshotId,
            token,
            msg.sender,
            minPurchase,
            maxPurchase,
            true,
            matchCount,
            surveyId
        );
    }
    
    /**
     * @notice Query holders with balance in range (view only, no storage)
     * @dev Use this for off-chain queries without gas cost for storage
     */
    function queryBalanceHolders(
        address token,
        uint256 minBalance,
        uint256 maxBalance,
        address[] calldata addresses
    ) external view returns (address[] memory matchingAddresses, uint256[] memory balances) {
        uint256 matchCount = 0;
        
        // First pass: count matches
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 balance = IMinimumERC20(token).balanceOf(addresses[i]);
            if (_matchesRange(balance, minBalance, maxBalance)) {
                matchCount++;
            }
        }
        
        // Second pass: populate arrays
        matchingAddresses = new address[](matchCount);
        balances = new uint256[](matchCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 balance = IMinimumERC20(token).balanceOf(addresses[i]);
            if (_matchesRange(balance, minBalance, maxBalance)) {
                matchingAddresses[index] = addresses[i];
                balances[index] = balance;
                index++;
            }
        }
    }
    
    /**
     * @notice Query purchasers with total purchase in range (view only)
     * @dev Returns matching addresses and their purchase amounts
     */
    function queryPurchasers(
        address token,
        uint256 minPurchase,
        uint256 maxPurchase,
        address[] calldata addresses
    ) external view returns (address[] memory, uint256[] memory) {
        return _queryPurchasersInternal(token, minPurchase, maxPurchase, addresses);
    }
    
    function _queryPurchasersInternal(
        address token,
        uint256 minPurchase,
        uint256 maxPurchase,
        address[] calldata addresses
    ) internal view returns (address[] memory matchingAddresses, uint256[] memory purchaseAmounts) {
        address campaignContract = _getCampaignContractForToken(token);
        require(campaignContract != address(0), "Campaign contract not set");
        
        // Count matches first
        uint256 matchCount = _countPurchaseMatches(campaignContract, token, minPurchase, maxPurchase, addresses);
        
        // Populate arrays
        matchingAddresses = new address[](matchCount);
        purchaseAmounts = new uint256[](matchCount);
        uint256 idx = 0;
        
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 amt = ICampaign(campaignContract).getUserPurchase(token, addresses[i]);
            if (_matchesRange(amt, minPurchase, maxPurchase)) {
                matchingAddresses[idx] = addresses[i];
                purchaseAmounts[idx] = amt;
                idx++;
            }
        }
    }
    
    function _countPurchaseMatches(
        address campaignContract,
        address token,
        uint256 minPurchase,
        uint256 maxPurchase,
        address[] calldata addresses
    ) internal view returns (uint256 count) {
        for (uint256 i = 0; i < addresses.length; i++) {
            uint256 amt = ICampaign(campaignContract).getUserPurchase(token, addresses[i]);
            if (_matchesRange(amt, minPurchase, maxPurchase)) {
                count++;
            }
        }
    }
    
    /**
     * @notice Get snapshot addresses
     */
    function getSnapshotAddresses(uint256 snapshotId) external view returns (address[] memory) {
        return snapshotAddresses[snapshotId];
    }
    
    /**
     * @notice Get snapshot address count
     */
    function getSnapshotAddressCount(uint256 snapshotId) external view returns (uint256) {
        return snapshotAddresses[snapshotId].length;
    }
    
    /**
     * @notice Verify if address was in snapshot
     */
    function isInSnapshot(uint256 snapshotId, address account) external view returns (bool) {
        address[] storage addrs = snapshotAddresses[snapshotId];
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == account) return true;
        }
        return false;
    }
    
    /**
     * @notice Get the correct campaign contract for a token (single-round or multi-round)
     * @param token Campaign token address
     * @return campaignContract Address of the campaign contract that tracks this token's purchases
     */
    function _getCampaignContractForToken(address token) internal view returns (address campaignContract) {
        if (registry.isMultiRoundCampaign(token)) {
            campaignContract = registry.multiRoundCampaign();
        } else {
            campaignContract = registry.campaign();
        }
    }

    /**
     * @notice Internal helper to check if value is in range
     */
    function _matchesRange(uint256 value, uint256 min, uint256 max) internal pure returns (bool) {
        if (value < min) return false;
        if (max > 0 && value > max) return false;
        return true;
    }
}
