# Tolly V3 — Event & Indexing Reference

Everything an indexer needs to discover Tolly tokens and tools, follow trades,
and track fees, locks, and distributions. Canonical event names, signatures, and
`topic0` hashes are taken verbatim from the compiled ABIs. Per-contract ABIs are
in [`abis/`](abis/) (see [`abis/README.md`](abis/README.md)); the address map
and creation evidence are in
[`deployment/arc-mainnet-5042.json`](deployment/arc-mainnet-5042.json).

## 1. Scope & chain

- **Network:** Arc mainnet, **chainId 5042**.
- **Quote asset:** `0x3600000000000000000000000000000000000000` (native quote / "WETH"
  role in the code). Actual trade prices live in the underlying Uniswap V3/V2
  pool `Swap` events, not in this repo (see §5).
- **Fixed singletons** (index at these addresses):

  | Contract | Address |
  | --- | --- |
  | TollyPad | `0xcad7ee36ac193bf2eddb7b3e2736c5bdb8269c8b` |
  | TollyFeeLocker | `0xe20e4297759597da75c8998ee76ec900600ad920` |
  | TollyForgeDeployer | `0x04b8a7aeafce846acd3838ad5961787810339db1` |
  | TollyUniversalForge | `0x6619d00e448664ac900f1f512a5b65e8ac358a7b` |
  | TollyRouterForge | `0xb808e78846205905607a425b329f0bcf8e036fab` |
  | TollyLiquidityForgeFactory | `0xd988b525960bf069cd2ef869642b8c2a26065cc0` |
  | TollyFurnace | `0xe60483df8bb33dbe7c50c47b440e957eb65614c3` |
  | TollyMultiRouter | `0xf28c138a39c234554c847dbef467b073ddbd7451` |
  | TollySwapRouter | `0xcebc2e409a85cfa82b086674e6bc5bed51692777` |
  | TollyTreasury | `0xa00c3a33bcb68856f9fd86003e17f76a733fc355` |
  | TollyHolderVault | `0x150bf8f4087d50da1081365e4a28d7912045a8f4` |
  | TollyLens | `0xcb249e9613123ad57dc438d5393e471c00020959` |

- **Per-token / per-creator instances** have no fixed address; discover them via
  factory events (§4). The deployment JSON records one **example** each:
  TollyToken `0xbc43ce8dec648ea298c4275559b81d6261c90b67` (the TOLLY token) and
  TollyBurner `0x41bd155c88148f29081901809ac04d34b5e66b1d`.

## 2. Indexing by purpose

**(a) Discovery of tokens and tools**
- Tokens + pools: `TollyPad.TokenCreated`, `TollyPad.Launched` (Pad address).
- Tool instances: `TollyForgeDeployer.ForgeDeployed`,
  `TollyRouterForge.RouterCreated`,
  `TollyLiquidityForgeFactory.LiquidityForgeCreated`,
  `TollyUniversalForge.DcaTreasuryCreated`,
  `TollyUniversalForge.UniversalBurnerCreated`, `TollyForge.BurnerCreated`.

**(b) Trades / pricing**
- Interface-fee wrappers: `TollySwapRouter.SwappedWithToll`,
  `TollyMultiRouter.SwappedWithToll` (router addresses). These record the toll,
  not the pool price — get executed price from the pool's own `Swap` (§5).
- Token movements: `TollyToken.Transfer` on each launched token.

**(c) Fee collection & distribution**
- Launch LP fees: `TollyFeeLocker.FeesCollected` then the distribution events
  (`TollPaid`, `ProtocolFeePaid`, `HolderRewardsAccrued`, `ProjectBurnRouted` /
  `ProjectBurnUnrouted`, `TokenFeesBurned`, `CreatorPaid` / `CreatorPayFailed`,
  `FeesClaimed`).
- Protocol burns: `TollyFurnace.TollDeposited`, `TollyFurnace.TollyBurned`.
- Per-token tool processing: `TollyBurner.Buyback`,
  `TollyRevenueRouter.RouterProcessed` / `Allocated`,
  `TollyDcaTreasury.DcaExecuted`, `TollyLiquidityForge.LiquidityAdded` /
  `LpFeesCollected`.
