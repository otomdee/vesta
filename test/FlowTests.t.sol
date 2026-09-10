// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { MockLaunchToken } from "../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../contracts/VestaStrategy.sol";
import { VestaCovenantVault } from "../contracts/VestaCovenantVault.sol";
import { MockCcaAdapter } from "../contracts/mocks/MockCcaAdapter.sol";
import { MockLiquidityAdapter } from "../contracts/mocks/MockLiquidityAdapter.sol";

contract VestaFlowTest is Test {
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
    }

    function testCCAtoFinalLPflow() public {
        vm.prank(team);
        strategy.openEnrollment();

        vm.prank(alice);
        //0.4E should go to the LP, if the entire 1E is used to purchase in the CCA
        vault.enrollCovenant{ value: 1 ether }(4_000);
        vm.prank(bob);
        //1.5E should go to the LP
        vault.enrollCovenant{ value: 3 ether }(5_000);

        auction.setAllocation(AUCTION, alice, 1_000 ether);
        auction.setAllocation(AUCTION, bob, 1500 ether);

        auction.setOutcome(AUCTION, 2e15, true);
        vm.prank(team);
        strategy.finalizeCovenants();

        vm.prank(team);
        strategy.migrate();

        //unfinished test, LP and token balance for alice isn't as I expected
    }
}
