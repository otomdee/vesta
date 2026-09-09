// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVestaLiquidityAdapter } from "../interfaces/IVestaLiquidityAdapter.sol";

/// @notice DEMO ONLY: records v4-shaped migration inputs and redeems proportional mock shares.
contract MockLiquidityAdapter is IVestaLiquidityAdapter {
    using SafeERC20 for IERC20;

    address public token;
    uint256 public clearingPrice;
    uint256 public totalToken;
    uint256 public totalEth;
    uint256 public totalShares;
    bool public initialized;

    error AlreadyInitialized();
    error NotInitialized();
    error InvalidValue();

    function initializePool(address token_, uint256 clearingPrice_) external {
        if (initialized) revert AlreadyInitialized();
        token = token_;
        clearingPrice = clearingPrice_;
        initialized = true;
    }

    function addLiquidity(address token_, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 shares)
    {
        if (!initialized) revert NotInitialized();
        if (token_ != token || msg.value != ethAmount || ethAmount == 0) revert InvalidValue();
        totalToken += tokenAmount;
        totalEth += ethAmount;
        shares = ethAmount;
        totalShares += shares;
    }

    function removeLiquidity(address recipient, uint256 shares)
        external
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        if (shares == 0 || shares > totalShares) revert InvalidValue();
        tokenAmount = totalToken * shares / totalShares;
        ethAmount = totalEth * shares / totalShares;
        totalToken -= tokenAmount;
        totalEth -= ethAmount;
        totalShares -= shares;
        IERC20(token).safeTransfer(recipient, tokenAmount);
        (bool sent,) = recipient.call{ value: ethAmount }("");
        if (!sent) revert InvalidValue();
    }

    receive() external payable { }
}