- Holder rewards ledger: `TollyHolderVault.Accrued`.

**(d) Locks / positions**
- Launch LP lock: `TollyFeeLocker.PositionLocked`.
- Tool LP locks: `TollyLiquidityForge.LockExtended`, `MadePermanent`,
  `PositionWithdrawn`.

## 3. Per-contract reference

For each event: canonical `EventName(types)` — `topic0` — indexed fields —
meaning. Ownership/admin events are marked *lifecycle/optional*.

### TollyPad — `0xcad7ee36ac193bf2eddb7b3e2736c5bdb8269c8b`

- `TokenCreated(address,address,string,string,address,string,string,string,string)` — `0x875522b092d9e19a1de359e4bd218090d582fa521c9733889acf1a5ff1941255` — indexed: `token`, `creator` — a new token was created; carries name, symbol, pool, and metadata URIs.
- `Launched(address,address,uint256,uint128,uint256)` — `0x507232c314c89b0fe087cad8c1071f5e0d9af45f9057b5f55f75317c09a1554c` — indexed: `token`, `pool` — the token's single-sided V3 pool was seeded and its LP NFT (`lpTokenId`, `liquidity`, `tokenSeeded`) minted/locked.
- `DevBuy(address,address,uint256,uint256)` — `0x84d429ed8af1c9cfe8bb07b556e4120e976c9f4c9232a7f50a15d31d83e232a9` — indexed: `token`, `creator` — the creator's optional launch-time buy (`quoteIn` → `tokensOut`).
- `BurnerAutoMinted(address,address)` — `0xdefd84618a4d1aceaf28aa60244fec2d00fa75f65b7243abd1c965cc80881b9a` — indexed: `token`, `burner` — a Burner was auto-created for the token during launch.
- `TokenMetaUpdated(address,address,string,string,string,string)` — `0x4a5d54c3dd9bc7c733b12e6dfc35810537f65455fece61b4cda10206d4cb9aff` — indexed: `token`, `creator` — creator updated image/website/twitter/telegram metadata (no funds move).
- `BannedSet(bytes32,bool)` — `0xb4c9eebe19a2a2dae2c6f4a808b1543e8a062e7ab72cb6330890051a067cd736` — indexed: `wordHash` — *lifecycle/optional* — owner banned/unbanned a normalized name/symbol word hash.
- `OwnershipTransferred(address,address)` — `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` — indexed: `previousOwner`, `newOwner` — *lifecycle/optional* — Pad ownership changed.

**Key instructions (entrypoints):** `createToken` (emits `TokenCreated`,
`Launched`, `DevBuy`, `BurnerAutoMinted`); `updateMeta` (`TokenMetaUpdated`);
`setBanned` (`BannedSet`); `transferOwnership` (`OwnershipTransferred`).

### TollyToken — per-token instance (example `0xbc43ce8dec648ea298c4275559b81d6261c90b67`)

Standard ERC-20 events only (OpenZeppelin 5.6.1).

- `Transfer(address,address,uint256)` — `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` — indexed: `from`, `to` — token transfer/mint/burn; the core signal for balances and holder sets.
- `Approval(address,address,uint256)` — `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` — indexed: `owner`, `spender` — *lifecycle/optional* — ERC-20 allowance set.

**Key instructions (entrypoints):** `transfer` / `transferFrom` / `approve`
(ERC-20). Transfers apply the launch anti-snipe deadline and max-wallet cap in
`_update`; `setPool` records the pool but emits nothing.

### TollyFeeLocker — `0xe20e4297759597da75c8998ee76ec900600ad920`

