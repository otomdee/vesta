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
///   isAuctionComplete  → isGraduated() && block.number >= endBlock()
///   claimableAllocation → sum of Bid.tokensFilled for all bids owned by bidder
///   clearingPrice      → clearingPrice() [Q96 currency-per-token; see note below]
///
/// @dev clearingPrice() is returned in Q96 format (price = currencyAmount * 2^96 / tokenAmount,
///      i.e. ETH per token — same convention as LBPStrategy.initialPriceX96).
///      The vault's liquidityAdapter (SepoliaLiquidityAdapter) converts this to sqrtPriceX96
///      via Uniswap's TokenPricing library (with inversion, since ETH is currency0)
///      before calling the Uniswap v4 PoolManager.
///
/// @dev Bid IDs are 0-indexed: the first bid is id 0 and nextBidId() is empty-count.
/// @dev Bid.tokensFilled is only populated after exitBid/exitPartiallyFilledBid.
///      Callers must exit a bidder's winning bids before claimableAllocation reflects them.
/// @dev clearingPrice()/isGraduated() are only as fresh as the last checkpoint().
///      The team must call pokeCheckpoint(auction) (anyone can call CCA.checkpoint())
///      after endBlock and before finalize/migrate so reads reflect the final price.
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
    /// @dev The CCA is complete once it has graduated (raised ≥ requiredCurrencyRaised)
    ///      AND the end block has passed. isGraduated() alone can be true mid-auction,
    ///      so both conditions are required. Call pokeCheckpoint() first so that
    ///      isGraduated() reflects the latest state.
    function isAuctionComplete(address auction) external view returns (bool) {
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        if (!cca.isGraduated()) return false;
        return block.number >= cca.endBlock();
    }

    /// @notice Permissionlessly advances the CCA checkpoint so reads are fresh.
    /// @dev Anyone can call CCA.checkpoint(); the team should call this after
    ///      endBlock and before finalizeCovenants/migrate.
    function pokeCheckpoint(address auction) external returns (uint256 clearingPriceQ96) {
        IContinuousClearingAuction(auction).checkpoint();
        clearingPriceQ96 = IContinuousClearingAuction(auction).clearingPrice();
    }

    /// @inheritdoc IVestaAuctionAdapter
    /// @dev Iterates all bids 0..<nextBidId() and sums tokensFilled for the bidder.
    ///      This is O(n) in the number of bids. Acceptable for testnet/demo;
    ///      production should use an off-chain index of BidSubmitted/BidExited events.
    ///      NOTE: only already-exited bids have tokensFilled set; un-exited
    ///      winning bids read as 0 until exitBid/exitPartiallyFilledBid is called.
    function claimableAllocation(address auction, address bidder)
        external
        view
        returns (uint256 total)
    {
        IContinuousClearingAuction cca = IContinuousClearingAuction(auction);
        uint256 nextId = cca.nextBidId();
        if (nextId > MAX_BID_SCAN) revert TooManyBids();
        // bid IDs are 0-indexed; nextBidId() equals the bid count
        for (uint256 id = 0; id < nextId; ++id) {
            Bid memory bid = cca.bids(id);
            if (bid.owner == bidder) {
                total += bid.tokensFilled;
            }
        }
    }

    /// @inheritdoc IVestaAuctionAdapter
    /// @dev Returns the most recent on-chain clearing price in Q96 format
    ///      (ETH per token as a Q96 fixed-point number, i.e. price * 2^96).
    ///      Callers should ensure checkpoint() was called on the auction first so that
    ///      clearingPrice() reflects the final post-auction price.
    function clearingPrice(address auction) external view returns (uint256) {
        return IContinuousClearingAuction(auction).clearingPrice();
    }
}
