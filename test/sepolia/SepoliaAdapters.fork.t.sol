// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { MockLaunchToken } from "../../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../../contracts/VestaStrategy.sol";
import { VestaCovenantVault } from "../../contracts/VestaCovenantVault.sol";
import { SepoliaCcaAdapter } from "../../contracts/adapters/SepoliaCcaAdapter.sol";
import { SepoliaLiquidityAdapter } from "../../contracts/adapters/SepoliaLiquidityAdapter.sol";
import { AuctionParameters } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import { IContinuousClearingAuction } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { TokenPricing } from "liquidity-launcher/src/libraries/TokenPricing.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Minimal factory surface used to create a real CCA on the Sepolia fork.
interface ICCAFactory {
    function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address);
}

/// @notice Permit2 getter (lives on Permit2Forwarder, not IPositionManager).
interface IPMPermit2 {
    function permit2() external view returns (address);
}

/// @notice Sepolia fork tests proving the Sepolia adapters work against the REAL
///         Uniswap CCA + v4 contracts (not mocks) and that the vault's per-user
///         NFT model has no double-burn.
///
/// Run:
///   SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
///     forge test --match-path test/sepolia/* -vvv
///
/// No live broadcast is performed; everything runs on a local fork.
/// Live Sepolia runs remain manual.
contract SepoliaAdaptersForkTest is Test {
    address internal constant CCA_FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;
    address internal constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

    // Currency-per-token Q96 prices (ETH per token — CCA convention).
    // FLOOR = 2^86 ≈ 0.00098 ETH/token (≈1024 tokens per ETH).
    // Spacing is an exact divisor so floor+spacing is a valid bid tick.
    uint256 internal constant FLOOR_PRICE = 1 << 86;
    uint256 internal constant TICK_SPACING = 1 << 80;
    uint256 internal constant MAX_PRICE = (1 << 86) + (1 << 80); // one tick above floor
    uint128 internal constant SALE_SUPPLY = 1_000_000 ether;
    uint64 internal constant DURATION = 100;

    address internal team = makeAddr("team");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockLaunchToken internal token;
    IContinuousClearingAuction internal auction;
    SepoliaCcaAdapter internal ccaAdapter;
    SepoliaLiquidityAdapter internal liquidityAdapter;
    VestaStrategy internal strategy;
    VestaCovenantVault internal vault;

    uint64 internal startBlock;
    uint64 internal endBlock;
    uint64 internal claimBlock;

    function setUp() public {
        string memory rpc = vm.envOr(
            "SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")
        );
        vm.createSelectFork(rpc);

        vm.deal(team, 20 ether);
        vm.deal(alice, 20 ether);
        vm.deal(bob, 20 ether);

        token = new MockLaunchToken();

        startBlock = uint64(block.number);
        endBlock = startBlock + DURATION;
        claimBlock = endBlock + 10;

        // 1% MPS x 50 blocks + 1% MPS x 50 blocks = 100% over 100 blocks.
        bytes memory steps =
            abi.encodePacked(uint24(100_000), uint40(50), uint24(100_000), uint40(50));

        AuctionParameters memory params = AuctionParameters({
            currency: address(0),
            tokensRecipient: team,
            fundsRecipient: team,
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: claimBlock,
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 1,
            auctionStepsData: steps
        });

        address auctionAddr = ICCAFactory(CCA_FACTORY).create(
            address(token), SALE_SUPPLY, abi.encode(params), keccak256("vesta-sepolia-fork")
        );
        auction = IContinuousClearingAuction(auctionAddr);

        // Fund the sale and open it.
        token.mint(auctionAddr, SALE_SUPPLY);
        auction.onTokensReceived();

        ccaAdapter = new SepoliaCcaAdapter();
        liquidityAdapter = new SepoliaLiquidityAdapter();

        vm.prank(team);
        strategy = new VestaStrategy(
            auctionAddr,
            IMintableLaunchToken(address(token)),
            ccaAdapter,
            liquidityAdapter,
            7 days,
            1_000
        );
        vault = strategy.vault();
        vm.prank(team);
        strategy.openEnrollment();
    }

    // -------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------

    function testFork_CanonicalAddressesAreLive() public view {
        assertGt(CCA_FACTORY.code.length, 0, "CCA factory missing");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager missing");
        address permit2 = IPMPermit2(POSITION_MANAGER).permit2();
        assertGt(permit2.code.length, 0, "Permit2 missing");
    }

    // -------------------------------------------------------------------------
    // CCA adapter vs real auction
    // -------------------------------------------------------------------------

    function _submitBids() internal returns (uint256 aliceBid, uint256 bobBid) {
        vm.prank(alice);
        aliceBid = auction.submitBid{ value: 1 ether }(MAX_PRICE, 1 ether, alice, FLOOR_PRICE, bytes(""));
        vm.prank(bob);
        bobBid = auction.submitBid{ value: 3 ether }(MAX_PRICE, 3 ether, bob, FLOOR_PRICE, bytes(""));
    }

    function testFork_CompletionRequiresEndBlock() public {
        // Bid IDs are 0-indexed: first bid must be id 0.
        (uint256 aliceBid,) = _submitBids();
        assertEq(aliceBid, 0, "first bid id must be 0");

        // Graduation is checkpoint-driven, and checkpoints cover state up to
        // (NOT including) the current block — so advance one block, then poke.
        // 4 ETH raised >> 1 wei required, so the auction graduates mid-auction —
        // but endBlock is still in the future, so the adapter must report incomplete.
        vm.roll(block.number + 1);
        ccaAdapter.pokeCheckpoint(address(auction));
        assertTrue(auction.isGraduated(), "expected graduation mid-auction");
        assertFalse(ccaAdapter.isAuctionComplete(address(auction)), "must wait for endBlock");
    }

    function testFork_AdapterReadsRealOutcomeIncludingBidZero() public {
        _submitBids();

        // Single-bid regression: with only bid 0 existing, allocation must be > 0.
        vm.roll(endBlock + 1);
        ccaAdapter.pokeCheckpoint(address(auction));
        assertTrue(ccaAdapter.isAuctionComplete(address(auction)));

        auction.exitBid(0);
        auction.exitBid(1);

        uint256 aliceAlloc = ccaAdapter.claimableAllocation(address(auction), alice);
        uint256 bobAlloc = ccaAdapter.claimableAllocation(address(auction), bob);
        assertGt(aliceAlloc, 0, "bid 0 must be counted");
        assertGt(bobAlloc, aliceAlloc, "3 ETH bid must fill more than 1 ETH bid");

        uint256 price = ccaAdapter.clearingPrice(address(auction));
        assertGe(price, FLOOR_PRICE, "clearing price below floor");
    }

    // -------------------------------------------------------------------------
    // Liquidity adapter vs real PositionManager
    // -------------------------------------------------------------------------

    function testFork_LiquidityAdapterMintsRealNft() public {
        uint256 nextBefore = IPositionManager(POSITION_MANAGER).nextTokenId();

        liquidityAdapter.initializePool(address(token), FLOOR_PRICE);

        // Pool must open at the INVERTED price: v4 price is token/ETH while
        // the CCA price is ETH/token. Pin the canonical TokenPricing result.
        uint160 expectedSqrt = TokenPricing.convertToSqrtPriceX96(
            TokenPricing.convertToPriceX192(FLOOR_PRICE, true)
        );
        assertEq(liquidityAdapter.sqrtPriceX96Stored(), expectedSqrt, "price must be inverted");

        token.mint(address(liquidityAdapter), 1000 ether);
        uint256 tokenId = liquidityAdapter.addLiquidity{ value: 1 ether }(
            address(token), 1000 ether, 1 ether
        );

        assertEq(tokenId, nextBefore, "must return freshly minted token id");
        assertEq(
            IERC721(POSITION_MANAGER).ownerOf(tokenId),
            address(liquidityAdapter),
            "adapter must own the NFT"
        );

        uint256 ethBefore = address(this).balance;
        (uint256 tokensOut, uint256 ethOut) =
            liquidityAdapter.removeLiquidity(address(this), tokenId);
        assertGt(tokensOut, 0);
        assertGt(ethOut, 0);
        assertEq(address(this).balance, ethBefore + ethOut);
    }

    // -------------------------------------------------------------------------
    // End-to-end: vault + real adapters, per-user NFTs, no double-burn
    // -------------------------------------------------------------------------

    function testFork_E2E_PerUserNftsAndUnlock() public {
        // Enroll in the vault (LP escrow, separate from CCA bids).
        vm.prank(alice);
        vault.enrollCovenant{ value: 1 ether }(4_000);
        vm.prank(bob);
        vault.enrollCovenant{ value: 3 ether }(5_000);

        // Bid in the real CCA.
        _submitBids();

        // Finish the auction. tokensFilled is only populated at exit, so bids
        // must be exited BEFORE finalizeCovenants reads allocations.
        vm.roll(endBlock + 1);
        ccaAdapter.pokeCheckpoint(address(auction));
        assertTrue(ccaAdapter.isAuctionComplete(address(auction)));

        auction.exitBid(0);
        auction.exitBid(1);

        vm.prank(team);
        strategy.finalizeCovenants();

        uint256 aliceAlloc = ccaAdapter.claimableAllocation(address(auction), alice);
        uint256 bobAlloc = ccaAdapter.claimableAllocation(address(auction), bob);
        assertGt(aliceAlloc, 0, "alice allocation must be set");
        uint256 committed = aliceAlloc * 4_000 / 10_000;
        assertEq(
            vault.totalCommittedTokens(), committed + bobAlloc * 5_000 / 10_000
        );

        vm.prank(team);
        strategy.migrate();

        VestaCovenantVault.Position memory alicePos = vault.positionOf(alice);
        VestaCovenantVault.Position memory bobPos = vault.positionOf(bob);

        // Distinct real NFTs, escrow-weighted reward shares.
        assertGt(alicePos.tokenId, 0);
        assertGt(bobPos.tokenId, 0);
        assertTrue(alicePos.tokenId != bobPos.tokenId, "each user needs their own NFT");
        assertEq(alicePos.shares, 1 ether);
        assertEq(bobPos.shares, 3 ether);
        assertEq(alicePos.tokenAmount, committed);

        // Rewards stay pro-rata by escrow.
        vm.prank(team);
        vault.fundRewards{ value: 4 ether }();
        assertEq(vault.pendingRewards(alice), 1 ether);
        assertEq(vault.pendingRewards(bob), 3 ether);
        vm.prank(alice);
        vault.claimRewards();

        // Past the lock both users withdraw their OWN position: the second
        // withdraw must not revert (double-burn regression).
        vm.warp(block.timestamp + 7 days + 1);
        uint256 aliceEth = alice.balance;
        vm.prank(alice);
        vault.withdrawAfterUnlock();
        assertGt(alice.balance, aliceEth, "alice must receive ETH");

        uint256 bobEth = bob.balance;
        vm.prank(bob);
        vault.withdrawAfterUnlock();
        assertGt(bob.balance, bobEth, "bob must receive ETH (no double-burn)");
        assertGt(token.balanceOf(bob), 0, "bob must receive tokens");

        // Liquid allocation path still works alongside Vesta: after claimBlock
        // both bidders can claim their real auction tokens.
        vm.roll(claimBlock + 1);
        auction.claimTokens(0);
        auction.claimTokens(1);
        assertGt(token.balanceOf(alice), 0, "alice liquid allocation");
    }

    receive() external payable { }
}