- `PositionLocked(uint256,address,address)` — `0xa440229f738a9fb80807b5a881152e41634f4879749dc3fd163415962c4ce45e` — indexed: `tokenId`, `launchedToken`, `creator` — a launch LP position NFT was registered and permanently locked here.
- `FeesCollected(uint256,address,uint256,uint256)` — `0x1df95d0058852523ea13aa1809224af942bd446ce86d3e431bf193c2bec269f1` — indexed: `tokenId`, `caller` — V3 fees (`amount0`, `amount1`) collected from a locked position.
- `TollPaid(address,uint256)` — `0x08a87033fc68bf458bd6e181a2e5ccbac239bdca46d8a753a172f5473ac05f5c` — indexed: `project` — protocol toll portion (TOLLY burn) routed out during distribution.
- `ProtocolFeePaid(address,uint256)` — `0xb87e607f6030a23ed9b7dac1a717610f3a3b07325269f18808ba763bdcefe7ae` — indexed: `project` — protocol fee share sent to the treasury.
- `HolderRewardsAccrued(address,uint256)` — `0xdaa6725b8e075f72dd56af70e3f199ea01db80c1d3b6576b059f489351e35687` — indexed: `project` — amount earmarked as holder rewards (evidence only; not a ledger write here).
- `ProjectBurnRouted(address,address,uint256)` — `0xbf4cc7a0210966d5c7af00c51e00174dc6717f21eefda99b8444d83e5dde197d` — indexed: `project`, `burner` — project burn share forwarded to the token's Burner.
- `ProjectBurnUnrouted(address,uint256)` — `0x15774664a1fb003868b96417940c3c6063b9618a9bd1e15e3e5cade2eb85e64d` — indexed: `project` — project burn share could not be routed (no burner) and stays claimable.
- `TokenFeesBurned(address,uint256)` — `0xd62f8440b6eb3ec1090b52873a88a127de1cc44a838d6324703705596039022b` — indexed: `asset` — fees denominated in the launched token were burned outright.
- `CreatorPaid(address,address,uint256)` — `0x3659e7fe852ba36408424c35e6422879f7a37b1f228466f2e2741ed87e686897` — indexed: `creator`, `payout` — creator fee share paid to the payout address.
- `CreatorPayFailed(address,address,uint256)` — `0x0bcd25037494b0d1dc2f2528a0c72820f395b3d9b877389a419e729c9776488e` — indexed: `creator`, `payout` — creator payout transfer failed; amount left claimable.
- `FeesClaimed(address,address,uint256)` — `0xfe3464cd748424446c37877c28ce5b700222c5bc9f90d908afcc4e5cb22707ff` — indexed: `asset`, `beneficiary` — a beneficiary pulled their claimable balance of an asset.
- `PayoutSet(address,address)` — `0x18b5078a8a55f53c428467b7f19cf8408acc494f8ae06b3e6202b7b2b19d23dc` — indexed: `creator`, `payout` — creator set/changed their payout destination.
- `ProtocolFeePaid` — see above. `Initialized(address,address,address,address)` — `0x3514319b7a526ad5f1f42edf0c1df25fa0ea2ae054779987fbe636f164515e2f` — indexed: (none) — *lifecycle/optional* — one-time wiring of furnace/universalForge/treasury/holderVault.

**Key instructions (entrypoints):** `register` (`PositionLocked`); `collect`
(`FeesCollected`, then the distribution events via `_distribute`: `TollPaid`,
`ProtocolFeePaid`, `HolderRewardsAccrued`, `ProjectBurnRouted` /
`ProjectBurnUnrouted`, `TokenFeesBurned`, `CreatorPaid` / `CreatorPayFailed`);
`claim` (`FeesClaimed`); `setPayout` (`PayoutSet`); `initialize` (`Initialized`).

### TollyForgeDeployer — `0x04b8a7aeafce846acd3838ad5961787810339db1`

- `ForgeDeployed(address,address,address,address)` — `0xa1099a899ff13af419d3d22fd38e83e74f1b92479ccf78c0a9e1e5a51907bf51` — indexed: `forge`, `launchRegistry`, `locker` — a launchpad Forge was deployed (4th arg: the deploying account). **No instances on Arc mainnet.**

**Key instructions (entrypoints):** `deployForge` (`ForgeDeployed`); `initialize`
and `registerTool` emit nothing.

### TollyUniversalForge — `0x6619d00e448664ac900f1f512a5b65e8ac358a7b`

- `UniversalBurnerCreated(address,address,address,address)` — `0x5bbc175109b7c2db003294f27b1954efc0652dbe873230f057162debe12c3f1b` — indexed: `token`, `burner`, `launchLocker` — a per-token `TollyBurner` was created (4th arg: creator).
- `DcaTreasuryCreated(address,address,address,address)` — `0xd5ad1310d376f75343ba798dc7c49d1cd00bca9121a2919480b06cd9ce1e8a7c` — indexed: `token`, `treasury`, `owner` — a per-token `TollyDcaTreasury` was created (4th arg: launchLocker).

