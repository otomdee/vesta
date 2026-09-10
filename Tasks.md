# Vesta — Build Tasks

## Working rules

- Build contracts and tests first. Do not start the frontend until the local Foundry scenario passes.
- Preserve Uniswap CCA as an external dependency; do not recreate CCA logic.
- Use a clearly named adapter/mocking boundary if direct v4/CCA integration blocks local progress.
- Never make a mock look like a mainnet deployment. Label all local-demo paths in code, README, and UI.
- Keep commits logically scoped if using git.

## Phase 0 — Bootstrap and design

- [ ] Create a repository layout:

  ```text
  vesta/
  ├─ contracts/
  ├─ test/
  ├─ script/
  ├─ lib/
  ├─ frontend/
  ├─ README.md
  └─ foundry.toml
  ```

- [ ] Initialize Foundry.
- [ ] Add OpenZeppelin and the official Uniswap CCA source/interfaces as dependencies.
- [ ] Decide whether direct CCA/v4 local deployment is feasible. Record the decision and adapter boundary in `README.md`.
- [ ] Add an architecture diagram.
- [ ] Define custom errors and event names before writing implementation.

**Exit criterion:** `forge build` succeeds with imports resolved.

## Phase 1 — Core contract skeletons

- [ ] Implement `MockLaunchToken.sol` with test-only minting.
- [ ] Define `IVestaAuctionAdapter.sol`:
  - finalized/claimable allocation lookup;
  - clearing price lookup;
  - auction completion check.
- [ ] Define `IVestaLiquidityAdapter.sol`:
  - pool initialization;
  - add liquidity;
  - remove/redemption of proportional position share.
- [ ] Implement `VestaCovenantVault.sol` storage and lifecycle state.
- [ ] Implement `VestaStrategy.sol` configuration and lifecycle gates.
- [ ] Implement `MockCcaAdapter.sol` and `MockLiquidityAdapter.sol` only in test/demo paths.

**Exit criterion:** contracts compile; no implementation function is left silently unguarded.

## Phase 2 — Covenant enrollment and accounting

- [ ] Implement `enrollCovenant(commitmentBps)` payable.
- [ ] Validate `commitmentBps <= 10_000` and nonzero ETH contribution.
- [ ] Emit `CovenantEnrolled(user, commitmentBps, escrowedEth)`.
- [ ] Implement pre-finalization update behavior; choose and document whether new ETH is additive or replaces the prior escrow.
- [ ] Implement cancellation/refund before finalization.
- [ ] Implement read functions for UI: commitment, position, lifecycle, unlock time, pending rewards.
- [ ] Write unit tests for enrollment, update, cancellation, invalid bps, invalid lifecycle, and ETH conservation.

**Exit criterion:** two users can hold different commitments and all escrow is accurately tracked.

## Phase 3 — Finalization, v4 migration, positions

- [ ] Implement `finalizeCovenants()` after auction completion.
- [ ] Calculate each participant's committed token amount from actual allocation × commitment bps.
- [ ] Ensure liquid allocation is not consumed by the covenant path.
- [ ] Implement `migrate()` as a one-time transition:
  - initialize the ERC-20/ETH pool at the adapter-provided clearing price;
  - send total committed token and ETH to the liquidity adapter;
  - record proportional LP shares and lock timestamps.
- [ ] Emit `CovenantsFinalized`, `PoolMigrated`, and `PositionCreated` events.
- [ ] Write tests for two participants with different allocation and commitment sizes.
- [ ] Write a test that proves migration cannot happen twice.
- [ ] If direct v4 integration is ready, add a local Anvil/fork test that verifies the actual pool/position call. Otherwise, explicitly test the adapter call data and keep the mock adapter isolated.

**Exit criterion:** a deterministic test demonstrates CCA outcome → covenant split → liquidity position shares.

## Phase 4 — Rewards, lock, and exit

- [ ] Choose and document the MVP reward formula:

  ```text
  reward share = user liquidity contribution / total covenant liquidity contribution
  ```

  Treat all positions as equal lock duration for MVP unless multiple lock terms are deliberately implemented.

