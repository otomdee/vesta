// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { VestaCovenantVault } from "./VestaCovenantVault.sol";
import { IVestaAuctionAdapter } from "./interfaces/IVestaAuctionAdapter.sol";
import { IVestaLiquidityAdapter } from "./interfaces/IVestaLiquidityAdapter.sol";

interface IMintableLaunchToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Launch-team coordinator for a Vesta covenant. This local implementation uses explicit adapters.
contract VestaStrategy {
    address public immutable owner;
    address public immutable auction;
    IMintableLaunchToken public immutable launchToken;
    IVestaAuctionAdapter public immutable auctionAdapter;
    IVestaLiquidityAdapter public immutable liquidityAdapter;
    VestaCovenantVault public immutable vault;

    error OnlyOwner();

    event EnrollmentOpened(address indexed vault);
    event CovenantsFinalized(address indexed vault, uint256 committedTokens);
    event MigrationExecuted(address indexed vault, uint256 committedTokens);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        address auction_,
        IMintableLaunchToken launchToken_,
        IVestaAuctionAdapter auctionAdapter_,
        IVestaLiquidityAdapter liquidityAdapter_,
        uint64 lockDuration,
        uint16 penaltyBps
    ) {
        owner = msg.sender;
        auction = auction_;
        launchToken = launchToken_;
        auctionAdapter = auctionAdapter_;
        liquidityAdapter = liquidityAdapter_;
        vault = new VestaCovenantVault(
            address(this),
            auction_,
            launchToken_,
            auctionAdapter_,
            liquidityAdapter_,
            lockDuration,
            penaltyBps
        );
    }

    /// @notice Opens enrollment for the configured local/adapter-backed CCA launch.
    function openEnrollment() external onlyOwner {
        vault.openEnrollment();
        emit EnrollmentOpened(address(vault));
    }

    /// @notice Finalizes actual adapter-reported allocations into covenant token amounts.
    function finalizeCovenants() external onlyOwner {
        vault.finalizeCovenants();
        emit CovenantsFinalized(address(vault), vault.totalCommittedTokens());
    }

    /// @notice Mints demo tokens to the vault then performs the one-time adapter-mediated migration.
    function migrate() external onlyOwner {
        uint256 committedTokens = vault.totalCommittedTokens();
        launchToken.mint(address(vault), committedTokens);
        vault.migrate();
        emit MigrationExecuted(address(vault), committedTokens);
    }
}