**Key instructions (entrypoints):** `createUniversalBurner`
(`UniversalBurnerCreated`); `createDcaTreasury` (`DcaTreasuryCreated`).

### TollyRouterForge — `0xb808e78846205905607a425b329f0bcf8e036fab`

- `RouterCreated(address,address,address,address)` — `0xe8e811674d167b407a67a22f592a226ade5e34b608e7d56721f82422f3b98197` — indexed: `token`, `routerContract`, `owner` — a per-token `TollyRevenueRouter` was created (4th arg: launchLocker).

**Key instructions (entrypoints):** `createRouter` (`RouterCreated`).

### TollyLiquidityForgeFactory — `0xd988b525960bf069cd2ef869642b8c2a26065cc0`

- `LiquidityForgeCreated(address,address,address)` — `0xe0e07ca532345f06e4f01b778c2f5b424a8d45a88fea9dfa6c7863fc4ff7ceab` — indexed: `token`, `forge` — a per-token `TollyLiquidityForge` was created (3rd arg: launchLocker).

**Key instructions (entrypoints):** `createLiquidityForge`
(`LiquidityForgeCreated`).

### TollyRevenueRouter — per-creator instance (discover via `RouterCreated`)

- `RouterProcessed(address,uint256,uint256,uint256,uint256)` — `0x4cb92b9cd5d05218b622c19c56c4fa4a101f9e272a69247753ada6d9bbeb4d27` — indexed: `caller` — a fee-processing run: gross, toll, callerPay, distributable.
- `Allocated(uint8,address,uint256,uint256)` — `0xa8ad17aeb43f1b787a9fd4ebb36550ff3a0ef7257d1217719ca4735a815b5cfa` — indexed: `kind`, `dest` — one allocation slice was applied (`amountIn`, `tokensOut`); `kind` is the allocation type (e.g. buyback-burn / liquidity).
- `PrepaidDeposit(address,uint256)` — `0x235b3e4e963772af8b5b7f640b408e6402db0ed7efb9e31d1998df158ce9a059` — indexed: `source` — someone pre-funded the router's processing budget.
- `FeesClaimed(bool,uint256,uint256)` — `0x2076e4782d1b5fea11d0e0ccdf34d819a416e7ed238c6f26c7ecef6e2ec551a0` — indexed: (none) — the router claimed LP fees from its position (`success`, `amount0`, `amount1`).
- `AllocationsSet(uint256)` — `0xb470a061a328bedea790142ca3e477573b6337191c39704740003dc082e76ecf` — indexed: (none) — *lifecycle/optional* — allocation table (`count` entries) was set.
- `ConfigurationLocked()` — `0xbef561f5625d8eb2113c43376ffc838261b71b170b15f11fbcd01c39c1f32447` — indexed: (none) — *lifecycle/optional* — allocations locked; no further changes.

**Key instructions (entrypoints):** `processFees` (`RouterProcessed`,
`Allocated`, and `FeesClaimed` via `_claim`); `depositPrepaid`
(`PrepaidDeposit`); `setAllocations` (`AllocationsSet`); `lockAllocations`
(`ConfigurationLocked`).

### TollyLiquidityForge — per-creator instance (discover via `LiquidityForgeCreated`)

