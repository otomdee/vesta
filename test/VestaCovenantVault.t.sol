// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { MockLaunchToken } from "../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../contracts/VestaStrategy.sol";
import { VestaCovenantVault } from "../contracts/VestaCovenantVault.sol";
import { MockCcaAdapter } from "../contracts/mocks/MockCcaAdapter.sol";
import { MockLiquidityAdapter } from "../contracts/mocks/MockLiquidityAdapter.sol";

contract VestaCovenantVaultTest is Test {
    address internal constant AUCTION = address(0xA11CE);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal team = makeAddr("team");
    MockLaunchToken internal token;
    MockCcaAdapter internal auction;
    MockLiquidityAdapter internal liquidity;
    VestaStrategy internal strategy;
    VestaCovenantVault internal vault;

    function setUp() public {
        vm.deal(alice, 20 ether);
        vm.deal(bob, 20 ether);
        vm.deal(team, 20 ether);
        token = new MockLaunchToken();
        auction = new MockCcaAdapter();
        liquidity = new MockLiquidityAdapter();
        vm.prank(team);
        strategy = new VestaStrategy(
            AUCTION, IMintableLaunchToken(address(token)), auction, liquidity, 7 days, 1_000
        );
        vault = strategy.vault();
        vm.prank(team);
        strategy.openEnrollment();
    }

    function testEnrollUpdateAndCancelConservesEscrow() public {
        vm.prank(alice);
        vault.enrollCovenant{ value: 1 ether }(4_000);

        vm.prank(alice);
        vault.updateCovenant{ value: 0.5 ether }(7_000);

        VestaCovenantVault.Commitment memory commitment = vault.commitmentOf(alice);
        assertEq(commitment.commitmentBps, 7_000);
        assertEq(commitment.escrowedEth, 1.5 ether);
        assertTrue(commitment.active);
        assertEq(vault.totalEscrowedEth(), 1.5 ether);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.cancelCovenant();
        assertEq(alice.balance, balanceBefore + 1.5 ether);
        assertEq(vault.totalEscrowedEth(), 0);
    }

    function testRejectsInvalidBpsAndZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert(VestaCovenantVault.InvalidCommitmentBps.selector);
        vault.enrollCovenant{ value: 1 ether }(10_001);
        vm.prank(alice);
        vm.expectRevert(VestaCovenantVault.ZeroEthContribution.selector);
        vault.enrollCovenant(1);
    }

    function testTwoBidderMigrationCreatesProportionalLockedPositions() public {
        _enrollAndFinalize();
        vm.prank(team);
        strategy.migrate();

        VestaCovenantVault.Position memory alicePosition = vault.positionOf(alice);
        VestaCovenantVault.Position memory bobPosition = vault.positionOf(bob);
        assertEq(alicePosition.tokenAmount, 400 ether);
        assertEq(bobPosition.tokenAmount, 750 ether);
        assertEq(alicePosition.ethAmount, 1 ether);
        assertEq(bobPosition.ethAmount, 3 ether);
        assertEq(alicePosition.shares, 1 ether);
        assertEq(bobPosition.shares, 3 ether);
        // Mock adapter returns ethAmount as the position id; one position
        // is minted per participant.
        assertEq(alicePosition.tokenId, 1 ether);
        assertEq(bobPosition.tokenId, 3 ether);
        assertEq(vault.totalCommittedTokens(), 1150 ether);
        assertEq(liquidity.totalToken(), 1150 ether);
        assertEq(liquidity.totalEth(), 4 ether);

        vm.prank(team);
        vm.expectRevert();
        strategy.migrate();
    }

    function testRewardsAndEarlyExitRetainPenalty() public {
        _enrollAndFinalize();
        vm.prank(team);
        strategy.migrate();
        vm.prank(team);
        vault.fundRewards{ value: 4 ether }();
        assertEq(vault.pendingRewards(alice), 1 ether);
        assertEq(vault.pendingRewards(bob), 3 ether);

        vm.prank(alice);
        vault.claimRewards();
        assertEq(vault.claimedRewards(alice), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.claimRewards();

        uint256 bobBalance = bob.balance;
        vm.prank(bob);
        vault.earlyExit();
        assertEq(bob.balance, bobBalance + 2.7 ether);
        assertEq(vault.rewardPot(), 4.3 ether);
        // The mock adapter pools all liquidity and redeems pro rata by shares.
        // Bob holds 3/4 of shares over 1150 pooled tokens => 862.5 tokens.
        assertEq(token.balanceOf(bob), 862.5 ether);
        vm.prank(bob);
        vm.expectRevert(VestaCovenantVault.AlreadyExited.selector);
        vault.earlyExit();
    }

    function testWithdrawAfterUnlock() public {
        _enrollAndFinalize();

        vm.prank(team);
        strategy.migrate();

        vm.warp(block.timestamp + 7 days);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawAfterUnlock();
        assertEq(alice.balance, balanceBefore + 1 ether);

        assertEq(token.balanceOf(alice), 287.5 ether);
    }

    function testFuzzEnrollAcceptsAllValidBps(uint16 bps, uint96 amount) public {
        bps = uint16(bound(bps, 0, 10_000));
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(alice, amount);
        vm.prank(alice);
        vault.enrollCovenant{ value: amount }(bps);
        VestaCovenantVault.Commitment memory commitment = vault.commitmentOf(alice);
        assertEq(commitment.escrowedEth, amount);
        assertEq(vault.totalEscrowedEth(), amount);
    }

    function _enrollAndFinalize() internal {
        vm.prank(alice);
        //0.4E should go to the LP, if the entire 1E is used to purchase in the CCA
        vault.enrollCovenant{ value: 1 ether }(4_000);
        vm.prank(bob);
        //1.5E should go to the LP
        vault.enrollCovenant{ value: 3 ether }(5_000);

        //these received token amounts are arbitrary, since the CCA is mocked, they also assume the entire subscribed amount was filled.
        auction.setAllocation(AUCTION, alice, 1_000 ether);
        auction.setAllocation(AUCTION, bob, 1500 ether);

        auction.setOutcome(AUCTION, 2e15, true);
        vm.prank(team);
        strategy.finalizeCovenants();
    }
}
