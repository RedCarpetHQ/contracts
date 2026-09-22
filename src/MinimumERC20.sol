// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

/**
 * @title MinimumERC20
 * @notice ERC20 token with role-based minting for campaign tokens
 * @dev Uses OpenZeppelin's standard contracts with AccessControl
 * 
 * KEY FEATURES:
 * - No fixed max supply initially
 * - Only MINTER_ROLE (Campaign contract) can mint tokens
 * - Supply can be locked by revoking MINTER_ROLE
 * - Uses 6 decimals (matching USDC/USDT) for 1:1 ratio with payment tokens
 * - Standard OpenZeppelin implementation for maximum security
 * - Supports burning for refunds
 * - ERC20Snapshot for dividend distribution (prevents double-claims)
 * 
 * ROLES:
 * - DEFAULT_ADMIN_ROLE: Campaign contract (can grant/revoke roles, lock supply, renounce ownership)
 * - MINTER_ROLE: Campaign contract (can mint tokens on purchases)
 * - SNAPSHOT_ROLE: DividendDistributor contract (can create snapshots for dividend rounds)
 * 
 * NOTE: We override name(), symbol(), and decimals() because OpenZeppelin's ERC20
 * sets them in the constructor, which doesn't work with clones.
 */
contract MinimumERC20 is ERC20, ERC20Snapshot, ERC20Burnable, AccessControlEnumerable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    
    bool private initialized;
    
    // Storage for name and symbol (overrides parent's immutable storage)
    string private _tokenName;
    string private _tokenSymbol;

    constructor() ERC20("", "") {
        // Empty constructor for proxy pattern
        // Disable initialization on implementation contract
        initialized = true;
    }

    /**
     * @notice Initialize the token (called once after cloning)
     * @dev Sets up roles: Campaign contract as both admin and minter
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _campaign Campaign contract (gets DEFAULT_ADMIN_ROLE and MINTER_ROLE)
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _campaign
    ) external {
        require(!initialized, "Already initialized");
        require(_campaign != address(0), "Invalid campaign");
        // FIX (L-13): Validate name and symbol are not empty
        require(bytes(_name).length > 0, "Empty name");
        require(bytes(_symbol).length > 0, "Empty symbol");
        
        initialized = true;
        
        // Set name and symbol in our storage
        _tokenName = _name;
        _tokenSymbol = _symbol;
        
        // Grant roles to Campaign contract only
        _grantRole(DEFAULT_ADMIN_ROLE, _campaign);
        _grantRole(MINTER_ROLE, _campaign);
    }
    
    /**
     * @notice Returns the name of the token
     * @dev Overrides ERC20.name() to return our storage variable
     */
    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }
    
    /**
     * @notice Returns the symbol of the token
     * @dev Overrides ERC20.symbol() to return our storage variable
     */
    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }
    
    /**
     * @notice Returns the number of decimals
     * @dev Overrides ERC20.decimals() to return 6 (matching USDC/USDT)
     */
    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }
    
    /**
     * @notice Mint tokens (only callable by MINTER_ROLE - Campaign contract)
     * @dev Used when users purchase tokens during campaign
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
    
    /**
     * @notice Lock supply by revoking all minter roles
     * @dev Can only be called by admin (Campaign contract)
     */
    function lockSupply() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 minterCount = getRoleMemberCount(MINTER_ROLE);
        
        // Revoke MINTER_ROLE from all members
        // Iterate backwards to avoid index shifting issues
        for (uint256 i = minterCount; i > 0; i--) {
            address minter = getRoleMember(MINTER_ROLE, i - 1);
            _revokeRole(MINTER_ROLE, minter);
        }
    }
    
    /**
     * @notice Renounce all ownership and control of the token
     * @dev Can only be called by admin (Campaign contract) when campaign closes
     * @dev Revokes all admin roles, making the token fully decentralized
     */
    function renounceOwnership() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 adminCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        
        // Revoke DEFAULT_ADMIN_ROLE from all members
        // Iterate backwards to avoid index shifting issues
        for (uint256 i = adminCount; i > 0; i--) {
            address admin = getRoleMember(DEFAULT_ADMIN_ROLE, i - 1);
            _revokeRole(DEFAULT_ADMIN_ROLE, admin);
        }
    }
    
    /**
     * @notice Check if supply is locked
     * @return True if no minters exist
     */
    function isSupplyLocked() external view returns (bool) {
        return getRoleMemberCount(MINTER_ROLE) == 0;
    }
    
    /**
     * @notice Create a snapshot of token balances
     * @dev Only callable by SNAPSHOT_ROLE (DividendDistributor)
     * @dev Used for dividend distribution to prevent double-claims
     * @return The snapshot ID
     */
    function snapshot() external onlyRole(SNAPSHOT_ROLE) returns (uint256) {
        return _snapshot();
    }
    
    /**
     * @notice Get the current snapshot ID
     * @return The current snapshot ID
     */
    function getCurrentSnapshotId() external view returns (uint256) {
        return _getCurrentSnapshotId();
    }
    
    /**
     * @notice Override required by Solidity for multiple inheritance
     * @dev Calls parent implementations in correct order
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);
    }
    
    // NOTE: burn() and burnFrom() inherited from ERC20Burnable
    // NOTE: balanceOfAt() and totalSupplyAt() inherited from ERC20Snapshot
}
