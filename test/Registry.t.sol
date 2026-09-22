// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/Registry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RegistryTest is Test {
    Registry public registry;
    address public owner = address(1);
    address public token = address(3);
    
    function setUp() public {
        // Deploy Registry with proxy (upgradeable pattern)
        Registry implementation = new Registry();
        bytes memory initData = abi.encodeWithSelector(
            Registry.initialize.selector,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = Registry(address(proxy));
    }
    
    function test_RegisterCampaign() public {
        // First authorize the owner to register campaigns
        vm.prank(owner);
        registry.setAuthorizedContract(owner, true);
        
        vm.prank(owner);
        registry.registerCampaign(
            token,
            owner,
            address(4), // paymentToken
            1000e6,     // floor
            0,          // ceiling
            1,          // overageType
            owner,      // fundsRecipient
            block.timestamp,
            block.timestamp + 30 days
        );
        
        (address creator,,,,,,,,,,,,) = registry.campaigns(token);
        assertEq(creator, owner);
    }
    
    function test_SetProtocolAddresses() public {
        vm.startPrank(owner);
        
        address usdc = address(4);
        registry.setUsdc(usdc);
        assertEq(registry.usdc(), usdc);
        
        vm.stopPrank();
    }
    
    function test_ZeroAddressValidation() public {
        vm.prank(owner);
        vm.expectRevert("Invalid address");
        registry.setUsdc(address(0));
    }
    
    function test_OnlyOwnerCanSetAddresses() public {
        vm.prank(address(999));
        vm.expectRevert();
        registry.setUsdc(address(4));
    }
    
    function test_AuthorizeContract() public {
        vm.prank(owner);
        registry.setAuthorizedContract(address(5), true);
        assertTrue(registry.authorizedContracts(address(5)));
    }
}
