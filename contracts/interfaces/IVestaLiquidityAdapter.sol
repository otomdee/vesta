// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Boundary to v4 pool initialization and a single configured LP range.
interface IVestaLiquidityAdapter {
    function initializePool(address token, uint256 clearingPrice) external;
    function addLiquidity(address token, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 shares);
    function removeLiquidity(address recipient, uint256 shares)
        external
        returns (uint256 tokenAmount, uint256 ethAmount);
}
