// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../src/Registry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title RegistryTestHelper
 * @notice Helper library for deploying upgradeable Registry in tests
 */
library RegistryTestHelper {
    /**
     * @notice Deploy Registry with proxy for testing
     * @param owner Owner address for the Registry
     * @return registry Deployed and initialized Registry instance
     */
    function deployRegistry(address owner) internal returns (Registry) {
        Registry implementation = new Registry();
        bytes memory initData = abi.encodeWithSelector(
            Registry.initialize.selector,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return Registry(address(proxy));
    }
}
