# Tolly V3 Contract ABIs

This directory holds one JSON ABI per contract in the Tolly V3 system, extracted
from this repository's own compile. Each `*.json` file is a single JSON array
(the contract's ABI). For the events these ABIs emit and how to index them, see
[`../INDEXING.md`](../INDEXING.md).

## Compile provenance

The ABIs were extracted from the repo's own solc **0.8.26** compile
(`+commit.8a97fa7a`), matching the settings recorded in
[`../deployment/arc-mainnet-5042.json`](../deployment/arc-mainnet-5042.json):
EVM `cancun`, `viaIR` enabled, optimizer on with `200` runs, `bytecodeHash: none`,
OpenZeppelin **5.6.1**. The deployment file also carries the address map,
creation evidence, and constructor/immutable values for every fixed singleton.

## Licence boundary

Licensing is assigned **per file** - there is no single licence for the whole
repo. Several sources (`TollyForge.sol` except its `FullMath` library,
`TollySwapRouter.sol`, `TollyMultiRouter.sol`, `TollyFeeLocker.sol`,
`TollyHolderVault.sol`, `TollyTreasury.sol`) are Business Source License 1.1
(source-available, not open source before the 2028 Change Date);
`TollyPad.sol` and `libraries/TickMath.sol` are GPL-2.0-or-later. See
[`../LICENSE.md`](../LICENSE.md) for the authoritative per-file assignment
before any production use. These ABIs are interface descriptions of those
sources and inherit the same boundary.

## Fixed singletons (one deployed address each on Arc 5042)

| Contract | Source file | ABI file | Role | Deployment |
| --- | --- | --- | --- | --- |
| TollyPad | `contracts/launchpad/TollyPad.sol` | [`./TollyPad.json`](./TollyPad.json) | Launchpad: creates each token, seeds its single-sided V3 pool, locks the LP | `0xcad7ee36ac193bf2eddb7b3e2736c5bdb8269c8b` |
| TollyFeeLocker | `contracts/launchpad/TollyFeeLocker.sol` | [`./TollyFeeLocker.json`](./TollyFeeLocker.json) | Holds each launch's LP position NFT; collects and distributes trading fees | `0xe20e4297759597da75c8998ee76ec900600ad920` |
| TollyForgeDeployer | `contracts/TollyForge.sol` | [`./TollyForgeDeployer.json`](./TollyForgeDeployer.json) | Registry/deployer of launchpad Forges; wires the forge sub-factories | `0x04b8a7aeafce846acd3838ad5961787810339db1` |
| TollyUniversalForge | `contracts/TollyForge.sol` | [`./TollyUniversalForge.json`](./TollyUniversalForge.json) | Factory: creates per-token universal Burners and DCA Treasuries | `0x6619d00e448664ac900f1f512a5b65e8ac358a7b` |
| TollyRouterForge | `contracts/TollyForge.sol` | [`./TollyRouterForge.json`](./TollyRouterForge.json) | Factory: creates per-token Revenue Routers | `0xb808e78846205905607a425b329f0bcf8e036fab` |
| TollyLiquidityForgeFactory | `contracts/TollyForge.sol` | [`./TollyLiquidityForgeFactory.json`](./TollyLiquidityForgeFactory.json) | Factory: creates per-token Liquidity Forges | `0xd988b525960bf069cd2ef869642b8c2a26065cc0` |
| TollyFurnace | `contracts/TollyForge.sol` | [`./TollyFurnace.json`](./TollyFurnace.json) | Protocol-wide sink: banks tolls in WETH and buys back + burns TOLLY | `0xe60483df8bb33dbe7c50c47b440e957eb65614c3` |
| TollyMultiRouter | `contracts/TollyMultiRouter.sol` | [`./TollyMultiRouter.json`](./TollyMultiRouter.json) | Swap router with interface toll across V3 and V2-fork venues | `0xf28c138a39c234554c847dbef467b073ddbd7451` |
| TollySwapRouter | `contracts/TollySwapRouter.sol` | [`./TollySwapRouter.json`](./TollySwapRouter.json) | Swap router with interface toll (V3 only) | `0xcebc2e409a85cfa82b086674e6bc5bed51692777` |
| TollyTreasury | `contracts/launchpad/TollyTreasury.sol` | [`./TollyTreasury.json`](./TollyTreasury.json) | Protocol treasury; owner-gated withdrawals | `0xa00c3a33bcb68856f9fd86003e17f76a733fc355` |
| TollyHolderVault | `contracts/launchpad/TollyHolderVault.sol` | [`./TollyHolderVault.json`](./TollyHolderVault.json) | Holds and books per-project holder-reward accruals | `0x150bf8f4087d50da1081365e4a28d7912045a8f4` |
| TollyLens | `contracts/TollyLens.sol` | [`./TollyLens.json`](./TollyLens.json) | Read-only aggregator (no events) | `0xcb249e9613123ad57dc438d5393e471c00020959` |

## Per-token / per-creator instances (no single fixed address)

These have no fixed deployment. Each is created on-chain by a factory; you
discover instances by indexing the factory's creation event, then attach the
matching class ABI below to each discovered address. The deployment JSON records
one **example** address for TollyToken (the TOLLY token itself) and one for
TollyBurner (an example burner) - treat both as examples, not registries.

| Contract | Source file | ABI file | Role | Deployment (discover via) |
| --- | --- | --- | --- | --- |
| TollyToken | `contracts/launchpad/TollyToken.sol` | [`./TollyToken.json`](./TollyToken.json) | ERC-20 launched token (anti-snipe + max-wallet at launch) | per-token instance - discover via `TollyPad.TokenCreated` / `TollyPad.Launched`. Example: `0xbc43ce8dec648ea298c4275559b81d6261c90b67` (TOLLY) |
| TollyBurner | `contracts/TollyForge.sol` | [`./TollyBurner.json`](./TollyBurner.json) | Per-token buyback-and-burn tool | per-token instance - discover via `TollyUniversalForge.UniversalBurnerCreated` or `TollyForge.BurnerCreated`. Example: `0x41bd155c88148f29081901809ac04d34b5e66b1d` |
| TollyRevenueRouter | `contracts/TollyForge.sol` | [`./TollyRevenueRouter.json`](./TollyRevenueRouter.json) | Per-token fee router splitting revenue across allocations | per-creator instance - discover via `TollyRouterForge.RouterCreated` |
| TollyLiquidityForge | `contracts/TollyForge.sol` | [`./TollyLiquidityForge.json`](./TollyLiquidityForge.json) | Per-token LP tool: adds and time-locks liquidity | per-creator instance - discover via `TollyLiquidityForgeFactory.LiquidityForgeCreated` |
| TollyDcaTreasury | `contracts/TollyForge.sol` | [`./TollyDcaTreasury.json`](./TollyDcaTreasury.json) | Per-token DCA treasury (scheduled buys) | per-creator instance - discover via `TollyUniversalForge.DcaTreasuryCreated` |
| TollyForge | `contracts/TollyForge.sol` | [`./TollyForge.json`](./TollyForge.json) | Launchpad-Forge burner factory (deployable; **zero instances on mainnet**) | per-creator instance - discover via `TollyForgeDeployer.ForgeDeployed` |

## How to discover per-token instances

1. Index **`TollyPad.TokenCreated`** (and **`TollyPad.Launched`**) at the Pad
   address for every launched token and its V3 pool.
2. Index the factory creation events to find that token's tool instances:
   - **`TollyForgeDeployer.ForgeDeployed`** - a launchpad Forge (none on mainnet).
   - **`TollyRouterForge.RouterCreated`** - a `TollyRevenueRouter`.
   - **`TollyLiquidityForgeFactory.LiquidityForgeCreated`** - a `TollyLiquidityForge`.
   - **`TollyUniversalForge.DcaTreasuryCreated`** - a `TollyDcaTreasury`.
   - **`TollyUniversalForge.UniversalBurnerCreated`** - a `TollyBurner`.
   - **`TollyForge.BurnerCreated`** - a `TollyBurner` (from a launchpad Forge).
3. Attach the class ABI above to each discovered address and index its own
   events. Full topic0 hashes and per-event details are in
   [`../INDEXING.md`](../INDEXING.md).
