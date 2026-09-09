// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IVestaAuctionAdapter } from "../interfaces/IVestaAuctionAdapter.sol";

/// @notice DEMO ONLY: supplies a deterministic CCA result in local tests and Anvil demos.
contract MockCcaAdapter is IVestaAuctionAdapter {
    mapping(address auction => mapping(address bidder => uint256 allocation)) public allocations;
    mapping(address auction => bool complete) public completed;
    mapping(address auction => uint256 price) public prices;

    function setOutcome(address auction, uint256 price, bool complete) external {
        prices[auction] = price;
        completed[auction] = complete;
    }

    function setAllocation(address auction, address bidder, uint256 allocation) external {
        allocations[auction][bidder] = allocation;
    }

    function isAuctionComplete(address auction) external view returns (bool) {
        return completed[auction];
    }

    function claimableAllocation(address auction, address bidder) external view returns (uint256) {
        return allocations[auction][bidder];
    }

    function clearingPrice(address auction) external view returns (uint256) {
        return prices[auction];
    }
}
