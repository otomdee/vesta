// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Boundary to an external CCA outcome.
///
/// Implementations:
///   - MockCcaAdapter      : local/Anvil demo only; stores deterministic outcomes in memory.
///   - SepoliaCcaAdapter   : reads a live ContinuousClearingAuction on Ethereum Sepolia
///                           (factory v2.1.0 at 0x000000001F26a0044BaA66024e7b6599c61963F8).
///
/// @dev clearingPrice() returns a Q96 fixed-point value (currency/token * 2^96,
///      i.e. ETH per token) as emitted by the CCA. The liquidity adapter is
///      responsible for converting Q96 to sqrtPriceX96 (with inversion, since
///      ETH is currency0) before calling Uniswap v4 PoolManager.
interface IVestaAuctionAdapter {
    /// @notice Returns true when the auction has finished and met its funding threshold.
    /// @dev On Sepolia maps to IContinuousClearingAuction.isGraduated().
    function isAuctionComplete(address auction) external view returns (bool);

    /// @notice Returns the total tokens filled for `bidder` in this auction.
    /// @dev On Sepolia sums Bid.tokensFilled across all bids owned by bidder.
    function claimableAllocation(address auction, address bidder) external view returns (uint256);

    /// @notice Returns the final clearing price in Q96 format (currency/token * 2^96).
    /// @dev On Sepolia maps to IContinuousClearingAuction.clearingPrice().
    ///      Call checkpoint() on the auction before reading to ensure up-to-date data.
    function clearingPrice(address auction) external view returns (uint256);
}
