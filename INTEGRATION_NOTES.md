# Tolly V3 - Integration notes

For data partners (indexers, aggregators, explorers) integrating TOLLY on Arc
mainnet (chainId 5042). Read this with `INDEXING.md` (events and entrypoints),
`abis/` (per-contract ABIs) and `deployment/arc-mainnet-5042.json` (the 14
deployed addresses).

## Is it a fork?

No. The launchpad and its tooling (`TollyPad`, `TollyForge` and its tool family,
`TollyFeeLocker`, the routers, `TollyLens`, `TollyToken`, `TollyTreasury`,
`TollyHolderVault`) are original TollyLabs contracts, not a rebrand of pump.fun,
a Uniswap fork, or any existing template.

It builds on standard Uniswap: every launched token trades in a normal
**Uniswap V3** pool (1% fee tier) against USDC. Some tokens also trade in
**Uniswap V2**-fork pools (via the multi-router) and **Uniswap V4** pools (some
external / pools.trade tokens). So your existing Uniswap V3 / V2 / V4 pool
decoders apply directly to the pools; only the launchpad and fee/tool contracts
are bespoke and need the ABIs in `abis/`.

The only vendored third-party code is two math libraries adapted from Uniswap
v3-core, `TickMath` (GPL-2.0-or-later) and `FullMath` (MIT), both attributed in
`NOTICE.md`, plus OpenZeppelin Contracts 5.6.1 (MIT). Those are libraries, not a
protocol fork.

## Liquidity locking

Native and permanent. Every launch mints 100% of supply as single-sided
liquidity locked in `TollyFeeLocker` (`0xe20e4297759597da75c8998ee76ec900600ad920`).
The locker holds the Uniswap V3 LP NFT forever: no withdraw, `decreaseLiquidity`
or transfer path, no unlock date, no team allocation. Treat a position owned by
that address as permanently locked, 100%, no expiry. Attribute it from
`TollyPad.Launched(token, pool, lpTokenId, ...)` or
`TollyFeeLocker.PositionLocked(tokenId, launchedToken, creator)`. The locker only
ever collects and splits fees; it never releases principal.

## Critical facts and non-standard behaviour

Ordered by how badly they break an integration if missed.

1. **USDC decimals (most important).** On Arc, USDC is the native gas token and
   also has a canonical ERC-20 view at `0x3600000000000000000000000000000000000000`
   whose `decimals()` is **6**. The V3 pools quote against that 6-decimal view.
   Some Uniswap V4 pools quote against the **native** currency (`address(0)`),
   which is **18** decimals. Same money, two units. Read `decimals()` per asset;
   never assume a global 6 or 18. Mixing them is a 1e12 price/volume error.

2. **Clamp `slot0` to the pool's tick range or you will publish garbage market
   caps.** Each token is single-sided liquidity across a deliberately wide range
   (ceiling on the order of $2.5T FDV by design, so tokens never pin to it). If a
   token's price runs above its range, `slot0` walks to the extreme tick and
   reads an absurd price (up to ~1e53 USD). Clamp displayed price and market cap
   to the pool's initialized tick range. Nothing on-chain clamps it for you.

3. **Normal Uniswap V3 pool from block one.** No bonding curve, no graduation.
   Launch opens near $5,000 FDV; standard V3 pricing works immediately.
   Circulating supply starts near zero and grows as buyers pull tokens out of the
   locked LP, so do not treat `totalSupply` as circulating.

4. **Price from the pool, not the routers.** The routers (`TollySwapRouter`,
   `TollyMultiRouter`, `TollyV4Router`) wrap swaps and emit `SwappedWithToll`, but
   that output is net of a 0.2% interface fee charged on external-token buys only.
   Take true price and volume from the underlying pool `Swap` events. Note the two
   router event signatures differ: `TollySwapRouter` emits a six-field form with
   no `venue`; `TollyMultiRouter` / `TollyV4Router` emit a seven-field form with a
   `venue` code (2 = V2, 3 = V3, 4 = V4). Different topic0 hashes; both are in
   `INDEXING.md`.

5. **Fee collection burns supply.** The 1% pool fee accrues to the locked LP;
   anyone can call `TollyFeeLocker.collect()`, which splits the USDC side five
   ways and burns 100% of the token side to `0x...dEaD` (`TokenFeesBurned`).
   Separately, 9% of the USDC fee buys the TOLLY token and burns it. So per-token
   supply drops over time, and TOLLY has constant buy-and-burn pressure.

6. **Per-token tool contracts have no fixed addresses.** Buyback burners, revenue
   routers, liquidity forges and DCA treasuries are created per token or creator
   and must be discovered via the factory creation events (see the discovery flow
   in `INDEXING.md`), then indexed with the class ABIs.

7. **V4 pools live in a singleton PoolManager**
   (`0x8366a39cc670b4001a1121b8f6a443a643e40951`); there is no per-pool token
   balance to read. Pool state is read by slot via `extsload`. If you do not index
   V4 yet, you still get every native TOLLY launch from the V3 path.

8. **Launch quirks.** A launch can include an atomic creator dev-buy in the same
   transaction (`DevBuy`), so a token's first trade is often in its creation tx.
   Tokens also enforce a short anti-snipe window with a per-wallet cap at launch,
   so some early transfers are restricted.

## How to QA the data

Public, no auth. Base URL `https://api.tollylabs.com`.

| Endpoint | Returns |
|---|---|
| `GET /health` | Chain id, indexer head and lag. Root keys `ok, chainId, pad, indexing`; the indexing fields are nested under `indexing`. |
| `GET /tokens?scope=all&limit=50` | Token list with `price`, `marketCap`, `liquidity`, `volume24h`, `change1h/4h/6h/24h`, `image_uri`, `pool`. Best single source to reconcile market data. `change4h` is not guaranteed. |
| `GET /tokens?q=<address>&scope=all` | One token by address. `scope=all` is required for external tokens; without it an external address returns zero rows. |
| `GET /token/<address>` | Metadata, pool, socials. On production take live price/mcap from `/tokens`. |
| `GET /candles?token=<address>&tf=<1m..1d>` | OHLCV; `volume` is USD; `bucket` is epoch seconds. |
| `GET /holders?token=<address>` | `count`, `top10Share`, `circulating`, plus the top holder list. |
| `GET /swaps?token=<address>&limit=50` | Recent trades, USD-valued. |

Frontend (per-token page shows price, market cap, liquidity, chart):
`https://tollylabs.com/token/<address>`. Block explorer: `https://arc-scan.org`.

For historical backfill, bootstrap from the API (`GET /tokens?scope=all`
enumerates every token) and coordinate a dedicated archive RPC with the TOLLY
team. The public relay `https://api.tollylabs.com/rpc` is for bounded QA only and
must not be used for bulk backfill; it shares limited capacity with production.

A good first reconciliation: pull `/tokens?scope=all`, take a token's `pool`,
index that pool's Uniswap V3 `Swap` events directly, and confirm your derived
price matches, remembering USDC is 6 decimals and the token is 18.
