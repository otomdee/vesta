// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IVestaAuctionAdapter } from "../interfaces/IVestaAuctionAdapter.sol";
import { IContinuousClearingAuction } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import { IBidStorage } from "continuous-clearing-auction/src/interfaces/IBidStorage.sol";
import { Bid } from "continuous-clearing-auction/src/libraries/BidLib.sol";

/// @notice Sepolia adapter that reads real CCA outcomes from a live
///         ContinuousClearingAuction instance deployed via the Uniswap
///         ContinuousClearingAuctionFactory v2.1.0 on Sepolia.
///
/// Sepolia deployment addresses (immutable, no config required):
///   ContinuousClearingAuctionFactory v2.1.0 : 0x000000001F26a0044BaA66024e7b6599c61963F8
///   CCALens v2.0.0                           : 0xc3C65F5453A3674aDb693cbdA3C842545cD30f53
///
/// Interface mapping (IVestaAuctionAdapter → IContinuousClearingAuction):
///   isAuctionComplete  → isGraduated()
///   claimableAllocation → sum of Bid.tokensFilled for all bids owned by bidder
///   clearingPrice      → clearingPrice() [Q96 token-per-ETH; see note below]
///
/// @dev clearingPrice() is returned in Q96 format (price = tokenAmount * 2^96 / currencyAmount).
///      The vault's liquidityAdapter (SepoliaLiquidityAdapter) converts this to sqrtPriceX96
///      before calling the Uniswap v4 PoolManager.
contract SepoliaCcaAdapter is IVestaAuctionAdapter {
    /// @notice Thrown when the bid iteration loop exceeds the safety cap.
    error TooManyBids();

    /// @notice Maximum number of bids to iterate when scanning for a bidder's allocation.
    ///         This prevents unbounded gas on a heavily used auction; 500 bids is ample for testnet.
    uint256 public constant MAX_BID_SCAN = 500;

    // -------------------------------------------------------------------------
    // IVestaAuctionAdapter
    // -------------------------------------------------------------------------

    /// @inheritdoc IVestaAuctionAdapter
    /// @dev The CCA is considered "complete" once it has graduated (raised ≥ requiredCurrencyRaised).
    ///      Callers should ensure checkpoint() was called on the auction beforehand so that
    ///      isGraduated() reflects the most up-to-date state.
    function isAuctionComplete(address auction) external view returns (bool) {
        return IContinuousClearingAuction(auction).isGraduated();
    }

    /// @inheritdoc IVestaAuctionAdapter
    /// @dev Iterates all bids up to nextBidId() and sums tokensFilled for the given bidder.
    ///      This is O(n) in the number of bids submitted to the auction.  It is acceptable for
    ///      testnet / demo use; for production a subgraph or off-chain index should be used.
    function claimableAllocation(address auction, address bidder) external view returns (uint256 total) {
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        uint256 nextId = cca.nextBidId();
        if (nextId > MAX_BID_SCAN + 1) revert TooManyBids();
        // bid IDs are 1-indexed; nextBidId() is the next id to be assigned
        for (uint256 id = 1; id < nextId; ++id) {
            Bid memory bid = cca.bids(id);
            if (bid.owner == bidder) {
                total += bid.tokensFilled;
            }
        }
    }

    /// @inheritdoc IVestaAuctionAdapter
    /// @dev Returns the most recent on-chain clearing price in Q96 format
    ///      (token / ETH expressed as a Q96 fixed-point number, i.e. price * 2^96).
    ///      Callers should ensure checkpoint() was called on the auction first so that
    ///      clearingPrice() reflects the final post-auction price.
    function clearingPrice(address auction) external view returns (uint256) {
        return IContinuousClearingAuction(auction).clearingPrice();
    }
}
