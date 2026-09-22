// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/LendingManager.sol";
import "../src/Registry.sol";
import "../src/VaultFactory.sol";
import "../src/TestUSDC.sol";
import "../src/MinimumERC20.sol";
import "../src/HybridPriceOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

contract LendingManagerTest is Test {
    using Clones for address;
    
    LendingManager public lendingManager;
    Registry public registry;
    VaultFactory public vaultFactory;
    TestUSDC public usdc;
    MinimumERC20 public tokenImpl;
    
    address public owner = address(1);
    address public campaign = address(2);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Registry with proxy (proper upgradeable pattern)
        Registry registryImpl = new Registry();
        bytes memory initData = abi.encodeWithSelector(Registry.initialize.selector, owner);
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = Registry(address(registryProxy));
        
        usdc = new TestUSDC(owner);
        registry.setUsdc(address(usdc));
        
        lendingManager = new LendingManager(owner, address(registry));
        vaultFactory = new VaultFactory(owner);  // Owner is test owner, not registry
        
        // Set up lendingManager -> vaultFactory relationship
        lendingManager.setVaultFactory(address(vaultFactory));
        vaultFactory.setLendingManager(address(lendingManager));  // Now owner can call this
        
        // Register lendingManager in registry
        registry.setLendingManager(address(lendingManager));
        
        // Deploy and set up price oracle for vault creation
        HybridPriceOracle priceOracle = new HybridPriceOracle(owner);
        registry.setHybridPriceOracle(address(priceOracle));
        
        // Authorize LendingManager in price oracle to initialize prices
        priceOracle.setAuthorizedUpdater(address(lendingManager), true);
        
        // Authorize LendingManager in registry to enable markets
        registry.setAuthorizedContract(address(lendingManager), true);
        
        // Deploy token implementation for clones
        tokenImpl = new MinimumERC20();
        
        vm.stopPrank();
    }
    
    function _registerAndEnableCampaign(MinimumERC20 token) internal {
        // Authorize campaign to register
        vm.prank(owner);
        registry.setAuthorizedContract(campaign, true);
        
        // Register campaign
        vm.prank(campaign);
        registry.registerCampaign(
            address(token),
            campaign,
            address(usdc),
            1000e6,
            0,
            1,
            campaign,
            block.timestamp,
            block.timestamp + 30 days
        );
        
        // Enable market to make campaign SUCCESS
        vm.prank(owner);
        registry.enableMarket(address(token));
    }
    
    function _deployToken() internal returns (MinimumERC20) {
        // Create token as clone of implementation (proper proxy pattern)
        address tokenClone = address(tokenImpl).clone();
        MinimumERC20 token = MinimumERC20(tokenClone);
        
        vm.startPrank(campaign);
        token.initialize("Test Token", "TEST", campaign);
        
        // Mint some tokens so totalSupply > 0 for price oracle initialization
        // Campaign has MINTER_ROLE from initialization
        token.mint(campaign, 1000e6);  // Mint 1000 tokens
        vm.stopPrank();
        
        return token;
    }
    
    function test_CreateVault_Success() public {
        MinimumERC20 token = _deployToken();
        
        // Register campaign and enable market
        _registerAndEnableCampaign(token);
        
        // Create vault (authorized caller)
        vm.prank(campaign);
        address vault = lendingManager.createVaultsOnCampaignSuccess(address(token));
        
        assertTrue(vault != address(0));
        assertEq(lendingManager.unifiedVaults(address(token)), vault);
    }
    
    function test_CreateVault_OnlyAuthorized() public {
        MinimumERC20 token = _deployToken();
        
        vm.prank(address(999));
        vm.expectRevert("Not authorized");
        lendingManager.createVaultsOnCampaignSuccess(address(token));
    }
    
    function test_CreateVault_PreventsDuplicate() public {
        MinimumERC20 token = _deployToken();
        
        // Register campaign and enable market
        _registerAndEnableCampaign(token);
        
        vm.startPrank(campaign);
        lendingManager.createVaultsOnCampaignSuccess(address(token));
        
        vm.expectRevert("Vault already exists");
        lendingManager.createVaultsOnCampaignSuccess(address(token));
        vm.stopPrank();
    }
    
    function test_DisableVault() public {
        MinimumERC20 token = _deployToken();
        
        // Register campaign and enable market
        _registerAndEnableCampaign(token);
        
        vm.prank(campaign);
        address vault = lendingManager.createVaultsOnCampaignSuccess(address(token));
        
        vm.prank(owner);
        lendingManager.disableVault(vault);
        
        assertTrue(lendingManager.vaultDisabled(vault));
    }
    
    function test_GetAllVaults() public {
        assertEq(lendingManager.getAllVaults().length, 0);
    }
}
