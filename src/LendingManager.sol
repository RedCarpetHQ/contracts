// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./Registry.sol";
import "./interfaces/ILendingInterfaces.sol";
import "./interfaces/IVaultFactory.sol";
import "./interfaces/IUnifiedVault.sol";
import "./interfaces/IRiskOracleViews.sol";

/**
 * @title LendingManager
 * @notice Simplified factory for deploying UnifiedVault per campaign token
 * @dev V3 Architecture: Single vault per token (replaces 5-contract stack)
 * 
 * V3 CHANGES:
 * - Deploys only UnifiedVault (consolidates StableVault, StabilityPool, SafetyModule, VaultLedger)
 * - Simplified infrastructure registration
 * - Removed clone pattern (ERC4626 requires constructor initialization)
 * 
 * Architecture Reference: /documentation/LENDING_V3_ARCHITECTURE.md
 */
contract LendingManager is Ownable {

    Registry public immutable registry;
    address public vaultFactory; // VaultFactory for deploying vaults

    // Mapping from campaign token to its UnifiedVault
    mapping(address => address) public unifiedVaults;  // token -> UnifiedVault
    address[] public allVaults;
    
    // Vault control
    mapping(address => bool) public vaultDisabled;
    
    // FIX (#7): Track vault creation timestamps
    mapping(address => uint256) public vaultCreationTime;  // token -> creation timestamp

    // Events
    event UnifiedVaultCreated(address indexed token, address indexed vault, uint256 timestamp);
    event VaultDisabled(address indexed vault);
    event VaultEnabled(address indexed vault);

    constructor(
        address _owner,
        address _registry
    ) {
        _transferOwnership(_owner);
        require(_registry != address(0), "Invalid registry");
        registry = Registry(_registry);
    }
    
    /**
     * @notice Set the VaultFactory address
     * @dev Must be called after deployment before creating vaults
     */
    function setVaultFactory(address _vaultFactory) external onlyOwner {
        require(_vaultFactory != address(0), "Invalid factory");
        vaultFactory = _vaultFactory;
    }

    /**
     * @notice Create UnifiedVault on campaign success
     * @dev V3: Deploys single UnifiedVault per token (replaces 5-contract stack)
     *      Also initializes HybridPriceOracle at 1 USDC with campaign mint volume
     * @param token Campaign token address
     * @return vault Address of created UnifiedVault
     */
    function createVaultsOnCampaignSuccess(address token) external returns (address vault) {
        // Only authorized contracts (Campaign) can call this
        require(registry.authorizedContracts(msg.sender), "Not authorized");
        require(unifiedVaults[token] == address(0), "Vault already exists");
        
        // SECURITY FIX: Verify token is from a registered campaign (prevents malicious tokens)
        (address creator,,,,,,,,,,,,) = registry.campaigns(token);
        require(creator != address(0), "Token not from registered campaign");
        
        // Verify token is from successful campaign (status is derived)
        require(registry.getCampaignStatus(token) == registry.STATUS_SUCCESS(), "Campaign not successful");
        
        // Deploy UnifiedVault
        vault = _deployVault(token);
        
        unifiedVaults[token] = vault;
        allVaults.push(vault);
        vaultCreationTime[token] = block.timestamp; // FIX (#7): Store creation time
        
        // Register in Registry (V3 simplified registration)
        registry.registerUnifiedVault(token, vault);
        
        // Initialize price oracle at 1 USDC with actual minted token supply
        // This prevents first trade manipulation and sets proper VWAP baseline
        // CRITICAL: Use totalSupply() instead of totalRaised for accuracy
        // (totalSupply reflects actual minted tokens, accounting for any discrepancies)
        address priceOracle = registry.hybridPriceOracle();
        require(priceOracle != address(0), "Price oracle not set");
        
        uint256 tokenSupply = IERC20(token).totalSupply();
        require(tokenSupply > 0, "Token supply is zero");
        
        // Initialize price - this MUST succeed for vault to be operational
        IPriceOracle(priceOracle).initializePrice(token, tokenSupply);
        
        emit UnifiedVaultCreated(token, vault, block.timestamp);
        
        return vault;
    }
    
    /**
     * @notice Deploy UnifiedVault for a token
     * @dev Uses VaultFactory to deploy (reduces LendingManager bytecode size)
     */
    function _deployVault(address token) internal returns (address vault) {
        require(vaultFactory != address(0), "VaultFactory not set");
        string memory tokenSymbol = _getTokenSymbol(token);
        
        vault = IVaultFactory(vaultFactory).deployVault(
            owner(),
            token,
            string(abi.encodePacked("Unified Vault V3 - ", tokenSymbol)),
            string(abi.encodePacked("uv3", tokenSymbol)),
            address(registry)
        );
    }
    
    /**
     * @notice Get token symbol for naming
     */
    function _getTokenSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "TOKEN";
        }
    }

    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get all UnifiedVaults
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
    
    /**
     * @notice Get UnifiedVault for a token
     */
    function getVault(address token) external view returns (address) {
        return unifiedVaults[token];
    }

    /**
     * @notice Check if a token is eligible for vault creation
     */
    function isEligibleForVault(address token) external view returns (bool eligible, string memory reason) {
        if (unifiedVaults[token] != address(0)) {
            return (false, "Vault already exists");
        }
        
        address priceOracle = registry.hybridPriceOracle();
        if (priceOracle == address(0)) {
            return (false, "Price oracle not set");
        }
        
        try IPriceOracle(priceOracle).getPrice(token) returns (uint256 price, bool reliable) {
            if (!reliable || price == 0) {
                return (false, "Price not reliable");
            }
        } catch {
            return (false, "Price oracle error");
        }
        
        return (true, "");
    }

    /**
     * @notice Get vault statistics
     */
    function getVaultStats(address token) external view returns (
        uint256 totalAssets,
        uint256 totalBorrowed,
        uint256 utilization,
        uint256 borrowRate,
        uint8 riskTier
    ) {
        address vault = unifiedVaults[token];
        if (vault == address(0)) {
            return (0, 0, 0, 0, 0);
        }
        
        IUnifiedVault v = IUnifiedVault(vault);
        totalAssets = v.totalAssets();
        totalBorrowed = v.totalBorrows();
        utilization = v.getUtilization();
        borrowRate = v.getBorrowRate();
        
        address riskOracle = registry.riskOracle();
        if (riskOracle != address(0)) {
            try IRiskOracleView(riskOracle).getRiskTier(token) returns (uint8 tier) {
                riskTier = tier;
            } catch {}
        }
    }

    /**
     * @notice Get user's position in UnifiedVault for a specific token
     * @param user User address
     * @param token Campaign token address
     */
    function getUserPosition(address user, address token) external view returns (
        uint256 deposited,           // USDC deposited (shares value)
        uint256 borrowed,            // USDC borrowed
        uint256 collateralValue,     // Collateral value in USDC
        uint256 healthFactor,
        bool canLiquidate
    ) {
        address vault = unifiedVaults[token];
        if (vault == address(0)) {
            return (0, 0, 0, 0, false);
        }
        
        IUnifiedVault v = IUnifiedVault(vault);
        
        // Get deposited value from shares
        uint256 shares = v.balanceOf(user);
        if (shares > 0) {
            deposited = v.convertToAssets(shares);
        }
        
        // Get borrow position using getUserPosition
        (uint256 collateral, uint256 debt, uint256 health, , ) = v.getUserPosition(user);
        borrowed = debt;
        collateralValue = collateral; // Note: this is raw collateral, not USDC value
        healthFactor = health;
        canLiquidate = healthFactor < 1e18 && borrowed > 0;
    }

    /**
     * @notice Get user's aggregated position across all tokens
     * @param user User address
     */
    function getUserAggregatedPosition(address user) external view returns (
        uint256 totalDeposited,      // Total USDC deposited
        uint256 totalBorrowed,       // Total USDC borrowed
        uint256 totalCollateral,     // Total collateral value in USDC
        uint256 lowestHealthFactor   // Lowest health factor across all positions
    ) {
        lowestHealthFactor = type(uint256).max;
        
        for (uint256 i = 0; i < allVaults.length; i++) {
            address vault = allVaults[i];
            if (vaultDisabled[vault]) continue;
            
            IUnifiedVault v = IUnifiedVault(vault);
            
            // Deposited
            uint256 shares = v.balanceOf(user);
            if (shares > 0) {
                totalDeposited += v.convertToAssets(shares);
            }
            
            // Get user position
            (uint256 collateral, uint256 debt, uint256 health, , ) = v.getUserPosition(user);
            totalBorrowed += debt;
            totalCollateral += collateral;
            
            // Health factor
            if (debt > 0 && health < lowestHealthFactor) {
                lowestHealthFactor = health;
            }
        }
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Disable a specific vault (emergency control)
     * @param vault Address of the vault to disable
     */
    function disableVault(address vault) external onlyOwner {
        require(vault != address(0), "Invalid vault");
        vaultDisabled[vault] = true;
        emit VaultDisabled(vault);
    }

    /**
     * @notice Re-enable a previously disabled vault
     * @param vault Address of the vault to enable
     */
    function enableVault(address vault) external onlyOwner {
        require(vault != address(0), "Invalid vault");
        vaultDisabled[vault] = false;
        emit VaultEnabled(vault);
    }

    /**
     * @notice Check if a vault is active (exists and not disabled)
     * @param token Campaign token address
     * @return True if vault exists and is not disabled
     */
    function isVaultActive(address token) external view returns (bool) {
        address vault = unifiedVaults[token];
        return vault != address(0) && !vaultDisabled[vault];
    }
    
    /**
     * @notice Get vault status including activation time
     * @dev V3: Vaults are immediately active upon creation (no delay)
     * @param token Campaign token address
     * @return exists Whether vault exists
     * @return active Whether vault is active (not disabled)
     * @return activationTime Timestamp when vault was created
     * @return timeRemaining Always 0 in V3 (immediate activation)
     */
    function getVaultStatus(address token) external view returns (
        bool exists,
        bool active,
        uint256 activationTime,
        uint256 timeRemaining
    ) {
        address vault = unifiedVaults[token];
        exists = vault != address(0);
        active = exists && !vaultDisabled[vault];
        // FIX (#7): Return actual creation timestamp instead of block.timestamp
        activationTime = vaultCreationTime[token];
        timeRemaining = 0; // V3: No activation delay
    }
}