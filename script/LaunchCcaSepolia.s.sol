// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockLaunchToken } from "../contracts/MockLaunchToken.sol";
import { AuctionParameters } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import { IContinuousClearingAuction } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import { IContinuousClearingAuctionFactory } from
    "continuous-clearing-auction/src/interfaces/IContinuousClearingAuctionFactory.sol";
import { IDistributor } from "liquidity-launcher/src/interfaces/IDistributor.sol";
import { ConstantsLib } from "continuous-clearing-auction/src/libraries/ConstantsLib.sol";
import { MaxBidPriceLib } from "continuous-clearing-auction/src/libraries/MaxBidPriceLib.sol";

/// @notice Launches a ContinuousClearingAuction on Sepolia via the canonical factory.
///
/// The auction sells `SALE_SUPPLY` whole tokens for ETH over a single flat
/// issuance step (uniform per-block supply). After creation the script funds
/// the auction and calls `onTokensReceived()`, so the auction is live.
///
/// Env (see .env.example):
///   PRIVATE_KEY (0x-prefixed), SEPOLIA_RPC_URL
///   TOKEN_ADDRESS (optional — deploys a mintable MockLaunchToken if unset)
///   SALE_SUPPLY (whole tokens, default 1000000)
///   FLOOR_PRICE_ETH (decimal ETH/token, default "0.0009765625" = 2^-10, ~1024 tokens/ETH)
///   TICK_SPACING_ETH (optional — defaults to floor/64)
///   AUCTION_BLOCKS (default 100; must divide 1e7 for the single-step schedule)
///   START_DELAY_BLOCKS (default 5), CLAIM_OFFSET_BLOCKS (default 10)
///   REQUIRED_CURRENCY_RAISED_ETH (default "0" — demo only; set a real threshold for production)
///   FUNDS_RECIPIENT / TOKENS_RECIPIENT (default deployer)
///   CCA_SALT (uint, default 0)
///
/// Run (dry-run first):
///   forge script script/LaunchCcaSepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --dry-run -vvv
/// Run (broadcast):
///   forge script script/LaunchCcaSepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
/// Then point DeploySepolia at the printed auction:
///   export CCA_AUCTION_ADDRESS=<auction>
contract LaunchCcaSepolia is Script {
    using SafeERC20 for IERC20;

    /// @notice Canonical ContinuousClearingAuctionFactory v2.1.0 on Sepolia.
    address internal constant FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;

    error BadSteps(string reason);
    error BadPrice(string reason);
    error InsufficientBalance(uint256 have, uint256 need);

    struct LaunchConfig {
        address tokenAddr;
        uint256 saleWhole;
        uint128 supply;
        uint256 floorQ96;
        uint256 spacingQ96;
        bytes steps;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint128 requiredRaised;
        address fundsRecipient;
        address tokensRecipient;
        bytes32 salt;
    }

    function run() external returns (IContinuousClearingAuction auction) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        LaunchConfig memory cfg = _loadConfig(deployer);

        AuctionParameters memory params = AuctionParameters({
            currency: address(0), // ETH-only bids
            tokensRecipient: cfg.tokensRecipient,
            fundsRecipient: cfg.fundsRecipient,
            startBlock: cfg.startBlock,
            endBlock: cfg.endBlock,
            claimBlock: cfg.claimBlock,
            tickSpacing: cfg.spacingQ96,
            validationHook: address(0),
            floorPrice: cfg.floorQ96,
            requiredCurrencyRaised: cfg.requiredRaised,
            auctionStepsData: cfg.steps
        });

        _logPlan(deployer, cfg);

        vm.startBroadcast(deployerKey);
        (auction, cfg.tokenAddr, cfg.supply) = _deployAndFund(deployer, cfg, params);
        vm.stopBroadcast();

        _report(auction, cfg);
    }

    function _loadConfig(address deployer) internal view returns (LaunchConfig memory cfg) {
        cfg.tokenAddr = vm.envOr("TOKEN_ADDRESS", address(0));
        cfg.saleWhole = vm.envOr("SALE_SUPPLY", uint256(1_000_000));
        if (cfg.saleWhole == 0 || cfg.saleWhole > ConstantsLib.MAX_TOTAL_SUPPLY) {
            revert BadSteps("SALE_SUPPLY out of range");
        }
        cfg.floorQ96 = _ethToQ96(vm.envOr("FLOOR_PRICE_ETH", string("0.0009765625")));
        if (cfg.floorQ96 < ConstantsLib.MIN_FLOOR_PRICE) {
            revert BadPrice("floor below MIN_FLOOR_PRICE");
        }
        string memory spacingStr = vm.envOr("TICK_SPACING_ETH", string(""));
        cfg.spacingQ96 =
            bytes(spacingStr).length == 0 ? cfg.floorQ96 / 64 : _ethToQ96(spacingStr);
        if (cfg.spacingQ96 < ConstantsLib.MIN_TICK_SPACING) {
            revert BadPrice("spacing below MIN_TICK_SPACING");
        }
        uint64 blocks = uint64(vm.envOr("AUCTION_BLOCKS", uint256(100)));
        if (blocks == 0 || ConstantsLib.MPS % blocks != 0) {
            revert BadSteps("AUCTION_BLOCKS must be > 0 and divide 1e7");
        }
        cfg.steps = abi.encodePacked(uint24(ConstantsLib.MPS / blocks), uint40(blocks));
        cfg.startBlock = uint64(block.number) + uint64(vm.envOr("START_DELAY_BLOCKS", uint256(5)));
        cfg.endBlock = cfg.startBlock + blocks;
        cfg.claimBlock = cfg.endBlock + uint64(vm.envOr("CLAIM_OFFSET_BLOCKS", uint256(10)));
        cfg.requiredRaised =
            uint128(_ethToWei(vm.envOr("REQUIRED_CURRENCY_RAISED_ETH", string("0"))));
        cfg.fundsRecipient = vm.envOr("FUNDS_RECIPIENT", deployer);
        cfg.tokensRecipient = vm.envOr("TOKENS_RECIPIENT", deployer);
        if (cfg.fundsRecipient == address(0) || cfg.tokensRecipient == address(0)) {
            revert BadSteps("recipients cannot be zero");
        }
        cfg.salt = bytes32(vm.envOr("CCA_SALT", uint256(0)));
    }

    function _deployAndFund(address deployer, LaunchConfig memory cfg, AuctionParameters memory params)
        internal
        returns (IContinuousClearingAuction auction, address tokenAddr, uint128 supply)
    {
        tokenAddr = cfg.tokenAddr;
        // Deploy a throwaway sale token if none was provided.
        if (tokenAddr == address(0)) {
            tokenAddr = address(new MockLaunchToken());
            MockLaunchToken(tokenAddr).mint(deployer, cfg.saleWhole * 1e18);
            console2.log("  MockLaunchToken:", tokenAddr);
        }
        uint8 dec = 18;
        try IERC20Metadata(tokenAddr).decimals() returns (uint8 d) {
            dec = d;
        } catch { }
        supply = uint128(cfg.saleWhole * 10 ** dec);

        // Protocol bound: floor + one tick must fit under the max bid price.
        uint256 maxBid = MaxBidPriceLib.maxBidPrice(supply);
        if (cfg.floorQ96 + cfg.spacingQ96 > maxBid) {
            revert BadPrice("floor+spacing exceeds maxBidPrice(supply)");
        }

        bytes memory configData = abi.encode(params);
        address predicted = address(
            IContinuousClearingAuctionFactory(FACTORY)
                .getAddress(tokenAddr, supply, configData, cfg.salt, deployer)
        );
        console2.log("  predicted auction:", predicted);

        auction = IContinuousClearingAuction(
            address(
                IContinuousClearingAuctionFactory(FACTORY)
                    .create(tokenAddr, supply, configData, cfg.salt)
            )
        );
        console2.log("  auction:", address(auction));

        // Fund + open the sale.
        uint256 balance = IERC20(tokenAddr).balanceOf(deployer);
        if (balance < supply) revert InsufficientBalance(balance, supply);
        IERC20(tokenAddr).safeTransfer(address(auction), supply);
        IDistributor(address(auction)).onTokensReceived();

        console2.log("  tokens funded:", supply);
    }

    function _report(IContinuousClearingAuction auction, LaunchConfig memory cfg) internal {
        console2.log("  start/end/claim:", cfg.startBlock, cfg.endBlock, cfg.claimBlock);
        // Frontend/operator reference (same folder DeploySepolia writes to).
        string memory json = string.concat(
            '{"auction":"',
            vm.toString(address(auction)),
            '","token":"',
            vm.toString(cfg.tokenAddr),
            '","supply":"',
            vm.toString(cfg.supply),
            '","startBlock":"',
            vm.toString(cfg.startBlock),
            '","endBlock":"',
            vm.toString(cfg.endBlock),
            '","claimBlock":"',
            vm.toString(cfg.claimBlock),
            '","floorPriceQ96":"',
            vm.toString(cfg.floorQ96),
            '","chainId":"',
            vm.toString(block.chainid),
            '"}'
        );
        vm.writeJson(json, "./frontend/src/generated/cca-launch.sepolia.json");
        console2.log("  wrote frontend/src/generated/cca-launch.sepolia.json");
        console2.log("  next: export CCA_AUCTION_ADDRESS=", address(auction));
    }

    /// @dev Parses a decimal ETH string ("0.002") to wei.
    function _ethToWei(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 whole = 0;
        uint256 frac = 0;
        uint256 fracDigits = 0;
        bool afterDot = false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == ".") {
                require(!afterDot, "bad decimal");
                afterDot = true;
                continue;
            }
            require(c >= "0" && c <= "9", "bad decimal");
            if (!afterDot) {
                whole = whole * 10 + (uint8(c) - 48);
            } else {
                if (fracDigits < 18) {
                    frac = frac * 10 + (uint8(c) - 48);
                    ++fracDigits;
                }
            }
        }
        while (fracDigits < 18) {
            frac *= 10;
            ++fracDigits;
        }
        return whole * 1e18 + frac;
    }

    /// @dev Decimal ETH/token string → Q96 currency-per-token.
    function _ethToQ96(string memory s) internal pure returns (uint256) {
        return (_ethToWei(s) * (1 << 96)) / 1e18;
    }

    function _logPlan(address deployer, LaunchConfig memory cfg) internal pure {
        console2.log("Launching CCA on Sepolia");
        console2.log("  factory :", FACTORY);
        console2.log("  deployer:", deployer);
        if (cfg.tokenAddr == address(0)) {
            console2.log("  token   : <deploy mock>");
        } else {
            console2.log("  token   :", cfg.tokenAddr);
        }
        console2.log("  sale (whole tokens):", cfg.saleWhole);
        console2.log("  floorQ96  :", cfg.floorQ96);
        console2.log("  spacingQ96:", cfg.spacingQ96);
        console2.log("  blocks    :", cfg.endBlock - cfg.startBlock);
    }
}