- `LiquidityAdded(address,bool,uint256,uint256,uint256)` — `0x68b801f03bfebda5fd0feb5e0889b22f097ae739d3af93a1c745caa1302d23b8` — indexed: `caller` — liquidity was added to the locked position (`tollFree`, `gross`, `toll`, `liquidityMinted`).
- `LpFeesCollected(uint256,uint256)` — `0x721528bc007a32c6eec1dffca9f89a9aab4c7a05c0c8ed56793ab33e0368f67f` — indexed: (none) — LP fees (`wethCollected`, `tokenCollected`) collected from the position.
- `LockExtended(uint256)` — `0x2d3b38a507b3fb0ee1aaa054f2d952d0ac517f18f1cba8857c1b0e2ed9d5dbd9` — indexed: (none) — the lock's unlock time was pushed out to `newUnlockTime`.
- `MadePermanent()` — `0x6a5fd4046631ca2a0a86f8d5bac9bab021ccc47b73b4e82c1cabd4531bd2096f` — indexed: (none) — the position lock was made permanent.
- `PositionWithdrawn(address,uint256)` — `0xc73cb9445bd4c612f5ab737521a91a974dc06cbb201b699d3a7958f4660c2cb7` — indexed: `to` — the LP position NFT (`positionId`) was withdrawn after unlock.
- `PrepaidDeposit(address,uint256)` — `0x235b3e4e963772af8b5b7f640b408e6402db0ed7efb9e31d1998df158ce9a059` — indexed: `source` — someone pre-funded processing budget.
- `FeesClaimed(bool,uint256,uint256)` — `0x2076e4782d1b5fea11d0e0ccdf34d819a416e7ed238c6f26c7ecef6e2ec551a0` — indexed: (none) — claimed launch-locker fees (`success`, `amount0`, `amount1`).

**Key instructions (entrypoints):** `addLiquidity` (`LiquidityAdded`);
`collectLpFees` (`LpFeesCollected`); `extendLock` (`LockExtended`);
`permanentLock` (`MadePermanent`); `withdrawPosition` (`PositionWithdrawn`);
`depositPrepaid` (`PrepaidDeposit`).

### TollyBurner — per-token instance (example `0x41bd155c88148f29081901809ac04d34b5e66b1d`)

- `Buyback(address,bool,uint256,uint256,uint256,uint256,uint256,uint256)` — `0xb356643683e6c5f3b039251ee70ed4235f50e8de8e301b6ddda9130252b4b5ca` — indexed: `caller` — a buyback+burn run (emergency flag, amount, toll, callerPay, swapAmount, bought, directBurn).
- `FeesClaimed(bool,uint256,uint256)` — `0x2076e4782d1b5fea11d0e0ccdf34d819a416e7ed238c6f26c7ecef6e2ec551a0` — indexed: (none) — claimed fees (`success`, `amount0`, `amount1`).
- `ParamsUpdated(uint256,uint256,uint256,uint256,uint256)` — `0x3004c51189ca28b9e3d1bfbc25fad1a40a49c68f6586da5b733459686020498b` — indexed: (none) — *lifecycle/optional* — buyback params (min/emergency weth, cooldown, gas refund, reward bps) changed.
- `ConfigurationLocked()` — `0xbef561f5625d8eb2113c43376ffc838261b71b170b15f11fbcd01c39c1f32447` — indexed: (none) — *lifecycle/optional* — config locked.
- `OwnershipTransferred(address,address)` — `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` — indexed: `from`, `to` — *lifecycle/optional* — burner ownership changed.

**Key instructions (entrypoints):** `triggerBuyback` / `emergencyBuyback`
(`Buyback`); `claimOnly` (`FeesClaimed`); `setParams` (`ParamsUpdated`);
`lockConfiguration` (`ConfigurationLocked`); `transferOwnership`
(`OwnershipTransferred`).

### TollyDcaTreasury — per-creator instance (discover via `DcaTreasuryCreated`)

- `DcaExecuted(address,uint256,uint256,uint256,uint256,uint256)` — `0xa6cc369c95bdd2110d3a99d8714590c1cd6a2f49e798bc2812a0fede74011bb9` — indexed: `caller` — a scheduled DCA run (gross, toll, bought, burned, toTreasury).
- `PrepaidDeposit(address,uint256)` — `0x235b3e4e963772af8b5b7f640b408e6402db0ed7efb9e31d1998df158ce9a059` — indexed: `source` — processing budget pre-funded.
- `FeesClaimed(bool,uint256,uint256)` — `0x2076e4782d1b5fea11d0e0ccdf34d819a416e7ed238c6f26c7ecef6e2ec551a0` — indexed: (none) — claimed fees (`success`, `amount0`, `amount1`).
- `StrategySet(uint8,address,uint16)` — `0x8894c05afafa563dc3df83dbd186d1f37010d11caaafd2883a270e3f4735180f` — indexed: (none) — *lifecycle/optional* — mode/treasuryDest/splitBurnBps set.
- `ScheduleSet(uint256,uint256)` — `0xd8179cfaa4e56e945d19fd6948ac104586941ad537148edb3d30f93eee02cf7f` — indexed: (none) — *lifecycle/optional* — interval and maxBatchWeth set.
- `StrategyLocked()` — `0xb5dab917f78d4070a504f435af0ecc88b755140d1999e1214d74f4168a7a796e` — indexed: (none) — *lifecycle/optional* — strategy locked.