- [ ] Implement reward-pot funding and `claimRewards()`.
- [ ] Implement `withdrawAfterUnlock()`.
- [ ] Implement `earlyExit()` before unlock and transfer/account for the configured penalty.
- [ ] Emit `RewardsClaimed`, `PositionWithdrawn`, and `EarlyExit` events.
- [ ] Test reward pro-rata accounting, one-time claims, lock enforcement, early-exit penalty, and normal withdrawal after warp past unlock.

**Exit criterion:** no user can double-claim, double-withdraw, or cause accounting deficits.

## Phase 5 — Security and test quality

- [ ] Add fuzz tests for commitment bps, ETH values, participant ordering, and reward allocations.
- [ ] Add invariants:
  - escrow/reward/position ETH accounting never exceeds contract balance;
  - total claimed rewards never exceeds funded rewards plus accounted penalties;
  - migrated state is irreversible;
  - position shares cannot exceed the total minted shares.
- [ ] Add reentrancy protection to ETH/token outflows and test with a malicious receiver if applicable.
- [ ] Run `forge fmt`, `forge test -vvv`, and `forge coverage`.
- [ ] Add NatSpec to all user-facing external functions and document all trust assumptions.

**Exit criterion:** all tests pass locally and the README can state exactly what is and is not production-ready.

## Phase 6 — Deployment scripts and local demo

- [ ] Write `script/DeployLocal.s.sol` to deploy the mock token, adapters, strategy, vault, and configure a sample launch.
- [ ] Write `script/DemoLocal.s.sol` or a documented sequence that:
  1. starts Anvil;
  2. deploys Vesta;
  3. creates two bidder commitments;
  4. sets mock CCA outcome;
  5. finalizes/migrates;
  6. funds and claims rewards;
  7. demonstrates early exit.
- [ ] Save deployment addresses to a frontend-readable local JSON file without putting secrets in the file.
- [ ] Verify the full sequence from a clean local node.

**Exit criterion:** one command sequence rebuilds the local demo reliably.

## Phase 7 — React frontend

Start only after Phase 6 passes.

- [ ] Initialize `frontend/` with Vite, React, and TypeScript.
- [ ] Add wagmi, viem, and a local Anvil chain configuration.
- [ ] Add a contract-address configuration file generated from the local deployment script.
- [ ] Build the launch overview screen with lifecycle state and terms.
- [ ] Build the covenant form:
  - commitment percentage;
  - ETH contribution;
  - calculated liquid/covenant allocation preview;
  - enroll/update/cancel buttons.
- [ ] Build the participant-position view:
  - committed ERC-20 and ETH;
  - LP shares;
  - unlock time/countdown;
  - pending rewards;
  - early-exit penalty;
  - actions gated by lifecycle.
- [ ] Build a local-demo operator panel for finalization and migration; make its local-only status unmissable.
- [ ] Display emitted event/transaction hashes and success/error messages.
- [ ] Apply the Vesta whiteboard/pastel visual language, but do not let styling delay the working flow.

**Exit criterion:** a user can complete the two-bidder happy path in a browser connected to Anvil.

## Phase 8 — Documentation and final verification

- [ ] Write `README.md` with product overview, architecture, prerequisites, exact commands, and local demo flow.
- [ ] Explain the use of Uniswap CCA and any mock adapter in a dedicated "Integration status" section.
- [ ] Add a limitations/security section.
- [ ] Include the architecture image.
- [ ] Verify from scratch:
  - `forge build`;
  - `forge test`;
  - Anvil deployment/demo;
  - `npm install` and frontend dev server;
  - browser happy path.
- [ ] Capture a concise demo script for a three-minute hackathon video.

## Definition of done

- [ ] Contracts are compilable, formatted, and tested locally.
- [ ] The local demonstration proves the covenant split, LP migration, lock, rewards, and penalty.
- [ ] The React app can run the demonstrated flow against Anvil without a backend.
- [ ] Every mock or simulation is clearly labeled.
- [ ] The repository explains how the implementation could swap mock adapters for production Uniswap CCA/v4 integration.
