// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { MockLaunchToken } from "../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../contracts/VestaStrategy.sol";
import { SepoliaCcaAdapter } from "../contracts/adapters/SepoliaCcaAdapter.sol";
import { SepoliaLiquidityAdapter } from "../contracts/adapters/SepoliaLiquidityAdapter.sol";

/// @notice Deploys Vesta on Ethereum Sepolia using live Uniswap CCA and v4 adapters.
///
/// Prerequisites:
///   1. A ContinuousClearingAuction must already exist on Sepolia.
///      Create one via the factory at 0x000000001F26a0044BaA66024e7b6599c61963F8 or via
///      https://app.uniswap.org/launch.  Export its address as CCA_AUCTION_ADDRESS.
///   2. Set environment variables (see .env.example):
///        PRIVATE_KEY, SEPOLIA_RPC_URL, CCA_AUCTION_ADDRESS
///
/// Run (dry-run):
///   forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --dry-run -vvv
///
/// Run (broadcast):
///   forge script script/DeploySepolia.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL \
///     --broadcast \
///     --verify \
///     -vvv
///
/// Well-known Sepolia contract addresses used by the adapters:
///   ContinuousClearingAuctionFactory v2.1.0 : 0x000000001F26a0044BaA66024e7b6599c61963F8
///   LiquidityLauncher v3.0.0               : 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9
///   CCALens v2.0.0                         : 0xc3C65F5453A3674aDb693cbdA3C842545cD30f53
///   Uniswap v4 PoolManager                 : 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
///   Uniswap v4 PositionManager             : 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
contract DeploySepolia is Script {
    // Lock configuration — adjust before deploy.
    uint64 internal constant LOCK_DURATION = 7 days;
    uint16 internal constant EARLY_EXIT_PENALTY_BPS = 1_000; // 10 %

    function run() external returns (VestaStrategy strategy) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address auctionAddress = vm.envAddress("CCA_AUCTION_ADDRESS");

        console2.log("Deploying Vesta on Sepolia");
        console2.log("  CCA auction :", auctionAddress);
        console2.log("  Lock duration (s):", LOCK_DURATION);
        console2.log("  Early exit penalty (bps):", EARLY_EXIT_PENALTY_BPS);

        vm.startBroadcast(deployerKey);

        // Deploy a test launch token (mintable by the strategy).
        // For a real launch the token would already exist.
        MockLaunchToken token = new MockLaunchToken();
        console2.log("  LaunchToken:", address(token));

        // Deploy the real Sepolia adapters — no mock code in this path.
        SepoliaCcaAdapter ccaAdapter = new SepoliaCcaAdapter();
        SepoliaLiquidityAdapter liquidityAdapter = new SepoliaLiquidityAdapter();
        console2.log("  SepoliaCcaAdapter:", address(ccaAdapter));
        console2.log("  SepoliaLiquidityAdapter:", address(liquidityAdapter));

        // Deploy the strategy (which in turn deploys the vault).
        strategy = new VestaStrategy(
            auctionAddress,
            IMintableLaunchToken(address(token)),
            ccaAdapter,
            liquidityAdapter,
            LOCK_DURATION,
            EARLY_EXIT_PENALTY_BPS
        );
        console2.log("  VestaStrategy:", address(strategy));
        console2.log("  VestaCovenantVault:", address(strategy.vault()));

        // Open enrollment immediately so participants can start committing.
        strategy.openEnrollment();

        vm.stopBroadcast();

        // Write deployment addresses to a JSON file for the frontend.
        string memory json = "deployment";
        json = vm.serializeAddress(json, "strategy", address(strategy));
        json = vm.serializeAddress(json, "vault", address(strategy.vault()));
        json = vm.serializeAddress(json, "token", address(token));
        json = vm.serializeAddress(json, "ccaAdapter", address(ccaAdapter));
        json = vm.serializeAddress(json, "liquidityAdapter", address(liquidityAdapter));
        json = vm.serializeAddress(json, "auctionAddress", auctionAddress);
        json = vm.serializeUint(json, "chainId", block.chainid);
        vm.writeJson(json, "./frontend/src/generated/deployment.json");

        console2.log("\nDeployment complete.  Addresses written to frontend/src/generated/deployment.json");
    }
}
