// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/TestUSDR.sol";

/**
 * @title DeployTestUSDR
 * @notice Deploy Test USDR token only (one-time deployment, testnet only)
 * @dev Mainnet deployments use real USDG instead.
 */
contract DeployTestUSDR is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Test USDR with deployer as owner
        TestUSDR usdr = new TestUSDR(deployer);
        console.log("Test USDG deployed at:", address(usdr));
        console.log("Initial USDG minted to:", deployer);
        console.log("USDG Balance:", usdr.balanceOf(deployer));

        vm.stopBroadcast();

        console.log("\n=== Add to .env ===");
        console.log("TEST_USDR_ADDRESS=", address(usdr));
    }
}
