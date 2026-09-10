// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { VestaStrategy } from "../contracts/VestaStrategy.sol";
import { VestaCovenantVault } from "../contracts/VestaCovenantVault.sol";
import { MockCcaAdapter } from "../contracts/mocks/MockCcaAdapter.sol";

/// @notice Runs the operator portion of the local demo after two browser/test-account enrollments.
contract DemoLocal is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        VestaStrategy strategy = VestaStrategy(vm.envAddress("VESTA_STRATEGY"));
        VestaCovenantVault vault = strategy.vault();
        MockCcaAdapter auction = MockCcaAdapter(address(strategy.auctionAdapter()));
        address alice = vm.envAddress("ALICE");
        address bob = vm.envAddress("BOB");
        address auctionAddress = strategy.auction();

        vm.startBroadcast(key);
        auction.setAllocation(auctionAddress, alice, 1_000 ether);
        auction.setAllocation(auctionAddress, bob, 500 ether);
        auction.setOutcome(auctionAddress, 2e15, true);
        strategy.finalizeCovenants();
        strategy.migrate();
        vault.fundRewards{ value: 4 ether }();
        vm.stopBroadcast();
    }
}
