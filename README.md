# RedCarpetHQ Smart Contracts

Solidity smart contracts for RedCarpetHQ — an RWA platform for the entertainment industry enabling crowdfunding, token trading, and lending/borrowing.

- **Language:** Solidity 0.8.20
- **Framework:** [Foundry](https://book.getfoundry.sh/)
- **Upgrade pattern:** UUPS (ERC1967 proxies) for `Registry`, `SingleRoundCampaign`, `MultiRoundCampaign`
- **Libraries:** OpenZeppelin Contracts & Contracts-Upgradeable (vendored in `lib/`)

See `AGENTS.md` for the full architecture overview and contract catalog.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Git

```bash
# Install Foundry (if needed)
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Setup

Dependencies (`forge-std`, `openzeppelin-contracts`, `openzeppelin-contracts-upgradeable`) are git submodules under `lib/`, pinned by `foundry.lock` — they are **not** vendored in the repo.

```bash
# From the repo root, after cloning:
git submodule update --init --recursive

cd smart-contracts

# Alternative (fetches the pinned versions from foundry.lock):
forge install

# Build
forge build
```

## Testing

```bash
# Run the full test suite
forge test

# Verbose output (shows revert reasons, logs, traces)
forge test -vvv

# Run a single test file
forge test --match-contract RegistryTest

# Run a single test function
forge test --match-test test_RegisterCampaign

# Gas report
forge test --gas-report
```

Tests live in `test/` as `*.t.sol` files using forge-std. Fuzz tests run **10,000 runs** by default (`foundry.toml`); to iterate faster locally:

```bash
FOUNDRY_FUZZ_RUNS=256 forge test
```

## Deployment

Target network: **Robinhood Chain Testnet** (Arbitrum Orbit L2).

| Setting | Value |
|---|---|
| Chain ID | `46630` |
| RPC URL | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` (Blockscout) |
| `--rpc-url` alias | `robinhoodtestnet` (defined in `foundry.toml`) |

`script/DeployRedCarpetHQ.s.sol` is the primary deployment script. It deploys the full protocol **and** applies the complete configuration inline (Registry wiring, authorizations, oracle/lending/contest setup, and timing parameters), so the deployment is usable immediately with no post-deployment transactions required.

> **Important:** All configuration calls are executed by the deployer, so `OWNER_ADDRESS` must be the address derived from `DEPLOYER_PRIVATE_KEY`.

### Environment variables

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

```bash
# Required
DEPLOYER_PRIVATE_KEY=0x...            # Deployer key (also becomes protocol owner)
OWNER_ADDRESS=0x...                   # Must equal the deployer address
FEE_SAFE_ADDRESS=0x...                # Wallet/safe that receives protocol fees

# Payment token — leave unset/false for testnet so the script deploys TestUSDR
PRODUCTION=false
TEST_USDR_ADDRESS=0x...               # Optional: reuse an existing TestUSDR instead of deploying a new one

# Optional
ADMIN_ADDRESSES=0xabc...,0xdef...     # Comma-separated; each is set as a CampaignAdmin screener

# RPC endpoint
ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com
```

### Deploying TestUSDR separately (optional)

The main deploy script deploys `TestUSDR` automatically. To deploy it standalone — e.g. so the same payment token survives across protocol redeployments — use `script/DeployTestUSDR.s.sol`. It only needs `DEPLOYER_PRIVATE_KEY` (the deployer becomes the token owner and receives the initial mint):

```bash
source .env

forge script script/DeployTestUSDR.s.sol \
  --rpc-url robinhoodtestnet \
  --broadcast \
  -vvvv
```

Then copy the printed `TEST_USDR_ADDRESS` into `.env` — the main deployment will reuse it instead of deploying a new token.

### Deploy

Deploys a fresh `TestUSDR` payment token (or reuses `TEST_USDR_ADDRESS` if set), then the rest of the protocol:

```bash
source .env

# Dry run (simulation only, no broadcast)
forge script script/DeployRedCarpetHQ.s.sol --rpc-url robinhoodtestnet -vvvv

# Live deployment
forge script script/DeployRedCarpetHQ.s.sol \
  --rpc-url robinhoodtestnet \
  --broadcast \
  -vvvv
```

### Contract verification (optional)

The Robinhood testnet explorer is Blockscout — pass verifier flags explicitly since the chain isn't in the `[etherscan]` config:

```bash
forge script script/DeployRedCarpetHQ.s.sol \
  --rpc-url robinhoodtestnet \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api \
  -vvvv
```

### What gets deployed

| Contract | Notes |
|---|---|
| TestUSDR | Test payment token; skipped when `TEST_USDR_ADDRESS` is set |
| MinimumERC20 | Token implementation for campaign token clones |
| Registry | UUPS proxy + implementation — single source of truth for all addresses |
| DividendDistributor | USDC dividend distribution to token holders |
| CampaignAdmin, CampaignFeeManager | Campaign screening/extensions; UI/integrator fee registry |
| SingleRoundCampaign, MultiRoundCampaign | UUPS proxies + implementations |
| MarketMulticall | Escrow-based trading, 2.5% trade fee, batched calls |
| HybridPriceOracle, OptimisticPriceOracle, RiskOracle | VWAP oracle, optimistic pricing, GREEN/YELLOW/RED risk tiers |
| JumpRateModel | Tier-based interest rate presets |
| VolumeTracker, TierLogic | 30-day volume tracking → fee discount tiers (Bronze/Silver/Gold) |
| InterestLogic, LendingLogic, StabilityLogic, MultiRoundLogic | Shared stateless logic contracts |
| VaultFactory, LendingManager | Deploy `UnifiedVault` (ERC-4626) per token |
| FeeDistributor | Fee split: 40% fee safe / 40% contest / 10% vault / 10% producer |
| Contest, KeeperRegistry, BurnRedemption, SurveySnapshot | Epoch rewards, automation, redemption, holder snapshots |

### After deployment

1. **Save the addresses** — the script prints a ready-to-paste `=== Add to .env ===` block (`REGISTRY_ADDRESS`, `MARKET_ADDRESS`, etc.) plus per-contract addresses in the summary. Broadcast artifacts are also written to `broadcast/DeployRedCarpetHQ.s.sol/<chainId>/`.
2. **Verify the configuration** (optional, read-only):
   ```bash
   source .env
   forge script script/VerifyMultisigSetup.s.sol --rpc-url robinhoodtestnet -vvvv
   ```
   This asserts every Registry address, authorization, oracle wiring, and timing parameter — it passes for deployments made by this script.
3. **Per-vault setup** — `UnifiedVault` instances are created later via `LendingManager`. For each new vault, call:
   ```bash
   cast send <VAULT_ADDRESS> "setMinDepositDuration(uint256)" 3600 \
     --rpc-url robinhoodtestnet --private-key $DEPLOYER_PRIVATE_KEY
   ```

### Troubleshooting

- **`OWNER_ADDRESS` mismatch** — the script requires the deployer to be the owner; check that `cast wallet address $DEPLOYER_PRIVATE_KEY` equals `OWNER_ADDRESS`.
- **RPC rate limiting** — `foundry.toml` sets `delay = 3000` (3s between transactions; supported on older forge versions). If a chain still rate-limits, re-run the script — broadcast resumes via `broadcast/` artifacts — or switch to a faster RPC.
- **Re-running a partial deploy** — set `TEST_USDR_ADDRESS` to reuse the existing token; other contracts are always redeployed fresh.
- **Verification failures** — contracts can be verified after the fact: `forge verify-contract <address> src/<Contract>.sol:<ContractName> --chain 46630 --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api --watch`.

## Repository layout

```
src/            Core contracts (Registry, campaigns, Market, vaults, oracles)
src/interfaces/ Contract interfaces
src/logic/      Shared logic contracts (TierLogic, LendingLogic, ...)
src/storage/    Storage contracts (VolumeTracker)
script/         Deployment & maintenance scripts
test/           Forge test suites (*.t.sol)
lib/            Dependencies (forge-std, OpenZeppelin)
foundry.toml    Compiler, fuzz, RPC, and explorer config
```