**Key instructions (entrypoints):** `executeDca` (`DcaExecuted`); `depositPrepaid`
(`PrepaidDeposit`); `setStrategy` (`StrategySet`); `setSchedule` (`ScheduleSet`);
`lockStrategy` (`StrategyLocked`); `claimOnly` (`FeesClaimed`).

### TollyFurnace — `0xe60483df8bb33dbe7c50c47b440e957eb65614c3`

- `TollDeposited(address,address,uint256)` — `0x9f570b58dba91f1f9f57cacf8f71964cd7db8e6ba480ab6aa4587b9fd924ec9b` — indexed: `project`, `tool` — a toll (in WETH) was banked into the furnace by a tool/router.
- `TollyBurned(address,uint256,uint256)` — `0x806ad81a507908cbf7e2df31af98ce0616e4d6676d2a1bf152ef15fb588c6f9c` — indexed: `caller` — banked WETH was spent buying and burning TOLLY (`wethSpent`, `tollyBurned`); also emitted by the piggyback auto-burn.

**Key instructions (entrypoints):** `depositToll` (`TollDeposited`);
`triggerTollyBurn` (`TollyBurned`, also via `_tryPiggybackBurn`).

### TollyForge — per-creator instance (discover via `ForgeDeployed`; none on mainnet)

- `BurnerCreated(address,address,address,address,uint256)` — `0xee59f2b669f8c6bb3763ca4331df30fab5c8e3723d3bea8df1265b8060257e57` — indexed: `token`, `burner`, `projectDeployer` — a launchpad Forge created a project `TollyBurner` (`creator`, `tollBps`).

**Key instructions (entrypoints):** `createBurner` (`BurnerCreated`).

### TollyMultiRouter — `0xf28c138a39c234554c847dbef467b073ddbd7451`

- `SwappedWithToll(address,address,address,uint256,uint256,uint256,uint8)` — `0xe681b3d369a9a022c0fceb9b70da2277b34962a3638f5cf7f2e5cb273ad30843` — indexed: `trader`, `tokenIn`, `tokenOut` — a swap through the router charging the interface toll (`amountIn`, `toll`, `amountOut`, `venue`: 3 = Uniswap V3, 2 = a V2 fork).

**Key instructions (entrypoints):** `swapWithToll` (V3, `venue=3`) and
`swapWithTollV2` (`venue=2`), both emit `SwappedWithToll`.

### TollySwapRouter — `0xcebc2e409a85cfa82b086674e6bc5bed51692777`

- `SwappedWithToll(address,address,address,uint256,uint256,uint256)` — `0x87c2abeefec6c5280aa91344c2517dd8e0ae7b7479f398396987c3cfdbc8e1fa` — indexed: `trader`, `tokenIn`, `tokenOut` — a V3 swap charging the interface toll (`amountIn`, `toll`, `amountOut`). **Note the different signature/topic0 from MultiRouter — no `venue` field.**

**Key instructions (entrypoints):** `swapWithToll` (`SwappedWithToll`).

### TollyTreasury — `0xa00c3a33bcb68856f9fd86003e17f76a733fc355`

- `Withdrawn(address,address,uint256)` — `0xd1c19fbcd4551a5edfb66d43d2e337c04837afda3482b42bdf569a8fccdae5fb` — indexed: `asset`, `to` — owner withdrew an ERC-20 (or native, `asset = address(0)`) from the treasury.
- `OwnershipTransferStarted(address,address)` — `0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700` — indexed: `from`, `to` — *lifecycle/optional* — two-step ownership handover started.
- `OwnershipTransferred(address,address)` — `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` — indexed: `from`, `to` — *lifecycle/optional* — ownership handover accepted.

