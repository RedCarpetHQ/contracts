// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract CampaignFeeManager is Ownable {
    mapping(address => uint256) public uiFeeFactor; // integrator => fee share bps

    uint256 public constant MAX_UI_FEE_FACTOR = 50; // Max 0.5%
    uint256 public constant FEE_DENOMINATOR = 10000;

    event UiFeeFactorUpdated(address indexed integrator, uint256 factor);
    event UiFeeCollected(address indexed token, address indexed integrator, uint256 amount);

    constructor(address _owner) {
        _transferOwnership(_owner);
    }

    function setUiFeeFactor(uint256 factor) external {
        require(factor <= MAX_UI_FEE_FACTOR, "UI fee too high");
        uiFeeFactor[msg.sender] = factor;
        emit UiFeeFactorUpdated(msg.sender, factor);
    }

    function getUiFeeFactor(address integrator) external view returns (uint256) {
        return uiFeeFactor[integrator];
    }
}
