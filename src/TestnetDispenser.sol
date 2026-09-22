// SPDX-License-Identifier: BUSL-1.1
//
// Copyright (c) RedCarpetHQ. All Rights Reserved. This codebase is submitted
// solely for evaluation in the Arbitrum Open House Singapore competition.
// No permission or license is granted to copy, deploy, modify, or run this
// code for commercial or non-commercial purposes.
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestnetDispenser
 * @notice Faucet contract for distributing testnet ETH and USDR to users
 * @dev Each wallet can claim exactly once. Claims are submitted by a trusted
 *      relayer (backend service) so the end user never needs ETH for gas —
 *      they only sign an off-chain message; the relayer pays gas and calls
 *      claimFor(). Testnet only.
 */
contract TestnetDispenser is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdr;

    uint256 public claimAmount;     // USDR amount per claim (in token units)
    uint256 public ethClaimAmount;  // ETH amount per claim (in wei)
    bool public enabled;            // global on/off switch

    address public relayer;         // backend address allowed to call claimFor()

    mapping(address => bool) public hasClaimed; // user => claimed flag

    event Claimed(address indexed user, address indexed relayer, uint256 ethAmount, uint256 usdrAmount);
    event ClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event EthClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event EnabledToggled(bool enabled);
    event RelayerUpdated(address oldRelayer, address newRelayer);
    event Withdrawn(address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);

    error DispenserDisabled();
    error AlreadyClaimed();
    error NotRelayer(address caller);
    error InsufficientEthBalance(uint256 available, uint256 required);
    error InsufficientUsdrBalance(uint256 available, uint256 required);
    error ZeroAddress();

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer(msg.sender);
        _;
    }

    constructor(address _usdr, address _owner) {
        if (_usdr == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        usdr = IERC20(_usdr);
        _transferOwnership(_owner);

        // Defaults: 10,000 USDR (6 decimals), 0.001 ETH, enabled
        claimAmount = 10_000 * 10 ** 6;
        ethClaimAmount = 0.0001 ether;
        enabled = true;
    }

    /**
     * @notice Claim testnet ETH + USDR for a user. Relayer-only.
     * @dev Each wallet may claim exactly once. The relayer (backend) pays gas.
     *      The user signs off-chain; the backend verifies and submits this call.
     * @param user Wallet to receive the ETH and USDR.
     */
    function claimFor(address user) external onlyRelayer {
        if (!enabled) revert DispenserDisabled();
        if (hasClaimed[user]) revert AlreadyClaimed();

        uint256 ethAmt = ethClaimAmount;
        uint256 usdrAmt = claimAmount;

        if (address(this).balance < ethAmt) {
            revert InsufficientEthBalance(address(this).balance, ethAmt);
        }
        uint256 usdrBalance = usdr.balanceOf(address(this));
        if (usdrBalance < usdrAmt) {
            revert InsufficientUsdrBalance(usdrBalance, usdrAmt);
        }

        hasClaimed[user] = true;

        // Send ETH first (no reentrancy risk: hasClaimed already set, and the
        // only state read after is the USDR transfer which is to the same user).
        (bool ethOk, ) = payable(user).call{value: ethAmt}("");
        require(ethOk, "ETH transfer failed");

        usdr.safeTransfer(user, usdrAmt);

        emit Claimed(user, msg.sender, ethAmt, usdrAmt);
    }

    /**
     * @notice Accept ETH funding for the dispenser.
     */
    receive() external payable {}

    function setClaimAmount(uint256 _claimAmount) external onlyOwner {
        emit ClaimAmountUpdated(claimAmount, _claimAmount);
        claimAmount = _claimAmount;
    }

    function setEthClaimAmount(uint256 _ethClaimAmount) external onlyOwner {
        emit EthClaimAmountUpdated(ethClaimAmount, _ethClaimAmount);
        ethClaimAmount = _ethClaimAmount;
    }

    function setEnabled(bool _enabled) external onlyOwner {
        enabled = _enabled;
        emit EnabledToggled(_enabled);
    }

    function setRelayer(address _relayer) external onlyOwner {
        if (_relayer == address(0)) revert ZeroAddress();
        emit RelayerUpdated(relayer, _relayer);
        relayer = _relayer;
    }

    /**
     * @notice Withdraw remaining USDR (owner only, for recovery)
     */
    function withdraw(address to, uint256 amount) external onlyOwner {
        usdr.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /**
     * @notice Withdraw remaining ETH (owner only, for recovery)
     */
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH withdraw failed");
        emit EthWithdrawn(to, amount);
    }

    function dispenserBalance() external view returns (uint256) {
        return usdr.balanceOf(address(this));
    }

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function canClaim(address user) external view returns (bool) {
        if (!enabled) return false;
        if (hasClaimed[user]) return false;
        if (address(this).balance < ethClaimAmount) return false;
        return usdr.balanceOf(address(this)) >= claimAmount;
    }
}
