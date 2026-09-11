# Vesta — Handoff

Date: 2026-09-11. Branch: `frontend` @ `5277b12` ("add sepolia adapters").
`Tasks.md` checkboxes were never ticked — ignore them; this file is the source of truth.

## What it is

Vesta is a token-launch stack on Uniswap's Continuous Clearing Auction (CCA) + Uniswap v4:
bidders buy in the CCA, optionally escrow ETH + a share (`commitmentBps`, of 10_000) of their
token allocation into a locked v4 LP position, enforced with a lock duration, early-exit
penalty (bps), and a pro-rata ETH reward pot.

| Contract | Role |
|---|---|
| `contracts/VestaStrategy.sol` | Owner-only coordinator; deploys vault, gates `openEnrollment` / `finalizeCovenants` / `migrate` |
| `contracts/VestaCovenantVault.sol` | Escrow, per-user NFT positions (`tokenId` + escrow-weighted `shares`), rewards, lock/exit |
| `contracts/interfaces/*` | `IVestaAuctionAdapter` (CCA reads), `IVestaLiquidityAdapter` (v4 LP lifecycle) |
| `contracts/mocks/*` | Local-only CCA + liquidity stand-ins |
| `contracts/adapters/SepoliaCcaAdapter.sol` | Live CCA reads (`isGraduated && block >= endBlock`, 0-indexed bid scan, `pokeCheckpoint`) |
| `contracts/adapters/SepoliaLiquidityAdapter.sol` | Live v4 via PositionManager (one NFT per user, `TokenPricing` conversion) |

## What's done

- Core contracts + mock adapters + local scripts (`DeployLocal`, `DemoLocal`).
- Sepolia adapters, `DeploySepolia`, `LaunchCcaSepolia` (factory-based CCA launcher, env-configured).
- Vanilla `frontend/` (no build): **Sepolia-only, MetaMask-only**, full in-UI CCA bid/exit/claim + covenant flow.
- Tests: 14/14 green — 7 unit, 2 invariant, 5 Sepolia-fork (`test/sepolia/`).

## Uncommitted working tree (do not lose)

Most of the Sepolia hardening is **uncommitted** (see `git status`):
modified `contracts/adapters/*`, `foundry.toml` (incl. `solady` remap fix + bounded `[invariant]`),
`script/DeployLocal.s.sol`, `script/DeploySepolia.s.sol`, `test/sepolia/*`, `.env.example`,
`README.md`; new `frontend/{app.js,index.html,styles.css}`, `script/LaunchCcaSepolia.s.sol`.
Commit or stash before switching branches.

## How to run

```sh
forge build
forge test                        # 9 local (invariant bounded: runs=64, depth=32)
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path 'test/sepolia/*'
```

Local demo: `anvil` → `DeployLocal --broadcast` (needs `PRIVATE_KEY` **with** `0x`, plus
`ETHERSCAN_API_KEY` set even to dummy) → serve `frontend/` over HTTP (not `file://`).

Sepolia flow (manual, needs funded key + existing CCA auction):
1. `LaunchCcaSepolia --broadcast` → `export CCA_AUCTION_ADDRESS=…`
2. `DeploySepolia --broadcast --verify` → fills `frontend/src/generated/deployment.sepolia.json`
3. Serve `frontend/`, connect MetaMask (team + participant), then:
   bid + enroll → `pokeCheckpoint` → **exit CCA bids** → finalize → migrate → fund → claim/exit/withdraw.

## Gotchas (earned, please keep)

- CCA price is **currency-per-token** Q96; v4 needs the inverse — adapter uses `TokenPricing` (same as `LBPStrategy`).
- `Bid.tokensFilled` is 0 until `exitBid`; finalize reads 0 otherwise. Checkpoint first (checkpoints exclude the current block — roll +1 in tests).
- Bid IDs are 0-indexed; `isGraduated()` can be true mid-auction; vault mints one NFT **per user** (never split a token ID as shares).
- Sepolia Permit2 is `…BA3`, not mainnet's `…BA2`; read it from `PositionManager.permit2()`.
- `vm.serialize*` chaining drops all but the last key in this forge version — scripts build JSON via `string.concat`.
- Default invariant runs×depth effectively never finishes; `cast --private-key` on this machine wants no `0x` while `vm.envUint` requires it; read Anvil keys from its startup log.
- `deployment.json` (local) vs `deployment.sepolia.json` vs `cca-launch.sepolia.json` in `frontend/src/generated/`.

## Suggested next steps

1. Live Sepolia run (manual): launch → deploy → full UI click-through.
2. `exitPartiallyFilledBid` support (needs checkpoint hints; UI currently punts to cast).
3. >500-bid auctions need off-chain bid indexing (`MAX_BID_SCAN`).
4. Real-launch token sourcing (strategy can't mint what it isn't authorized for).
5. Commit the working tree; then audit + DOCS update (`Tasks.md`/`PRD.md` lag the code).
