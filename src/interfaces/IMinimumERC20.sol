// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IMinimumERC20
 * @notice Interface for MinimumERC20 token with snapshot and burn capabilities
 */
interface IMinimumERC20 is IERC20 {
    /// @notice Create a snapshot of token balances
    function snapshot() external returns (uint256);
    
    /// @notice Get the current snapshot ID
    function getCurrentSnapshotId() external view returns (uint256);
    
    /// @notice Get balance at a specific snapshot
    function balanceOfAt(address account, uint256 snapshotId) external view returns (uint256);
    
    /// @notice Get total supply at a specific snapshot
    function totalSupplyAt(uint256 snapshotId) external view returns (uint256);
    
    /// @notice Burn tokens from caller
    function burn(uint256 amount) external;
    
    /// @notice Burn tokens from account (requires approval)
    function burnFrom(address account, uint256 amount) external;
    
    /// @notice Check if supply is locked
    function isSupplyLocked() external view returns (bool);
    
    /// @notice Grant a role to an account
    function grantRole(bytes32 role, address account) external;
    
    /// @notice Revoke a role from an account
    function revokeRole(bytes32 role, address account) external;
    
    /// @notice Get SNAPSHOT_ROLE constant
    function SNAPSHOT_ROLE() external view returns (bytes32);
}
