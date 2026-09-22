// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "./UnifiedVault.sol";

/**
 * @title VaultFactory
 * @notice Factory contract for deploying UnifiedVault instances
 * @dev Simplified direct deployment since UnifiedVault is only ~19KB (well under 24KB limit)
 */
contract VaultFactory {
    
    address public owner;
    address public lendingManager;
    
    event VaultDeployed(address indexed token, address indexed vault);
    
    error NotOwner();
    error NotLendingManager();
    error AlreadySet();
    error InvalidAddress();
    error DeploymentFailed();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    
    constructor(address _owner) {
        owner = _owner;
    }
    
    function setLendingManager(address _lendingManager) external onlyOwner {
        if (lendingManager != address(0)) revert AlreadySet();
        if (_lendingManager == address(0)) revert InvalidAddress();
        lendingManager = _lendingManager;
    }
    
    /**
     * @notice Deploy a new UnifiedVault instance
     * @dev Direct deployment using 'new' - no bytecode chunking needed
     * @dev UnifiedVault gets USDC address from Registry internally
     */
    function deployVault(
        address vaultOwner,
        address token,
        string memory name,
        string memory symbol,
        address registry
    ) external returns (address vault) {
        if (msg.sender != lendingManager) revert NotLendingManager();
        
        // Direct deployment - UnifiedVault is only ~19KB
        // UnifiedVault will retrieve USDC from Registry internally
        UnifiedVault newVault = new UnifiedVault(
            vaultOwner,
            token,
            name,
            symbol,
            registry
        );
        
        vault = address(newVault);
        
        if (vault == address(0)) revert DeploymentFailed();
        
        emit VaultDeployed(token, vault);
    }
}