**Key instructions (entrypoints):** `withdraw` / `withdrawNative` (`Withdrawn`);
`transferOwnership` (`OwnershipTransferStarted`); `acceptOwnership`
(`OwnershipTransferred`).

### TollyHolderVault — `0x150bf8f4087d50da1081365e4a28d7912045a8f4`

- `Accrued(address,address,uint256)` — `0x25963a1429417a86986b3c9b49e532b39cf61128506dbcd415f9f3420b10af30` — indexed: `project`, `asset` — a holder-reward accrual was booked into the per-project/per-asset ledger.
- `DistributorSet(address)` — `0x86719c518c7d99ac94b3d405d462ea876ba5cd0a978461dc9a7c9862a9485886` — indexed: `distributor` — *lifecycle/optional* — the distributor contract was set (once).
- `LockerSet(address)` — `0xef7ce00901486d0ae4bbe00a818eb6bb2f42bc78fc75571cf294c1c50c61adfd` — indexed: `locker` — *lifecycle/optional* — the fee-locker source was set.

**Key instructions (entrypoints):** `bookAccrual` (`Accrued`); `setDistributor`
(`DistributorSet`); `setLocker` (`LockerSet`); `releaseTo` moves booked funds and
emits nothing.

### TollyLens — `0xcb249e9613123ad57dc438d5393e471c00020959`

Read-only aggregator. **No events** — nothing to index; call its view functions
for composed reads.

## 4. Discovery flow

1. **Tokens & pools.** Index `TollyPad.TokenCreated` and `TollyPad.Launched` at
   the Pad. `TokenCreated` gives the token, creator, and metadata; `Launched`
   gives the pool address, `lpTokenId`, `liquidity`, and `tokenSeeded`.
2. **Launch LP lock.** `TollyFeeLocker.PositionLocked` ties each `lpTokenId` to
   its `launchedToken` and `creator`.
3. **Per-token tool instances.** Index the factory creation events and record
   the created address against its token:
   - `TollyForgeDeployer.ForgeDeployed` → launchpad Forge (none on mainnet).
   - `TollyRouterForge.RouterCreated` → `TollyRevenueRouter`.
   - `TollyLiquidityForgeFactory.LiquidityForgeCreated` → `TollyLiquidityForge`.
   - `TollyUniversalForge.DcaTreasuryCreated` → `TollyDcaTreasury`.
   - `TollyUniversalForge.UniversalBurnerCreated` → `TollyBurner`.
   - `TollyForge.BurnerCreated` → `TollyBurner` (created by a launchpad Forge).
4. **Attach class ABIs.** For each discovered instance address, subscribe with
   the matching class ABI ([`abis/`](abis/)) and index its own events (§3).
5. **Balances & holders.** Index `TollyToken.Transfer` per launched token.

## 5. Notes

- **The two routers differ.** `TollySwapRouter.SwappedWithToll` has **no
  `venue`** field (topic0 `0x87c2abee…`); `TollyMultiRouter.SwappedWithToll`
  adds a trailing `uint8 venue` (3 = Uniswap V3, 2 = a V2 fork) and therefore
  has a **different topic0** (`0xe681b3d3…`). They are distinct events — do not
  share a decoder.
- **Prices come from the pool, not the router.** `SwappedWithToll` is the
  interface-fee wrapper: it records the toll and the router's in/out amounts. The
  authoritative executed price is in the underlying Uniswap **V3/V2 pool `Swap`
  events**, which are standard Uniswap contracts and are **not part of this
  repo** (no ABI shipped here). Index those pools directly (the pool address
  comes from `TollyPad.Launched`) for trade pricing and volume.
- Several tool contracts share identical event signatures — e.g.
  `FeesClaimed(bool,uint256,uint256)` (topic0 `0x2076e478…`) and
  `PrepaidDeposit(address,uint256)` (topic0 `0x235b3e4e…`) appear on
  `TollyRevenueRouter`, `TollyLiquidityForge`, and `TollyDcaTreasury`, and
  `ConfigurationLocked()` (topic0 `0xbef561f5…`) on both `TollyRevenueRouter` and
  `TollyBurner`. Disambiguate by emitting **address**, not topic0 alone.
