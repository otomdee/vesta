// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Boundary to v4 pool initialization and a single configured LP range.
///
/// Implementations:
///   - MockLiquidityAdapter       : local/Anvil demo only; uses a simple in-memory accounting model.
///   - SepoliaLiquidityAdapter    : wires into the Uniswap v4 PositionManager on Ethereum Sepolia
///                                  (0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4).
///
/// @dev `shares` is an ERC-721 position token ID issued by the v4 PositionManager.
///      The adapter holds the NFT for the duration of the lock; the vault stores only the ID.
interface IVestaLiquidityAdapter {
    /// @notice Initialize the token/ETH pool at the given clearing price.
    /// @param token     The ERC-20 launch token address.
    /// @param clearingPrice  The CCA clearing price in Q96 format (token/ETH * 2^96).
    ///                       On Sepolia the adapter converts this to sqrtPriceX96 internally.
    function initializePool(address token, uint256 clearingPrice) external;

    /// @notice Add token + ETH liquidity and return the position identifier.
    /// @param token        The ERC-20 launch token address.
    /// @param tokenAmount  Amount of launch token to provide (must already be in the adapter).
    /// @param ethAmount    Amount of ETH to provide; must equal msg.value.
    /// @return shares      On Sepolia: the v4 ERC-721 position token ID.
    function addLiquidity(address token, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        returns (uint256 shares);

    /// @notice Redeem a position and send the underlying assets to `recipient`.
    /// @param recipient  Address to receive the unwound ETH and token amounts.
    /// @param shares     On Sepolia: the v4 ERC-721 position token ID to burn.
    /// @return tokenAmount  Amount of launch token returned.
    /// @return ethAmount    Amount of ETH returned.
    function removeLiquidity(address recipient, uint256 shares)
        external
        returns (uint256 tokenAmount, uint256 ethAmount);
}
