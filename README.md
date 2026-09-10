# Vesta

Vesta is a token launch strategy: an external auction discovers a launch price, and bidders can opt to escrow ETH plus a percentage of their allocation for a locked liquidity position. In return, bidders get rewards set by the launch team.

> **Local demo only.** This repository deliberately uses mock adapters for Uniswap CCA allocation data and Uniswap v4 liquidity. They are not mainnet contracts and should not be used as such.

## Architecture

```text
                           external CCA
                               │ allocation + clearing price
                               ▼
Launch team ──► VestaStrategy ──► VestaCovenantVault ──► v4 (adapter boundary)
                    │                  │                       │
                    │             escrowed ETH              pooled LP shares
                    │                  │                       │
                    └── mint demo token ─┴── locked positions ─┘
                                        │
                                  rewards / exits
```

`VestaStrategy` is the owner-operated coordinator. `VestaCovenantVault` owns escrow, position records, the lock, and reward accounting. `IVestaAuctionAdapter` and `IVestaLiquidityAdapter` are explicit integration seams. The mock implementations under `contracts/mocks/` make the complete flow reproducible on Anvil.

## Reward and exit rules

- A participant's reward entitlement is `rewardPot × positionShares / totalPositionShares`.
- All MVP positions use one lock duration. No price oracle or volume scoring is used.
- `updateCovenant` makes ETH **additive**; it does not replace the prior escrow.
- An early exit returns the underlying LP redemption minus `earlyExitPenaltyBps`; the penalty is retained in the reward pot.
- A single pooled range redeems pro rata by LP shares. Therefore a redemption's token amount may differ from the participant's original token contribution if contributors supplied different token/ETH ratios.

## Prerequisites

- Foundry (Forge, Cast, Anvil)
- Node.js 20+
- A browser wallet connected to Anvil (`http://127.0.0.1:8545`, chain ID `31337`)

## Contracts and tests

```sh
forge build
forge test -vvv
```

The tests cover two-participant allocation splitting, escrow accounting, cancellation, invalid commitments, single migration, rewards, early exit, post-lock withdrawal, and fuzz valid bps/ETH inputs.

## Local demo

Terminal 1:

```sh
anvil
```

Terminal 2 (Anvil's first private key is supplied only through your shell):

```sh
export PRIVATE_KEY=<anvil-first-private-key>
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8545 --broadcast
```

The deployment script writes public contract addresses to `frontend/src/generated/deployment.json`. Connect two Anvil accounts in the UI, enroll them with different bps and ETH values, then run the operator completion with the generated strategy address and the two account addresses:

```sh
export VESTA_STRATEGY=<strategy-address>
export ALICE=<first-bidder-address>
export BOB=<second-bidder-address>
forge script script/DemoLocal.s.sol:DemoLocal --rpc-url http://127.0.0.1:8545 --broadcast
```

Fund rewards, claim, and exit actions are available in the UI. For a terminal-only path, the Foundry test `testRewardsAndEarlyExitRetainPenalty` is the reference.

## Integration status

The production-facing shape intentionally preserves Uniswap CCA as the price-discovery source and Uniswap v4 as the liquidity destination. The present `MockCcaAdapter` allows a test operator to set completed outcomes and per-user claims; the `MockLiquidityAdapter` records pool inputs and owns proportional demo shares. Replacing those adapters with the actual CCA claim reads and v4 position-manager calls is required before any real deployment.

## Limitations and security

- No audit has been performed; this code is not production-ready.
- `MockLaunchToken.mint` is deliberately unrestricted for local testing.
- The strategy is team-owner operated for enrollment opening, finalization, and migration.
- The mock liquidity adapter is not an AMM and has no ticks, fees, slippage protections, or real v4 position NFT.
- Reward funding is ETH-only and current entitlement is deterministic; no oracle is involved.
- Contract functions use reentrancy protection around ETH/token flows, but a real integration needs a dedicated threat model and audit.

See [Tasks.md](Tasks.md) for the build plan.
