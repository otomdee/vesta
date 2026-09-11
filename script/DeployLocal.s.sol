// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { MockLaunchToken } from "../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../contracts/VestaStrategy.sol";
import { MockCcaAdapter } from "../contracts/mocks/MockCcaAdapter.sol";
import { MockLiquidityAdapter } from "../contracts/mocks/MockLiquidityAdapter.sol";

/// @notice Deploys a clearly labelled, adapter-backed Vesta local demo and emits frontend addresses.
contract DeployLocal is Script {
    address internal constant DEMO_AUCTION = address(0xCAFE);

    function run() external returns (VestaStrategy strategy) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockLaunchToken token = new MockLaunchToken();
        MockCcaAdapter auctionAdapter = new MockCcaAdapter();
        MockLiquidityAdapter liquidityAdapter = new MockLiquidityAdapter();
        strategy = new VestaStrategy(
            DEMO_AUCTION,
            IMintableLaunchToken(address(token)),
            auctionAdapter,
            liquidityAdapter,
            7 days,
            1_000
        );
        strategy.openEnrollment();
        vm.stopBroadcast();

        // NOTE: vm.serialize* chaining drops all but the last key in this
        // forge version, so the JSON is built explicitly instead.
        string memory json = string.concat(
            '{"strategy":"',
            vm.toString(address(strategy)),
            '","vault":"',
            vm.toString(address(strategy.vault())),
            '","token":"',
            vm.toString(address(token)),
            '","auctionAdapter":"',
            vm.toString(address(auctionAdapter)),
            '","liquidityAdapter":"',
            vm.toString(address(liquidityAdapter)),
            '","demoAuction":"',
            vm.toString(DEMO_AUCTION),
            '"}'
        );
        vm.writeJson(json, "./frontend/src/generated/deployment.json");
    }
}
