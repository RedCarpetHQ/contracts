// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library CampaignFeeLib {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_UI_FEE_FACTOR = 50; // Max 0.5%

    function calculateUiFee(uint256 amount, uint256 factor) internal pure returns (uint256) {
        if (factor == 0) return 0;
        return (amount * factor) / FEE_DENOMINATOR;
    }

    function collectUiFee(
        address paymentToken,
        address buyer,
        address uiFeeReceiver,
        uint256 factor,
        uint256 amount
    ) internal returns (uint256 uiFee) {
        if (uiFeeReceiver == address(0) || factor == 0) return 0;
        uiFee = calculateUiFee(amount, factor);
        if (uiFee > 0) {
            IERC20(paymentToken).safeTransferFrom(buyer, uiFeeReceiver, uiFee);
        }
    }
}
