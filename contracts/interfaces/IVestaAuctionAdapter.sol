// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Boundary to an external CCA outcome. The local implementation is a demo-only mock.
interface IVestaAuctionAdapter {
    function isAuctionComplete(address auction) external view returns (bool);
    function claimableAllocation(address auction, address bidder) external view returns (uint256);
    function clearingPrice(address auction) external view returns (uint256);
}
