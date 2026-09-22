
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";

contract SigTest is Test {
    function testSigs() public {
        console.log("recordTrade(address,uint256,uint256):");
        console.logBytes4(bytes4(keccak256("recordTrade(address,uint256,uint256)")));
        
        console.log("recordTrade(address,address,address,uint256):");
        console.logBytes4(bytes4(keccak256("recordTrade(address,address,address,uint256)")));
        
        console.log("recordTrade(uint256,address,address,address,uint256,uint256,uint256):");
        console.logBytes4(bytes4(keccak256("recordTrade(uint256,address,address,address,uint256,uint256,uint256)")));

        console.log("deposit(uint256,address):");
        console.logBytes4(bytes4(keccak256("deposit(uint256,address)")));

        console.log("distributeFees(address,uint256):");
        console.logBytes4(bytes4(keccak256("distributeFees(address,uint256)")));

        console.log("onFill(address,address,address,uint256,uint256,uint16):");
        console.logBytes4(bytes4(keccak256("onFill(address,address,address,uint256,uint256,uint16)")));

        console.log("addBuyVolume(address,address,uint128):");
        console.logBytes4(bytes4(keccak256("addBuyVolume(address,address,uint128)")));

        address market = 0x2A6Ea7Bd8dBF0F8f18572CD8541531E9BfACaE2c;
        uint256 slot = 4;
        bytes32 marketSlot = keccak256(abi.encode(market, slot));
        console.log("authorizedUpdaters[Market] slot:");
        console.logBytes32(marketSlot);
    }
}
