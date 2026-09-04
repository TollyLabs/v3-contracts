// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 TollyLabs
pragma solidity ^0.8.24;

/**
 * @title TollyForge
 * @notice Buy-and-burn infrastructure for TOLLY, plus the creator tools that
 *         feed it, deployable against any compatible launchpad without
 *         modification.
 *
 * @dev NO ORACLE, BY CHOICE. Nothing here reads a price feed. Burns are
 *      denominated in the quote asset and sized against pool liquidity, so
 *      the protocol takes no dependency on a third party staying online, and
 *      there is no feed to be stale, manipulated, or discontinued.
 *
 *      THE QUOTE ASSET IS NAMED `weth` THROUGHOUT, which is historical: it is
 *      whatever ERC-20 the deployment is configured with, and on a chain whose
 *      native asset is a dollar it is that. Read every `weth` identifier as
 *      "the quote asset".
 *
 *      Defined in this file:
 *      - SafeT, FullMath, PoolMath: transfer, 512-bit arithmetic, and
 *        constant-product/tick helpers.
 *      - TollyFurnace: receives the toll, pools it, and permissionlessly buys
 *        and burns TOLLY once a threshold is reached.
 *      - TollyBurner: per-project fee receiver. Self-claims launchpad creator
 *        fees, burns the project-token side directly, swaps the quote side for
 *        the project token on Uniswap V3, and burns that too.
 *      - TollyForge: per-launchpad factory and registry of official burners.
 *      - TollyForgeDeployer: meta-factory. Wires up a new V3-locker-family
 *        launchpad in one transaction, with no admin and no approval step;
 *        every Forge it deploys is on-chain-provably official.
 *      - TollyUniversalForge: burners for a token with no compatible
 *        launchpad behind it.
 *      - TollyRevenueRouter, TollyLiquidityForge, TollyDcaTreasury and their
 *        factories (TollyRouterForge, TollyLiquidityForgeFactory): the
 *        creator tools a project points its fee receiver at, each taking the
 *        same toll on the way past.
 *
 *      Invariants enforced here:
 *      - TOLL_BPS = 100 is a constant in every tool: 1% OF THE FEES A PROJECT
 *        REDIRECTS INTO ONE, never of its volume, its supply or its transfers.
 *        No owner, no governance, no way to change it.
 *      - 100% of that toll buys and burns TOLLY. Executor pay is computed
 *        after the toll is taken, so it comes out of the project's 99%.
 *      - The TOLLY token's own burner pays no toll, set by the factory in
 *        code rather than by configuration.
 *      - No transfer taxes anywhere. The toll applies only when a project's
 *        fees are processed by a tool.
 *      - One burner per project token, so a broken or malicious token cannot
 *        affect other projects, the Furnace pool, or TOLLY.
 *
 *      Target launchpad family ("V3-locker" family, launchpad-agnostic): any
 *      launchpad that (a) creates a Uniswap V3 pool at launch and locks the
 *      LP position in a locker contract, (b) pays creator fees as claimable
 *      V3 LP fees via locker.collectFees(token), and (c) exposes a launch
 *      registry with getLaunchedToken(token). One template covers every
 *      launchpad matching that interface, each wired up permissionlessly
 *      through TollyForgeDeployer.
 *      - Fees are claimed via locker.collectFees(token); the current fee
 *        recipient is an authorized caller, so the burner self-claims.
 *        Hardcoded, no arbitrary calldata.
 *      - Fees arrive as two ERC-20s: the quote asset and the project token.
 *        The launchpad takes its cut inside collectFees, so the burner
 *        receives net amounts.
 *      - The launch's pool fee tier and paired token are read from the
 *        registry at burner creation.
 */

// ---------------------------------------------------------------------------
// External interfaces
// ---------------------------------------------------------------------------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Uniswap SwapRouter02, whose address is supplied per deployment.
///      SwapRouter02's ExactInputSingleParams has no deadline field, unlike
///      the classic V3 SwapRouter, which is why this interface is declared
///      here rather than imported.
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface ILaunchLocker {
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
}

/// @dev Canonical WETH deposit, used to wrap native-ETH fee payouts. Some
///      launchpad fee routers unwrap WETH and push native ETH to the fee
///      receiver (verified on-chain against a live family-1 dialect), so an
///      agnostic burner must accept ETH and wrap it before processing.
interface IWETH9Min {
    function deposit() external payable;
}

/// @dev Uniswap V3 NonfungiblePositionManager; the LP position is a
///      `UNI-V3-POS` NFT. The Liquidity Forge mints a full-range position and
///      holds it forever: the absence of a withdraw path is what makes the
///      lock permanent, the same pattern used elsewhere on the chain.
interface INonfungiblePositionManagerMin {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function mint(MintParams calldata) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce, address operator, address token0, address token1, uint24 fee,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 f0, uint256 f1, uint128 owed0, uint128 owed1
        );
}

interface ILaunchRegistry {
    /// @dev Field order verified against the reference launchpad's source.
    ///      Verify against the explorer ABI before any mainnet deploy.
    struct LaunchedToken {
        address token;
        address deployer;
        address pairedToken;
        address positionManager;
        uint256 positionId;
        uint256 dexId;
        uint256 launchConfigId;
        uint256 restrictionsEndBlock;
        uint256 supply;
        bool isToken0;
        uint24 poolFee;
        bool exists;
        uint256 initialBuyAmount;
    }
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

/// @dev Minimal Uniswap V3 pool surface used for impact-sizing and the TWAP guard.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);
    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
}

/// @dev Registry hook allowing a Forge to record its burners as globally
///      official on the shared Deployer in O(1), replacing an unbounded
///      on-chain loop.
interface ITollyToolRegistry {
    function registerTool(address tool) external;
    /// @notice The single authenticated answer to "which pool is this token's".
    ///         Every consumer that binds a pool goes through it, including this
    ///         per-launchpad Forge, whose own registry is caller-supplied.
    function resolveAuthenticatedPool(address token, address quote) external view returns (address pool, uint24 fee);
    /// @notice Per-deployment values in raw base-asset units. See the note on
    ///         TollyForgeDeployer: these are amounts of money, not scales.
    function minProcessBase() external view returns (uint256);
    function gasRefundBase() external view returns (uint256);
    function nativeIsQuote() external view returns (bool);
}

/// @author TollyLabs
/// @notice ERC-20 transfers that tolerate non-standard tokens (no return
///         value, or a return value that is not a bool, e.g. USDT-style).
///         Reverts on failure.
library SafeT {
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "token transfer failed");
    }

    function safeTransfer(IERC20 t, address to, uint256 a) internal {
        _call(address(t), abi.encodeWithSelector(t.transfer.selector, to, a));
    }

    function safeTransferFrom(IERC20 t, address from, address to, uint256 a) internal {
        _call(address(t), abi.encodeWithSelector(t.transferFrom.selector, from, to, a));
    }
}

/// @notice 512-bit muldiv (Remco Bloemen, MIT), verbatim from Uniswap v3.
///         Required so the TWAP quote never phantom-overflows on extreme
///         memecoin/WETH price ratios.
/// @dev    This FullMath section is excluded from the BUSL Licensed Work and
///         remains available under the MIT License. Copyright (c) 2021
///         Remco Bloemen. See NOTICE.md and LICENSES/MIT.txt.
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            require(denominator > prod1);
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = (0 - denominator) & denominator;
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }
}

/// @author TollyLabs
/// @notice Uniswap V3 liquidity-aware helpers, shared by the Furnace and every
///         Burner. Sizes a buy to a target price impact and quotes the
///         expected output from the live price, both derived from the pool's
///         own L and sqrt(P), so they scale with liquidity and require no USD
///         oracle. The protocol is denominated in WETH and pool liquidity by
///         design: sizing against the pool the swap executes in needs no
///         external price, and adding one would only introduce a trusted,
///         staleable dependency.
library PoolMath {
    uint256 private constant Q96 = 0x1000000000000000000000000;

    /// @dev Maximum amount of the other token that can be swapped in so the
    ///      price moves by at most `impactBps`. `targetIsToken0` indicates the
    ///      token being bought is token0.
    ///      V3: Δtoken1 = L·Δ√P ; Δtoken0 = L·Δ(1/√P).
    function maxImpactIn(address pool, bool targetIsToken0, uint256 impactBps) internal view returns (uint256) {
        uint128 L = IUniswapV3Pool(pool).liquidity();
        if (L == 0) return 0;
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 sp = uint256(sqrtP);
        if (targetIsToken0) {
            // Buying token0 with token1: Δtoken1 = L·√P·(impact/2)/Q96.
            return FullMath.mulDiv(FullMath.mulDiv(L, sp, Q96), impactBps, 20_000);
        } else {
            // Buying token1 with token0: Δtoken0 = L·(impact/2)·Q96/√P.
            return FullMath.mulDiv(FullMath.mulDiv(L, Q96, sp), impactBps, 20_000);
        }
    }

    /// @dev Expected target-token output for `amountIn` of the other token, at
    ///      the current spot price.
    function spotOut(address pool, bool targetIsToken0, uint256 amountIn) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 sp = uint256(sqrtP);
        if (targetIsToken0) {
            return FullMath.mulDiv(FullMath.mulDiv(amountIn, Q96, sp), Q96, sp);
        } else {
            return FullMath.mulDiv(FullMath.mulDiv(amountIn, sp, Q96), sp, Q96);
        }
    }
}

// ---------------------------------------------------------------------------
// TollyFurnace: standalone, launchpad-agnostic, no admin, no registry
// ---------------------------------------------------------------------------

/// @notice Resolves the pool an EXTERNAL token may bind, and says whether it
///         vouches for it. Two returns, not one: a non-zero address must never
///         be read as authority on its own, so `authenticated` carries the claim
///         and the address carries only the answer.
/// @dev    Implemented for mainnet v1 by a governed registry. A later
///         proof-of-authority resolver can replace it without the consumers
///         changing, which is why the boundary is an interface and not a
///         mapping read.
/// Read off a candidate pool to check it against the factory.
interface IUniswapV3PoolFee {
    function fee() external view returns (uint24);
}

interface IExternalPoolResolver {
    function resolvePool(address token, address quote) external view returns (address pool, bool authenticated);
}

/// The pad's own record, reached through immutables the protocol set and nobody
/// else can write: deployer.locker -> locker.pad -> pad.tokens.
interface ILockerPad { function pad() external view returns (address); }
interface IPadTokens { function tokens(address) external view returns (address creator, address pool, uint256 lpTokenId); }

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @author TollyLabs
contract TollyFurnace {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable weth;
    IERC20 public immutable tolly;
    ISwapRouterV3 public immutable router;
    uint24 public immutable tollyPoolFee;
    /// @notice The WETH/TOLLY V3 pool and its token ordering, used for impact
    ///         sizing and a manipulation-resistant minTollyOut.
    address public immutable tollyPool;
    bool public immutable tollyIsToken0;

    /// @notice Burn cadence and sizing, all constants, unchangeable by anyone.
    ///         Denominated in WETH and pool liquidity; no USD oracle is needed
    ///         to size against a pool. The batch is sized to the pool's live
    ///         liquidity so a single burn moves the price by at most
    ///         ~MAX_IMPACT_BPS: scale-invariant and launchpad-agnostic,
    ///         burning small amounts on a shallow launch pool and larger
    ///         amounts once TOLLY grows, with zero tuning required, and always
    ///         inside the slippage floor.
    uint256 public constant BURN_COOLDOWN = 60;           // 1 min, enough to stop same-block
                                                          // amplification; impact-sizing bounds each burn
    uint256 public constant MAX_IMPACT_BPS = 200;         // a burn moves price <= ~2%
    uint256 public constant BURN_SLIPPAGE_BPS = 500;      // 5% amountOutMinimum floor

    /// @notice Skips tiny, unnecessary burns. Relative, not a fixed WETH/USD
    ///         amount, so nothing freezes in an immutable contract: a burn
    ///         only fires once the pooled WETH is at least MIN_FILL_BPS of a
    ///         full impact-sized burn. Scales with the pool, so a burn is
    ///         meaningful at any depth, and tolls simply accumulate until
    ///         firing is worthwhile.
    uint256 public constant MIN_FILL_BPS = 2500;          // 25% of a full impact burn

    /// @notice Optional wide manipulation check. Applies only when the pool
    ///         has a real TWAP (cardinality >= 2 and >= TWAP_MIN_WINDOW of
    ///         history). It does not block on normal memecoin volatility,
    ///         only on gross (>~20%) deviation. When no TWAP exists (a fresh
    ///         or shallow pool) the check is skipped, so burns are never
    ///         stuck waiting for a warm-up. Impact sizing and the slippage
    ///         floor are the primary protection; this is cheap extra
    ///         insurance on deep, warmed pools.
    uint32 public constant TWAP_MAX_WINDOW = 1800;         // consult up to 30 min
    uint32 public constant TWAP_MIN_WINDOW = 300;          // ignore < 5 min of history
    int24 public constant MAX_TWAP_DEVIATION_TICKS = 2000; // ~22% gross-manip band
    uint256 private constant _BPS = 10_000;
    uint256 private constant _Q96 = 0x1000000000000000000000000;

    uint256 public lastBurn;

    // Ecosystem stats, read by the dashboard alongside the emitted events.
    uint256 public totalWethCollected;
    uint256 public totalTollyBurned;
    mapping(address => uint256) public projectContribution; // project token -> WETH tolls

    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    event TollDeposited(address indexed project, address indexed tool, uint256 wethAmount);
    event TollyBurned(address indexed caller, uint256 wethSpent, uint256 tollyBurned);

    /// @param _v3Factory Uniswap V3 factory, used only at deploy time to prove
    ///        the WETH/TOLLY pool exists at `_tollyPoolFee`. A wrong fee tier
    ///        would otherwise create a furnace that can never burn (the swap
    ///        try/catch would silently pool tolls forever), a fault that is
    ///        fatal and irreparable in an immutable contract, so the
    ///        constructor refuses to deploy in that case.
    constructor(
        address _weth,
        address _tolly,
        address _router,
        uint24 _tollyPoolFee,
        address _v3Factory
    ) {
        require(_weth != address(0) && _tolly != address(0) && _router != address(0), "zero address");
        address pool = IUniswapV3FactoryMinimal(_v3Factory).getPool(_weth, _tolly, _tollyPoolFee);
        require(pool != address(0), "protocol pool not found at fee tier");
        weth = IERC20(_weth);
        tolly = IERC20(_tolly);
        router = ISwapRouterV3(_router);
        tollyPoolFee = _tollyPoolFee;
        tollyPool = pool;
        tollyIsToken0 = IUniswapV3Pool(pool).token0() == _tolly;
        IERC20(_weth).approve(_router, type(uint256).max);
    }

    /// @notice Permissionless deposit. The furnace only knows how to buy TOLLY
    ///         and burn it to DEAD, so feeding it is a donation, never an
    ///         attack vector. This is what makes the furnace launchpad-
    ///         agnostic: any Forge on any launchpad, or any third party, can
    ///         feed it.
    /// @dev    Attribution caveat: `project`/`tool` in TollDeposited are
    ///         caller-supplied, so dashboards and leaderboards must filter by
    ///         known official `tool` addresses, and totalWethCollected reads
    ///         as "total WETH burned through the furnace", not "protocol
    ///         tolls". Auto-attempts a pooled burn when ready; a failed burn
    ///         never blocks the deposit.
    function depositToll(address project, uint256 amount) external nonReentrant {
        require(amount > 0, "zero toll");
        SafeT.safeTransferFrom(weth, msg.sender, address(this), amount);

        totalWethCollected += amount;
        projectContribution[project] += amount;
        emit TollDeposited(project, msg.sender, amount);

        // Piggyback burn attempt, sized to the pool's liquidity so it never
        // stalls. If the pool is grossly manipulated or the swap cannot fill,
        // the burn is skipped (tolls stay pooled); it never reverts the deposit.
        if (block.timestamp >= lastBurn + BURN_COOLDOWN) {
            uint256 amt = _worthAutoBurn(); // auto-burn only when it is a meaningful fill
            if (amt > 0) {
                _tryPiggybackBurn(amt);
            }
        }
    }

    /// @notice Anyone can trigger a pooled TOLLY burn. The batch is sized to
    ///         the pool's liquidity (<= ~2% price impact) and a spot-based
    ///         slippage floor is always enforced; `minTollyOut` can only
    ///         tighten it, so 0 is safe. Reverts only if there is nothing
    ///         worth burning or the pool is grossly (>~20%) manipulated
    ///         relative to its TWAP.
    function triggerTollyBurn(uint256 minTollyOut) external nonReentrant {
        require(block.timestamp >= lastBurn + BURN_COOLDOWN, "cooldown");
        uint256 amount = _burnAmount(); // no fill gate: a keeper can always drain
        require(amount > 0, "nothing to burn");

        (uint256 spotMin, bool ok) = _quote(amount);
        require(ok, "pool grossly manipulated");
        uint256 minOut = spotMin > minTollyOut ? spotMin : minTollyOut;

        lastBurn = block.timestamp;
        uint256 before = tolly.balanceOf(DEAD);
        // No try/catch: a slippage revert should bubble up so lastBurn is
        // rolled back and the caller is not charged the cooldown for a failed
        // burn.
        router.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(tolly),
                fee: tollyPoolFee,
                recipient: DEAD,
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 burned = tolly.balanceOf(DEAD) - before;
        totalTollyBurned += burned;
        emit TollyBurned(msg.sender, amount, burned);
    }

    /// @dev Quote that can never revert. Wraps `_quote` in an external
    ///      try/catch so even an overflow on an extreme price ratio degrades
    ///      to "skip the burn" instead of bubbling up. Used by the paths that
    ///      must not revert: the piggyback deposit, and the `canBurn` view.
    function _quoteSafe(uint256 wethAmount) internal view returns (uint256 minOut, bool ok) {
        try this.quotePreview(wethAmount) returns (uint256 m, bool k) {
            return (m, k);
        } catch {
            return (0, false);
        }
    }

    /// @dev Piggyback path: must never revert its caller (a toll deposit).
    function _tryPiggybackBurn(uint256 wethAmount) internal {
        (uint256 minOut, bool ok) = _quoteSafe(wethAmount);
        if (!ok) return; // pool volatile, TWAP not ready, or quote overflow: skip
        lastBurn = block.timestamp;
        uint256 before = tolly.balanceOf(DEAD);
        try router.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(tolly),
                fee: tollyPoolFee,
                recipient: DEAD,
                amountIn: wethAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256) {
            uint256 burned = tolly.balanceOf(DEAD) - before;
            totalTollyBurned += burned;
            emit TollyBurned(msg.sender, wethAmount, burned);
        } catch {
            // Swap route temporarily unavailable; tolls stay pooled and are
            // retried later.
        }
    }

    /// @dev How far back the pool can actually be consulted right now, capped
    ///      at TWAP_MAX_WINDOW. Reads the age of the oldest stored observation
    ///      (Uniswap's getOldestObservationSecondsAgo pattern) so observe() is
    ///      never asked for more history than exists, which would revert with
    ///      "OLD".
    function _achievableWindow() internal view returns (uint32) {
        (, , uint16 index, uint16 cardinality,,,) = IUniswapV3Pool(tollyPool).slot0();
        // Requires at least two observations for a real time-weighted average.
        // At cardinality 1 the pool holds a single point and observe() would
        // simply extrapolate it, which is not manipulation-resistant. A pool
        // is created at cardinality 1 unless someone pays to grow it, so this
        // forces the warm-up before any burn.
        if (cardinality < 2) return 0;

        // The oldest observation is the next slot after the current index
        // (ring buffer); if that slot is not yet initialised, slot 0 is the
        // oldest.
        (uint32 ts,,, bool init) = IUniswapV3Pool(tollyPool).observations((index + 1) % cardinality);
        if (!init) {
            (ts,,,) = IUniswapV3Pool(tollyPool).observations(0);
        }
        uint32 age = uint32(block.timestamp) - ts;
        return age > TWAP_MAX_WINDOW ? TWAP_MAX_WINDOW : age;
    }

    /// @dev WETH input that moves the pool price by at most MAX_IMPACT_BPS,
    ///      derived from the pool's live liquidity L and price (V3:
    ///      Δtoken1 = L·Δ√P, Δtoken0 = L·Δ(1/√P)). Scale-invariant and grows
    ///      with liquidity, so the burn is small on a thin launch pool and
    ///      large on a deep one, with no per-launchpad tuning required.
    function _maxImpactWethIn() internal view returns (uint256) {
        return PoolMath.maxImpactIn(tollyPool, tollyIsToken0, MAX_IMPACT_BPS);
    }

    /// @dev The WETH a burn spends now: the pooled balance, capped so the swap
    ///      moves price by at most ~MAX_IMPACT_BPS. No fill floor here; the
    ///      public triggerTollyBurn uses this, so a keeper can always drain
    ///      accumulated WETH regardless of pool size, and it never hoards on a
    ///      grown pool.
    function _burnAmount() internal view returns (uint256) {
        uint256 cap = _maxImpactWethIn();
        if (cap == 0) return 0;
        uint256 bal = weth.balanceOf(address(this));
        return bal < cap ? bal : cap;
    }

    /// @dev The automatic (piggyback) burn amount, or 0 when not yet worth
    ///      firing: pooled below MIN_FILL_BPS of a full impact burn. This
    ///      gates only the auto-burn, so automatic burns are always
    ///      meaningful and scale with the pool, while the keeper's
    ///      triggerTollyBurn (above) has no such gate, so a large pool can
    ///      never strand WETH. Relative, so nothing freezes.
    function _worthAutoBurn() internal view returns (uint256) {
        uint256 cap = _maxImpactWethIn();
        if (cap == 0) return 0;
        uint256 bal = weth.balanceOf(address(this));
        uint256 amount = bal < cap ? bal : cap;
        return amount >= (cap * MIN_FILL_BPS) / _BPS ? amount : 0;
    }

    /// @dev Expected TOLLY output for `wethAmount` and whether a burn is
    ///      allowed. minOut = spotQuote * (1 - slippage). `ok` is false only
    ///      on gross manipulation caught by the optional wide TWAP check
    ///      (deep, warmed pools); on a fresh or shallow pool with no TWAP, ok
    ///      stays true so burns can proceed. Impact sizing keeps the real
    ///      swap well inside the floor.
    function _quote(uint256 wethAmount) internal view returns (uint256 minOut, bool ok) {
        (, int24 spotTick,,,,,) = IUniswapV3Pool(tollyPool).slot0();
        uint256 expected = PoolMath.spotOut(tollyPool, tollyIsToken0, wethAmount);
        if (expected == 0) return (0, false);
        minOut = (expected * (_BPS - BURN_SLIPPAGE_BPS)) / _BPS;

        // Optional wide manipulation check, only when a real TWAP exists.
        // Never blocks on normal volatility; only catches gross (>~20%)
        // manipulation.
        uint32 window = _achievableWindow();
        if (window >= TWAP_MIN_WINDOW) {
            uint32[] memory ago = new uint32[](2);
            ago[0] = window;
            ago[1] = 0;
            try IUniswapV3Pool(tollyPool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
                int56 delta = cum[1] - cum[0];
                int24 avgTick = int24(delta / int56(uint56(window)));
                if (delta < 0 && (delta % int56(uint56(window)) != 0)) avgTick--;
                int24 dev = spotTick > avgTick ? spotTick - avgTick : avgTick - spotTick;
                if (dev > MAX_TWAP_DEVIATION_TICKS) return (minOut, false); // gross manipulation
            } catch {
                // TWAP glitch: do not block; sizing and the slippage floor
                // still protect the swap.
            }
        }
        ok = true;
    }

    /// @notice Preview the TWAP guard for a given WETH amount: the enforced
    ///         minTollyOut floor and whether a burn is currently allowed.
    ///         Allows keepers and dashboards to check before spending gas.
    function quotePreview(uint256 wethAmount) external view returns (uint256 minOut, bool ok) {
        return _quote(wethAmount);
    }

    /// @notice The most WETH a single burn will spend now (the
    ///         ~MAX_IMPACT_BPS cap derived from live pool liquidity). Auto-
    ///         burns fire once pooled WETH reaches MIN_FILL_BPS of this value.
    ///         Read by keepers and dashboards for sizing.
    function maxBurnWeth() external view returns (uint256) {
        return _maxImpactWethIn();
    }

    /// @notice True when an auto-burn is worth firing now: the cooldown has
    ///         passed, the pool is filled to a meaningful level, and the
    ///         manipulation guard passes. Serves as the keeper's trigger
    ///         signal for whether firing is worthwhile. Note: triggerTollyBurn
    ///         also works below this threshold (to drain a large pool); it is
    ///         simply not flagged as "worth it" here.
    function canBurn() external view returns (bool) {
        if (block.timestamp < lastBurn + BURN_COOLDOWN) return false;
        uint256 amount = _worthAutoBurn();
        if (amount == 0) return false;
        (, bool ok) = _quoteSafe(amount);
        return ok;
    }
}

// ---------------------------------------------------------------------------
// TollyBurner (per project)
// ---------------------------------------------------------------------------

/// @author TollyLabs
contract TollyBurner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;

    /// @notice The protocol toll. Hardcoded, not adjustable by anyone, ever.
    uint256 public constant TOLL_BPS = 100; // 1%

    uint256 public constant MAX_CALLER_REWARD_BPS = 300; // bounty hard cap 3%
    /// @notice Longest buyback cooldown an owner may set. Matches the Router's
    ///         own `cd <= 7 days` bound so the two tools cannot diverge on how
    ///         long a project's buyback can be stalled by configuration.
    uint256 public constant MAX_COOLDOWN = 7 days;
    uint256 public constant MAX_CALLER_PAY_BPS = 1_000;  // total caller pay <= 10% of project side

    // ---- Immutables (locked at creation, verified from the launchpad's own registry) ----
    IERC20 public immutable projectToken;
    IERC20 public immutable weth;
    ILaunchLocker public immutable locker;
    ISwapRouterV3 public immutable router;
    uint24 public immutable poolFee;          // the project pool's V3 fee tier
    address public immutable projectPool;     // the project's WETH V3 pool (for impact sizing)
    bool public immutable projectIsToken0;    // projectToken == pool.token0()
    TollyFurnace public immutable furnace;
    uint256 public immutable tollBps;         // TOLL_BPS, or 0 for TOLLY's own burner
    /// @notice See `TollyForgeDeployer.nativeIsQuote`.
    bool public immutable nativeIsQuote;

    /// @notice The per-buyback cap is not a fixed USD/WETH amount: it is sized
    ///         to the project pool's live liquidity so a buyback moves its
    ///         price by at most ~MAX_IMPACT_BPS (scale-invariant, no oracle).
    uint256 public constant MAX_IMPACT_BPS = 200;    // buyback moves price <= ~2%
    uint256 public constant BURN_SLIPPAGE_BPS = 500; // 5% swap floor

    // ---- Configuration (owner-adjustable until locked) ----
    address public owner;                     // the launch deployer (from the registry)
    bool public configurationLocked;

    // Per-deployment values, in raw base-asset units. These express an amount
    // of money, not a scale, so decimals alone cannot carry them across chains:
    // 0.01 ether rescaled by decimals is one cent where roughly $18 was meant.
    // Each must be set for the quote asset the deployment actually uses.
    uint256 public minBuybackWeth;               // min base accrued to trigger
    uint256 public emergencyWeth;                // emergency skips cooldown only
    uint256 public cooldown = 1800;              // 30 min
    uint256 public gasRefund;                    // fixed executor refund, raw base units
    uint256 public callerRewardBps = 100;        // +1% executor bounty

    uint256 public lastBuyback;

    uint256 private _lockedFlag = 1;
    modifier nonReentrant() {
        require(_lockedFlag == 1, "reentrancy");
        _lockedFlag = 2;
        _;
        _lockedFlag = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    event Buyback(
        address indexed caller,
        bool emergency,
        uint256 wethProcessed,
        uint256 tollPaid,
        uint256 callerPaid,
        uint256 wethSwapped,
        uint256 projectTokensBurned,
        uint256 directTokensBurned
    );
    event FeesClaimed(bool success, uint256 amount0, uint256 amount1);
    event ParamsUpdated(uint256 minBuybackWeth, uint256 emergencyWeth, uint256 cooldown, uint256 gasRefund, uint256 rewardBps);
    event ConfigurationLocked();
    event OwnershipTransferred(address indexed from, address indexed to);

    constructor(
        address _projectToken,
        address _weth,
        address _locker,
        address _router,
        uint24 _poolFee,
        address _projectPool,
        bool _projectIsToken0,
        address _furnace,
        uint256 _tollBps,
        address _owner,
        uint256 _minProcessBase,
        uint256 _gasRefundBase,
        bool _nativeIsQuote
    ) {
        nativeIsQuote = _nativeIsQuote;
        projectToken = IERC20(_projectToken);
        weth = IERC20(_weth);
        locker = ILaunchLocker(_locker);
        router = ISwapRouterV3(_router);
        poolFee = _poolFee;
        projectPool = _projectPool;
        projectIsToken0 = _projectIsToken0;
        furnace = TollyFurnace(_furnace);
        tollBps = _tollBps;
        owner = _owner;

        // Per-deployment VALUES in raw base units, not scales. The emergency
        // threshold keeps its original 50x relationship to the trigger (0.5 vs
        // 0.01 ether) instead of being a second literal to get wrong.
        require(_minProcessBase > 0, "min0");
        require(_gasRefundBase < _minProcessBase, "ref>min");
        minBuybackWeth = _minProcessBase;
        emergencyWeth = _minProcessBase * 50;
        gasRefund = _gasRefundBase;

        IERC20(_weth).approve(_router, type(uint256).max);
        IERC20(_weth).approve(_furnace, type(uint256).max);
    }

    /// @notice Agnostic by default: some launchpads pay the fee receiver in
    ///         native ETH (their fee router unwraps WETH before sending). The
    ///         burner accepts it here with an empty body so even 2300-gas
    ///         senders succeed, and `_process` wraps the balance into WETH
    ///         before the buyback, so incoming ETH is never trapped: its only
    ///         exit is the burn, same as WETH.
    receive() external payable {}

    // ------------------------------------------------------------------
    // Public triggers
    // ------------------------------------------------------------------

    /// @notice Normal public trigger: claim fees, burn the token side
    ///         directly, process at least $50 of WETH (capped at $250), pay
    ///         the executor from the project side, send the 1% toll to the
    ///         Furnace, then buy and burn.
    function triggerBuyback(uint256 minProjectOut) external nonReentrant {
        require(block.timestamp >= lastBuyback + cooldown, "cooldown");
        _process(minProjectOut, false);
    }

    /// @notice Emergency valve: usable only above $1,000 of accrued WETH.
    ///         Skips the cooldown only; the $250 per-trade cap still applies,
    ///         so draining a large backlog happens in repeated capped trades,
    ///         never one giant sandwich-able swap. Callable repeatedly by
    ///         anyone until drained.
    function emergencyBuyback(uint256 minProjectOut) external nonReentrant {
        _process(minProjectOut, true);
    }

    /// @notice Claim accrued launchpad fees without swapping. Useful for
    ///         verification, meeting deadlines, or when the swap route is
    ///         temporarily unavailable.
    function claimOnly() external nonReentrant {
        _claim();
    }

    // ------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------

    function _claim() internal returns (bool ok) {
        // Universal/push-only burners have no locker (address(0) or anything
        // codeless): fees arrive pushed, so there is nothing to self-claim.
        if (address(locker).code.length == 0) {
            emit FeesClaimed(false, 0, 0);
            return false;
        }
        try locker.collectFees(address(projectToken)) returns (uint256 a0, uint256 a1) {
            emit FeesClaimed(true, a0, a1);
            return true;
        } catch {
            // e.g. NoFeesToCollect: fine, process whatever already sits here.
            emit FeesClaimed(false, 0, 0);
            return false;
        }
    }

    function _process(uint256 minProjectOut, bool emergency) internal {
        // 1. Self-claim from the launchpad locker (hardcoded adapter; never bricks).
        _claim();

        // 2. The project-token half of the fees burns directly. No swap, no MEV.
        uint256 directBurn = projectToken.balanceOf(address(this));
        if (directBurn > 0) {
            SafeT.safeTransfer(projectToken, DEAD, directBurn);
        }

        // 3. Wrap any native-ETH payout (push-model launchpads) into WETH so
        //    everything downstream stays a single denomination.
        // Nothing to wrap where native and quote are the same asset.
        if (!nativeIsQuote) {
            uint256 nativeBal = address(this).balance;
            if (nativeBal > 0) IWETH9Min(address(weth)).deposit{value: nativeBal}();
        }

        //    Threshold check on the WETH half (denominated in WETH, no oracle).
        uint256 wethBal = weth.balanceOf(address(this));
        uint256 gateWei = emergency ? emergencyWeth : minBuybackWeth;
        require(wethBal >= gateWei, emergency ? "below emergency threshold" : "below min buyback");

        // Cap the buyback to ~MAX_IMPACT_BPS of the project pool's liquidity,
        // so a large backlog drains in impact-bounded chunks instead of one
        // giant swap.
        uint256 maxWei = PoolMath.maxImpactIn(projectPool, projectIsToken0, MAX_IMPACT_BPS);
        uint256 amount = wethBal > maxWei ? maxWei : wethBal;
        require(amount > 0, "no in-range pool liquidity"); // guards L==0 (dead pool)

        lastBuyback = block.timestamp;

        // 4. Exact 1% toll off the gross, straight into the Furnace. (The
        //    Furnace pulls via transferFrom and may piggyback a TOLLY burn.)
        uint256 toll = (amount * tollBps) / BPS;
        if (toll > 0) furnace.depositToll(address(projectToken), toll);

        // 5. Executor pay comes from the project side (never from the toll),
        //    hard-capped at 10% of it so bad settings cannot brick or drain
        //    the tool.
        uint256 projectSide = amount - toll;
        uint256 callerPay = gasRefund + (projectSide * callerRewardBps) / BPS;
        uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
        if (callerPay > maxPay) callerPay = maxPay;
        SafeT.safeTransfer(weth, msg.sender, callerPay);

        // 6. Swap the rest for the project token on its own V3 pool, output
        //    straight to the burn address. A spot-based slippage floor is
        //    always enforced (impact sizing keeps it clearable); `minProjectOut`
        //    can only tighten it, so passing 0 is safe.
        uint256 swapAmount = projectSide - callerPay;
        uint256 spotFloor = (PoolMath.spotOut(projectPool, projectIsToken0, swapAmount) * (BPS - BURN_SLIPPAGE_BPS)) / BPS;
        uint256 minOut = spotFloor > minProjectOut ? spotFloor : minProjectOut;
        uint256 before = projectToken.balanceOf(DEAD);
        router.exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(projectToken),
                fee: poolFee,
                recipient: DEAD,
                amountIn: swapAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        // `before` was read after the direct burn, so this delta is the swap
        // output only.
        uint256 bought = projectToken.balanceOf(DEAD) - before;

        emit Buyback(msg.sender, emergency, amount, toll, callerPay, swapAmount, bought, directBurn);
    }

    // ------------------------------------------------------------------
    // Views (for bots and the dashboard)
    // ------------------------------------------------------------------

    function canTrigger()
        external
        view
        returns (bool ready, uint256 wethAvailable, uint256 requiredWei, bool cooldownPassed)
    {
        // Native ETH counts: _process wraps it before the threshold check.
        wethAvailable = weth.balanceOf(address(this)) + address(this).balance;
        requiredWei = minBuybackWeth;
        cooldownPassed = block.timestamp >= lastBuyback + cooldown;
        ready = cooldownPassed && wethAvailable >= requiredWei;
    }

    function previewProcess()
        external
        view
        returns (uint256 processAmount, uint256 toll, uint256 callerPay, uint256 swapAmount, uint256 directBurn)
    {
        // Includes unwrapped native ETH: _process wraps it before sizing.
        uint256 wethBal = weth.balanceOf(address(this)) + address(this).balance;
        uint256 maxWei = PoolMath.maxImpactIn(projectPool, projectIsToken0, MAX_IMPACT_BPS);
        processAmount = wethBal > maxWei ? maxWei : wethBal;
        toll = (processAmount * tollBps) / BPS;
        uint256 projectSide = processAmount - toll;
        callerPay = gasRefund + (projectSide * callerRewardBps) / BPS;
        uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
        if (callerPay > maxPay) callerPay = maxPay;
        swapAmount = projectSide - callerPay;
        directBurn = projectToken.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Owner configuration (until locked)
    // ------------------------------------------------------------------

    function setParams(
        uint256 _minBuybackWeth,
        uint256 _emergencyWeth,
        uint256 _cooldown,
        uint256 _gasRefund,
        uint256 _callerRewardBps
    ) external onlyOwner {
        require(!configurationLocked, "locked");
        require(_minBuybackWeth > 0, "bad bounds");
        require(_emergencyWeth > _minBuybackWeth, "emergency too low");
        require(_callerRewardBps <= MAX_CALLER_REWARD_BPS, "bounty too high");
        // Bounds the cooldown, as the Router sibling does (`cd <= 7 days`).
        // Left open, an owner could set a cooldown of years before calling
        // lockConfiguration() and quietly neutralise the buyback this Burner
        // exists to perform: the tool would look configured and simply never
        // fire. Nobody gains from that, which is why it is a latent risk
        // rather than an exploitable attack, but the guard exists two
        // contracts over and its absence here was an oversight.
        require(_cooldown <= MAX_COOLDOWN, "cooldown too long");

        minBuybackWeth = _minBuybackWeth;
        emergencyWeth = _emergencyWeth;
        cooldown = _cooldown;
        gasRefund = _gasRefund;
        callerRewardBps = _callerRewardBps;
        emit ParamsUpdated(_minBuybackWeth, _emergencyWeth, _cooldown, _gasRefund, _callerRewardBps);
    }

    /// @notice Permanently freezes configuration. The toll, token, furnace,
    ///         route and adapter were never configurable; this locks the
    ///         rest.
    function lockConfiguration() external onlyOwner {
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// ---------------------------------------------------------------------------
// TollyForge, factory + registry
// ---------------------------------------------------------------------------

/// @author TollyLabs
contract TollyForge {
    ILaunchRegistry public immutable launchRegistry;
    address public immutable locker;
    address public immutable weth;
    address public immutable router;
    address public immutable tolly;

    address public immutable v3Factory; // to resolve each project's WETH pool
    TollyFurnace public immutable furnace;
    /// @notice The TollyForgeDeployer that created this Forge (address(0) if
    ///         it was deployed standalone). Burners are registered there so
    ///         the cross-launchpad official-tool check is O(1).
    address public immutable deployer;

    uint256 public constant TOLL_BPS = 100; // informational mirror of the burner constant

    uint256 private _lock = 1;
    modifier noReenter() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    // Registry
    address[] public allTools;
    mapping(address => bool) public isOfficialTool;
    mapping(address => address) public burnerForToken; // one official burner per project

    event BurnerCreated(address indexed token, address indexed burner, address indexed projectDeployer, address creator, uint256 tollBps);

    /// @dev Receives the Furnace and Oracle already deployed (they are shared
    ///      across every Forge on every launchpad) and validates the wiring
    ///      on-chain; a mis-wire here would be fatal and irreparable, so the
    ///      constructor refuses to deploy unless everything matches.
    ///      Deliberately performs no lookup of TOLLY on this launchpad: TOLLY
    ///      lives on launchpad #1, and Forge #2..N must still deploy fine.
    constructor(
        address _launchRegistry,
        address _locker,
        address _weth,
        address _router,
        address _tolly,
        address _furnace,
        address _v3Factory,
        address _deployer
    ) {
        require(
            _launchRegistry != address(0) && _locker != address(0) && _weth != address(0)
                && _router != address(0) && _tolly != address(0) && _v3Factory != address(0),
            "zero address"
        );
        // Wiring validation: the shared furnace must agree with what this
        // Forge will tell its burners.
        TollyFurnace f = TollyFurnace(_furnace);
        require(address(f.weth()) == _weth, "furnace weth mismatch");
        require(address(f.tolly()) == _tolly, "furnace bound to a different protocol token");
        require(address(f.router()) == _router, "furnace router mismatch");

        launchRegistry = ILaunchRegistry(_launchRegistry);
        locker = _locker;
        weth = _weth;
        router = _router;
        tolly = _tolly;
        furnace = f;
        v3Factory = _v3Factory;
        deployer = _deployer;
    }

    /// @notice Deploy the official burner for a token launched on this
    ///         launchpad. Callable by anyone (a bot, the project, or the
    ///         protocol team); ownership always goes to the token's actual
    ///         launch deployer, read from the launchpad's own registry.
    function createBurner(address token) external noReenter returns (address) {
        require(burnerForToken[token] == address(0), "burner exists");

        ILaunchRegistry.LaunchedToken memory t = launchRegistry.getLaunchedToken(token);
        require(t.exists, "not launched here");
        require(t.pairedToken == weth, "not WETH-paired"); // exotic pairs: later version

        uint256 tollBps = token == tolly ? 0 : TOLL_BPS;

        // The pool is NOT taken from `t.poolFee`. `launchRegistry` is whatever
        // address the caller of the permissionless `deployForge` supplied, so a
        // fee tier read from it is an attacker-chosen number wearing a registry's
        // clothes: name any tier, create that pool, seed it with dust, and every
        // impact cap and slippage floor a burner ever computes comes from a market
        // you own. The same authority that answers for the other four consumers
        // answers here, and it consults the pad or a governed registry, never the
        // caller. `t` still decides WHO owns the tool -- that is the launchpad's
        // business -- but not WHERE the money trades.
        (address projectPool, uint24 poolFee) =
            ITollyToolRegistry(deployer).resolveAuthenticatedPool(token, weth);
        bool projectIsToken0 = IUniswapV3Pool(projectPool).token0() == token;

        TollyBurner burner = new TollyBurner(
            token,
            weth,
            locker,
            router,
            poolFee,
            projectPool,
            projectIsToken0,
            address(furnace),
            tollBps,
            t.deployer,
            ITollyToolRegistry(deployer).minProcessBase(),
            ITollyToolRegistry(deployer).gasRefundBase(),
            ITollyToolRegistry(deployer).nativeIsQuote()
        );

        allTools.push(address(burner));
        isOfficialTool[address(burner)] = true;
        burnerForToken[token] = address(burner);

        // Mirror into the shared deployer registry so the cross-launchpad
        // check is O(1) instead of an unbounded loop.
        if (deployer != address(0)) {
            ITollyToolRegistry(deployer).registerTool(address(burner));
        }

        emit BurnerCreated(token, address(burner), t.deployer, msg.sender, tollBps);
        return address(burner);
    }

    function toolsCount() external view returns (uint256) {
        return allTools.length;
    }
}

// ---------------------------------------------------------------------------
// TollyForgeDeployer, the launchpad-agnostic entry point
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice Meta-factory. A chain tends to carry many launchpads, most of them
 *         forks of the same V3-locker codebase, so rather than the protocol
 *         team hand-deploying a Forge per launchpad, anyone (a project, a bot,
 *         the launchpad itself) connects a new launchpad in one transaction:
 *
 *             deployer.deployForge(launchRegistry, locker)
 *
 *         The new Forge is wired to the one shared Furnace and uses the exact
 *         template in this file. That makes officialness on-chain verifiable
 *         with no admin: a Forge is official if and only if
 *         `deployer.isOfficialForge(forge)`, because that means it provably
 *         runs this bytecode and provably feeds the canonical Furnace.
 *
 *         For tokens whose launchpad speaks a registry dialect no Forge
 *         understands, or with no launchpad at all, `createUniversalBurner(
 *         token, locker)` mints the same Burner template, resolving the
 *         token's WETH pool from the neutral V3 factory with no registry
 *         read, push-model first, locker optional. The creator proves project
 *         control by redirecting their fees to it, since only the current fee
 *         wallet can do that.
 *
 *         No owner. No pause. No approval queue. Agnostic by default.
 */
contract TollyForgeDeployer {
    address public immutable weth;
    address public immutable router;
    address public immutable tolly;
    address public immutable furnace;
    address public immutable v3Factory;
    /// @notice Uniswap V3 NonfungiblePositionManager, used by the Liquidity
    ///         Forge (Tool 3) to mint the locked positions. Chain-specific;
    ///         passed in.
    address public immutable positionManager;

    address[] public allForges;
    mapping(address => bool) public isOfficialForge;
    /// @notice Cross-launchpad official-tool set, written by official Forges
    ///         as they create burners, giving an O(1) lookup for dashboards.
    mapping(address => bool) public isOfficialTool;
    /// @notice One Forge per (launchRegistry, locker) pair.
    mapping(bytes32 => address) public forgeFor;

    /// @notice The self-service tool factories (burners, routers, liquidity
    ///         forges for any launchpad). Deployed as separate contracts,
    ///         since they embed too much tool bytecode to fit this one, and
    ///         blessed once via `initialize`. Set post-construction, so not
    ///         immutable.
    address public universalForge;
    address public routerForge;
    address public liquidityForgeFactory;
    bool public initialized;

    /// @notice The one address whose deposits into a tool have already paid
    ///         the toll, in practice the launchpad's fee locker, which takes
    ///         the 1% itself before forwarding a creator's share.
    ///         Without this, a creator who points their pad payout at a
    ///         Revenue Router would pay the toll twice: once in the locker on
    ///         the gross amount, and again in the Router on what arrives. The
    ///         Router cannot otherwise tell, because a plain ERC-20 transfer
    ///         leaves it holding a balance with no provenance. Set once,
    ///         alongside the factories; zero on chains with no launchpad of
    ///         ours.
    address public officialFeeSource;

    /// @notice The address that deployed this stack. Its only power is
    ///         calling `initialize` exactly once to bless the canonical
    ///         factories. No ongoing admin: it can never move funds or change
    ///         anything afterward.
    address public immutable initializer;

    /// @notice Per-deployment values in raw base-asset units, handed to every
    ///         tool this stack creates. They express an amount of money, not
    ///         a scale, so they cannot be derived from decimals: `0.01 ether`
    ///         rescaled by decimals is one cent where roughly $18 was meant.
    ///         Hardcoding them as 18-decimal literals meant a tool on a
    ///         6-decimal chain needed 10,000,000,000 USDC of accrual before it
    ///         would ever fire.
    uint256 public immutable minProcessBase;
    uint256 public immutable gasRefundBase;

    /// @notice True where the chain's native asset and `weth` are the same
    ///         asset, as on Arc.
    bool public immutable nativeIsQuote;

    /// @notice Resolver consulted for tokens the pad did not launch.
    /// @dev    IMMUTABLE on purpose. It decides which pools may ever be bound,
    ///         so a setter here would be an authority strictly stronger than the
    ///         registry it points at -- whoever held it could redirect every
    ///         future binding in one transaction. Changing the MECHANISM
    ///         therefore costs a new deployer, which is the price of not having
    ///         that key exist. The registry's CONTENTS stay governable, which is
    ///         where day-to-day decisions belong.
    address public immutable externalResolver;

    event ForgeDeployed(
        address indexed forge,
        address indexed launchRegistry,
        address indexed locker,
        address deployedBy
    );

    constructor(
        address _weth,
        address _router,
        address _tolly,
        address _furnace,
        address _v3Factory,
        address _positionManager,
        address _externalResolver,
        uint256 _minProcessBase,
        uint256 _gasRefundBase,
        bool _nativeIsQuote
    ) {
        // Zero is allowed and means "no external tokens on this deployment":
        // resolveAuthenticatedPool then reverts for anything the pad did not
        // launch. That is the conservative default, and it is reachable without
        // deploying a registry first.
        externalResolver = _externalResolver;
        require(_minProcessBase > 0, "min0");
        // A refund at or above the trigger threshold would pay the executor
        // more than the run is allowed to be worth.
        require(_gasRefundBase < _minProcessBase, "ref>min");
        minProcessBase = _minProcessBase;
        gasRefundBase = _gasRefundBase;
        nativeIsQuote = _nativeIsQuote;
        require(
            _weth != address(0) && _router != address(0) && _tolly != address(0)
                && _furnace != address(0) && _v3Factory != address(0) && _positionManager != address(0),
            "zero address"
        );
        // Same wiring validation a Forge performs: fail here, fail loudly,
        // fail once.
        TollyFurnace f = TollyFurnace(_furnace);
        require(address(f.weth()) == _weth, "furnace weth mismatch");
        require(address(f.tolly()) == _tolly, "furnace bound to a different protocol token");
        require(address(f.router()) == _router, "furnace router mismatch");

        weth = _weth;
        router = _router;
        tolly = _tolly;
        furnace = _furnace;
        v3Factory = _v3Factory;
        positionManager = _positionManager;
        initializer = msg.sender;
        // The tool factories are deployed separately (they embed too much
        // tool bytecode to fit here) and blessed once via `initialize`.
    }

    /// @notice One-time wiring of the self-service tool factories, callable
    ///         only by the address that deployed this stack, only once. Each
    ///         factory is verified to point back at this deployer. After
    ///         this the initializer has no power left; it cannot move funds
    ///         or change anything. The launchpad-Forge path (`deployForge`)
    ///         needs no init.

    /// @notice The ONE definition of "the official pool" for a token.
    /// @dev    Any ranking over candidate pools is decidable by whoever spends
    ///         a dollar shaping one, so there is no ranking here and no
    ///         fallback: a pool is either authenticated or the call reverts.
    ///         Precedence is ABSOLUTE. A token the pad launched resolves through
    ///         the pad and the external resolver is never consulted for it, so a
    ///         wrong or compromised governed entry cannot displace the official
    ///         pool of a token we issued. That ordering is the security property;
    ///         the validation below is only hygiene on top of it.
    ///         Lives on the deployer because all four consumers already hold it.
    ///         One implementation cannot drift into four definitions.
    function resolveAuthenticatedPool(address token, address quote)
        public
        view
        returns (address pool, uint24 fee)
    {
        // 1. Ours? The pad's record, through immutables nobody else can write.
        address padPool = _padPoolOf(token);
        if (padPool != address(0)) return _validatePool(token, quote, padPool);

        // 2. Not ours. A resolver that reverts, or refuses to vouch, ends the
        //    call here -- there is nowhere else to look by design.
        require(externalResolver != address(0), "no external resolver");
        (address p, bool authenticated) = IExternalPoolResolver(externalResolver).resolvePool(token, quote);
        require(authenticated, "pool not authenticated");
        require(p != address(0), "authenticated nothing"); // (0, true) vouches for absence
        return _validatePool(token, quote, p);
    }

    /// @dev The pad's registered pool, or zero if this token is not one of ours.
    ///      Reached only through addresses the protocol fixed: an arbitrary token
    ///      cannot answer for itself, which is what separates authentication from
    ///      the `token.pool()` getter any contract can implement.
    function _padPoolOf(address token) internal view returns (address) {
        // officialFeeSource IS the pad's locker: DeployArc passes it to
        // initialize, and the locker sets `pad = msg.sender` in its own
        // constructor. Naming that here because it reads like a coincidence and
        // is not -- it is the link that makes the pad reachable at all, and a
        // future deployment wiring something else into officialFeeSource would
        // silently turn every pad token into an external one.
        address lk = officialFeeSource;
        if (lk == address(0)) return address(0);
        address padAddr = ILockerPad(lk).pad();
        if (padAddr == address(0)) return address(0);
        (, address pool,) = IPadTokens(padAddr).tokens(token);
        return pool;
    }

    /// @dev Structure, not depth. Authentication says WHICH pool; this says the
    ///      address really is that pool.
    ///      Deliberately NOT checking liquidity() > 0. Active-tick liquidity is
    ///      exactly the value an attacker can move in one swap, so requiring it
    ///      would be a veto: anyone could exclude an honest pool by pushing its
    ///      price out of range. It is also legitimately zero on the pad's own
    ///      launch pool, which holds the entire supply on one side of the
    ///      opening tick. A momentary zero is not invalidity.
    function _validatePool(address token, address quote, address pool)
        internal
        view
        returns (address, uint24)
    {
        require(pool.code.length > 0, "pool has no code");
        uint24 fee = IUniswapV3PoolFee(pool).fee();
        require(IUniswapV3FactoryMinimal(v3Factory).getPool(token, quote, fee) == pool, "not this pair's pool");
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(sqrtPriceX96 != 0, "pool not initialised");
        return (pool, fee);
    }

    function initialize(address _universalForge, address _routerForge, address _lfFactory, address _officialFeeSource) external {
        require(msg.sender == initializer, "not initializer");
        require(!initialized, "already initialized");
        // May be zero: a chain with no pad of ours resolves everything through
        // the registry. But if it is set it is hop 1 of the pool-authority tree,
        // so it has to be a live locker that answers with a pad. Unchecked, two
        // failures hide here that no later call can undo: a codeless address makes
        // EVERY resolution revert, taking every future launch with it, and a
        // contract whose `pad()` is zero silently reclassifies every pad token as
        // external -- the one inversion this design exists to prevent. This is a
        // one-shot setter with no companion; the only moment to check is now.
        if (_officialFeeSource != address(0)) {
            require(_officialFeeSource.code.length > 0, "fee source has no code");
            require(ILockerPad(_officialFeeSource).pad() != address(0), "fee source is not a pad's locker");
        }
        officialFeeSource = _officialFeeSource;
        require(_universalForge != address(0) && _routerForge != address(0) && _lfFactory != address(0), "zero address");
        TollyUniversalForge uf = TollyUniversalForge(_universalForge);
        TollyRouterForge rf = TollyRouterForge(payable(_routerForge));
        require(address(uf.deployer()) == address(this), "uf mismatch");
        require(address(rf.deployer()) == address(this), "rf mismatch");
        // Re-assert each factory is wired to this stack's canonical
        // immutables, so a mis-wired or spoofed factory cannot be blessed as
        // official. deployer() alone is a value any contract can fake, so the
        // whole wiring is pinned.
        require(
            uf.weth() == weth && uf.router() == router && uf.tolly() == tolly
                && uf.furnace() == furnace && uf.v3Factory() == v3Factory,
            "uf wiring"
        );
        require(
            rf.weth() == weth && rf.router() == router && rf.furnace() == furnace
                && rf.v3Factory() == v3Factory && rf.positionManager() == positionManager,
            "rf wiring"
        );
        TollyLiquidityForgeFactory lff = TollyLiquidityForgeFactory(_lfFactory);
        require(address(lff.deployer()) == address(this), "lff mismatch");
        require(
            lff.weth() == weth && lff.router() == router && lff.furnace() == furnace
                && lff.v3Factory() == v3Factory && lff.positionManager() == positionManager,
            "lff wiring"
        );
        initialized = true;
        universalForge = _universalForge;
        routerForge = _routerForge;
        liquidityForgeFactory = _lfFactory;
        isOfficialForge[_universalForge] = true;
        isOfficialForge[_routerForge] = true;
        isOfficialForge[_lfFactory] = true;
    }

    /// @notice Connect a new V3-locker-family launchpad to Tolly. Permissionless.
    /// @param launchRegistry the launchpad's factory/registry exposing getLaunchedToken()
    /// @param locker the launchpad's fee locker exposing collectFees()
    function deployForge(address launchRegistry, address locker) external returns (address) {
        require(launchRegistry != address(0) && locker != address(0), "zero address");
        bytes32 key = keccak256(abi.encodePacked(launchRegistry, locker));
        require(forgeFor[key] == address(0), "forge exists");

        TollyForge forge = new TollyForge(launchRegistry, locker, weth, router, tolly, furnace, v3Factory, address(this));

        allForges.push(address(forge));
        isOfficialForge[address(forge)] = true;
        forgeFor[key] = address(forge);

        emit ForgeDeployed(address(forge), launchRegistry, locker, msg.sender);
        return address(forge);
    }

    /// @notice Called by an official Forge when it creates a burner, so the
    ///         cross-launchpad official-tool set stays O(1) to query. Only
    ///         Forges this deployer created can write here.
    function registerTool(address tool) external {
        require(isOfficialForge[msg.sender], "not official forge");
        isOfficialTool[tool] = true;
    }

    function forgesCount() external view returns (uint256) {
        return allForges.length;
    }
}

// ---------------------------------------------------------------------------
// TollyUniversalForge, self-service burners for any launchpad
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice The registry-less burner factory. Forge-created burners need the
 *         launchpad's registry to speak a known dialect; this one needs
 *         nothing from the launchpad at all, since the token's pool is
 *         resolved from the neutral V3 factory. One transaction, one input,
 *         any launchpad.
 *
 *         Ownership model: the burner is ownerless (battle-tested default
 *         parameters, forever), and the creator proves project control by
 *         redirecting their launchpad fees to it, since only the token's
 *         current fee wallet can do that. Front-running creation is
 *         pointless: the attacker would only mint the exact same contract
 *         the project wanted.
 */
contract TollyUniversalForge {
    TollyForgeDeployer public immutable deployer;
    address public immutable weth;
    address public immutable router;
    address public immutable tolly;
    address public immutable furnace;
    address public immutable v3Factory;

    /// @notice One universal burner per token, enumerable for keepers and dashboards.
    mapping(address => address) public universalBurnerForToken;
    address[] public allUniversalBurners;
    /// @notice DCA Treasuries (Tool 4): owned and configured, so not one-per-token.
    address[] public allDcaTreasuries;

    bool private _lock;

    event UniversalBurnerCreated(
        address indexed token, address indexed burner, address indexed launchLocker, address createdBy
    );
    event DcaTreasuryCreated(address indexed token, address indexed treasury, address indexed owner, address launchLocker);

    constructor(address _deployer, address _weth, address _router, address _tolly, address _furnace, address _v3Factory) {
        // Fail loudly at deploy if this factory is mis-wired: the same
        // furnace wiring check the Forge and Deployer make, so blessed tools
        // stay consistent.
        TollyFurnace f = TollyFurnace(_furnace);
        require(address(f.weth()) == _weth && address(f.tolly()) == _tolly && address(f.router()) == _router, "furnace wiring");
        deployer = TollyForgeDeployer(_deployer);
        weth = _weth;
        router = _router;
        tolly = _tolly;
        furnace = _furnace;
        v3Factory = _v3Factory;
    }

    /// @notice Mint the standard Burner for any WETH-paired token.
    /// @param token the project token (must have a WETH V3 pool)
    /// @param launchLocker optional launchpad fee locker for self-claims; pass
    ///        address(0) for pure push mode (fees simply arrive, as WETH,
    ///        tokens, or native ETH). A wrong locker only no-ops the
    ///        self-claim; it can never brick the burner.
    function createUniversalBurner(address token, address launchLocker) external returns (address) {
        require(!_lock, "reentrancy");
        _lock = true;
        require(token != address(0) && token != weth, "bad token");
        require(token.code.length > 0, "token has no code");
        require(universalBurnerForToken[token] == address(0), "burner exists");

        // One boundary, on the deployer, shared by all four consumers. It
        // authenticates rather than ranks: a pad token resolves through the pad,
        // an external one through the governed resolver, and anything else
        // reverts. There is no heuristic left to win.
        (address pool, uint24 poolFee) = deployer.resolveAuthenticatedPool(token, weth);
        require(pool != address(0), "no WETH pool");
        bool isToken0 = IUniswapV3Pool(pool).token0() == token;

        TollyBurner burner = new TollyBurner(
            token,
            weth,
            launchLocker,
            router,
            poolFee,
            pool,
            isToken0,
            furnace,
            token == tolly ? 0 : 100, // TOLLY's own burner never pays the toll
            address(0),               // ownerless, defaults locked in forever
            deployer.minProcessBase(),
            deployer.gasRefundBase(),
            deployer.nativeIsQuote()
        );

        universalBurnerForToken[token] = address(burner);
        allUniversalBurners.push(address(burner));
        deployer.registerTool(address(burner)); // official-tool O(1) lookup registration

        emit UniversalBurnerCreated(token, address(burner), launchLocker, msg.sender);
        _lock = false;
        return address(burner);
    }

    function universalBurnersCount() external view returns (uint256) {
        return allUniversalBurners.length;
    }

    /// @notice Mint a DCA Treasury (Tool 4) for any WETH-paired token, owned
    ///         by the caller, who configures the mode and schedule and then
    ///         locks it. An independent instance, not one-per-token, so
    ///         nothing is squattable.
    function createDcaTreasury(address token, address launchLocker) external returns (address) {
        require(!_lock, "reentrancy");
        _lock = true;
        require(token != address(0) && token != weth, "bad token");
        require(token.code.length > 0, "token has no code");

        // One boundary, on the deployer, shared by all four consumers. It
        // authenticates rather than ranks: a pad token resolves through the pad,
        // an external one through the governed resolver, and anything else
        // reverts. There is no heuristic left to win.
        (address pool, uint24 poolFee) = deployer.resolveAuthenticatedPool(token, weth);
        require(pool != address(0), "no WETH pool");
        bool isToken0 = IUniswapV3Pool(pool).token0() == token;

        TollyDcaTreasury t = new TollyDcaTreasury(
            token, weth, launchLocker, router, poolFee, pool, isToken0, furnace, msg.sender,
            deployer.minProcessBase(), deployer.gasRefundBase(), deployer.officialFeeSource(), deployer.nativeIsQuote()
        );
        allDcaTreasuries.push(address(t));
        deployer.registerTool(address(t));
        emit DcaTreasuryCreated(token, address(t), msg.sender, launchLocker);
        _lock = false;
        return address(t);
    }

    function dcaTreasuriesCount() external view returns (uint256) { return allDcaTreasuries.length; }

    /// @dev The token's deepest WETH pool across the standard fee tiers: the
    ///      neutral, launchpad-independent answer to "where does it trade".
}

// ---------------------------------------------------------------------------
// TollyRevenueRouter, Tool 2: configurable creator-fee split (one toll)
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice Replaces the Burner's rigid "burn 99%" with a configurable split.
 *         Same first move: claim fees, take the exact 1% toll once, wrap
 *         native ETH, pay the executor from the project side, then divide the
 *         remaining project side across the owner's allocations, which must
 *         sum to 100%. v1 performs the allocations internally, with no
 *         pluggable external modules, so no downstream tool charges a second
 *         toll: Rule 3 holds by construction.
 *
 *         Ownership: the creator owns it and configures the split, then
 *         `lockAllocations()` freezes it forever. Not one-per-token in a
 *         global slot; each router is an independent instance owned by its
 *         creator, so there is nothing to front-run or squat, unlike a shared
 *         mapping.
 */
contract TollyRevenueRouter {
    using SafeT for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant TOLL_BPS = 100;          // 1%, hardcoded
    uint256 public constant MAX_IMPACT_BPS = 200;    // buyback slice moves price <= ~2%
    uint256 public constant BURN_SLIPPAGE_BPS = 500; // 5% swap floor
    uint256 public constant MAX_CALLER_PAY_BPS = 1_000; // executor pay <= 10% of project side
    uint256 public constant MAX_ALLOCATIONS = 6;

    enum Kind { BUYBACK_BURN, TREASURY, REWARDS, LIQUIDITY }
    struct Allocation { Kind kind; uint16 bps; address dest; }

    // ---- Immutables ----
    IERC20 public immutable projectToken;
    IERC20 public immutable weth;
    ILaunchLocker public immutable locker;
    ISwapRouterV3 public immutable router;
    uint24 public immutable poolFee;
    address public immutable projectPool;
    bool public immutable projectIsToken0;
    TollyFurnace public immutable furnace;
    TollyForgeDeployer public immutable deployer; // to verify a LIQUIDITY dest is official
    /// @notice See `TollyForgeDeployer.nativeIsQuote`.
    bool public immutable nativeIsQuote;

    // ---- Configuration (owner-set until locked) ----
    address public owner;
    bool public configurationLocked;
    Allocation[] public allocations;

    /// @dev Raw base-asset units, set per deployment. See the note in TollyBurner.
    uint256 public minProcessWeth;

    /// @notice Funds forwarded by the official fee source, which already paid
    ///         the toll there and must not pay it again here. Same mechanism
    ///         as TollyRevenueRouter, since a pad creator may point their
    ///         creator share at either one and the toll is charged once.
    address public immutable officialFeeSource;
    uint256 public prepaidBalance;
    event PrepaidDeposit(address indexed source, uint256 amount);
    uint256 public cooldown = 1800;      // 30 min
    uint256 public gasRefund;            // fixed executor refund, raw base units
    uint256 public callerRewardBps = 100; // +1% executor bounty
    uint256 public lastProcess;

    uint256 private _lockedFlag = 1;
    modifier nonReentrant() { require(_lockedFlag == 1, "reentrancy"); _lockedFlag = 2; _; _lockedFlag = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier notLocked() { require(!configurationLocked, "locked"); _; }

    event AllocationsSet(uint256 count);
    event ConfigurationLocked();
    event FeesClaimed(bool success, uint256 amount0, uint256 amount1);
    event RouterProcessed(
        address indexed caller,
        uint256 gross,
        uint256 toll,
        uint256 callerPaid,
        uint256 distributable
    );
    event Allocated(Kind indexed kind, address indexed dest, uint256 amountIn, uint256 tokensOut);

    constructor(
        address _projectToken,
        address _weth,
        address _locker,
        address _router,
        uint24 _poolFee,
        address _projectPool,
        bool _projectIsToken0,
        address _furnace,
        address _deployer,
        address _owner,
        uint256 _minProcessBase,
        uint256 _gasRefundBase,
        bool _nativeIsQuote
    ) {
        nativeIsQuote = _nativeIsQuote;
        require(_owner != address(0), "router needs an owner");
        projectToken = IERC20(_projectToken);
        weth = IERC20(_weth);
        locker = ILaunchLocker(_locker);
        router = ISwapRouterV3(_router);
        poolFee = _poolFee;
        projectPool = _projectPool;
        projectIsToken0 = _projectIsToken0;
        furnace = TollyFurnace(_furnace);
        require(_minProcessBase > 0, "min0");
        require(_gasRefundBase < _minProcessBase, "ref>min");
        minProcessWeth = _minProcessBase;
        gasRefund = _gasRefundBase;
        deployer = TollyForgeDeployer(_deployer);
        owner = _owner;
        IERC20(_weth).approve(_router, type(uint256).max);
        IERC20(_weth).approve(_furnace, type(uint256).max);
    }

    // native-ETH payout launchpads: accept and wrap on process (like the Burner)
    receive() external payable {}

    // ------------------------------------------------------------------
    // Configuration (owner, until locked)
    // ------------------------------------------------------------------

    /// @notice Set the split of the project side (after the 1% toll). `bps`
    ///         must sum to exactly 10_000. LIQUIDITY is reserved for the
    ///         Liquidity Forge (Tool 3) and reverts until that tool exists.
    function setAllocations(Allocation[] calldata a) external onlyOwner notLocked {
        require(a.length > 0 && a.length <= MAX_ALLOCATIONS, "bad count");
        delete allocations;
        uint256 sum;
        uint256 buybacks;
        for (uint256 i; i < a.length; i++) {
            require(a[i].bps > 0, "zero bps");
            if (a[i].kind == Kind.BUYBACK_BURN) {
                buybacks++;
            } else if (a[i].kind == Kind.LIQUIDITY) {
                // dest must be an official Tolly Liquidity Forge for this
                // token, so the router routes toll-free liquidity only to a
                // real forge that adds to the same project's pool.
                require(deployer.isOfficialTool(a[i].dest), "liquidity dest not official");
                require(address(TollyLiquidityForge(payable(a[i].dest)).projectToken()) == address(projectToken), "forge token mismatch");
            } else {
                require(a[i].dest != address(0), "dest required"); // treasury / rewards
            }
            sum += a[i].bps;
            allocations.push(a[i]);
        }
        require(sum == BPS, "must sum to 100%");
        require(buybacks <= 1, "one buyback max");
        emit AllocationsSet(a.length);
    }

    function lockAllocations() external onlyOwner {
        require(allocations.length > 0, "no allocations");
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    function setParams(uint256 minWei, uint256 cd, uint256 refund, uint256 rewardBps) external onlyOwner notLocked {
        require(minWei > 0 && cd <= 7 days && rewardBps <= 300, "bounds");
        minProcessWeth = minWei; cooldown = cd; gasRefund = refund; callerRewardBps = rewardBps;
    }

    function allocationsCount() external view returns (uint256) { return allocations.length; }

    // ------------------------------------------------------------------
    // Execution (permissionless)
    // ------------------------------------------------------------------

    function claimOnly() external nonReentrant { _claim(); }

    /// @notice Claim and wrap fees, take the 1% toll once, pay the executor
    ///         from the project side, then run every allocation.
    ///         Permissionless; the executor is reimbursed from the project
    ///         side, never from the toll.
    /// @param minBuybackOut slippage floor for the buyback slice (0 is safe,
    ///        the contract always enforces its own spot floor).
    function processFees(uint256 minBuybackOut) external nonReentrant {
        require(configurationLocked, "configure & lock first");
        require(block.timestamp >= lastProcess + cooldown, "cooldown");
        _claim();

        // The project-token half of the claimed fees burns directly (same
        // first move as the Burner). The Router only distributes the WETH
        // side, so without this the token side would strand in the contract
        // forever.
        uint256 directBurn = projectToken.balanceOf(address(this));
        if (directBurn > 0) SafeT.safeTransfer(projectToken, DEAD, directBurn);

        // Wrap native ETH so everything downstream is WETH.
        // Nothing to wrap where native and quote are the same asset.
        if (!nativeIsQuote) {
            uint256 nativeBal = address(this).balance;
            if (nativeBal > 0) IWETH9Min(address(weth)).deposit{value: nativeBal}();
        }

        uint256 wethBal = weth.balanceOf(address(this));
        require(wethBal >= minProcessWeth, "below min");

        // Impact-cap the whole batch to the project pool (same as the Burner).
        uint256 maxWei = PoolMath.maxImpactIn(projectPool, projectIsToken0, MAX_IMPACT_BPS);
        uint256 gross = wethBal > maxWei ? maxWei : wethBal;
        require(gross > 0, "no in-range pool liquidity");
        lastProcess = block.timestamp;

        // 1% toll to the Furnace, once. Money forwarded by the official fee
        // source already paid it there, so only the rest is tolled here.
        // Without this, the pad's own creators, the normal path, would pay
        // 1% twice.
        uint256 exempt = gross < prepaidBalance ? gross : prepaidBalance;
        prepaidBalance -= exempt;
        uint256 toll = ((gross - exempt) * TOLL_BPS) / BPS;
        if (toll > 0) furnace.depositToll(address(projectToken), toll);

        // Executor pay from the project side, hard-capped.
        uint256 projectSide = gross - toll;
        uint256 callerPay = gasRefund + (projectSide * callerRewardBps) / BPS;
        uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
        if (callerPay > maxPay) callerPay = maxPay;
        SafeT.safeTransfer(weth, msg.sender, callerPay);

        uint256 distributable = projectSide - callerPay;
        _distribute(distributable, minBuybackOut);

        emit RouterProcessed(msg.sender, gross, toll, callerPay, distributable);
    }

    function _distribute(uint256 distributable, uint256 minBuybackOut) internal {
        uint256 len = allocations.length;
        for (uint256 i; i < len; i++) {
            Allocation memory al = allocations[i];
            uint256 amount = (distributable * al.bps) / BPS;
            if (amount == 0) continue;
            if (al.kind == Kind.BUYBACK_BURN) {
                uint256 spotFloor = (PoolMath.spotOut(projectPool, projectIsToken0, amount) * (BPS - BURN_SLIPPAGE_BPS)) / BPS;
                uint256 minOut = spotFloor > minBuybackOut ? spotFloor : minBuybackOut;
                uint256 before = projectToken.balanceOf(DEAD);
                router.exactInputSingle(ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: address(weth), tokenOut: address(projectToken), fee: poolFee,
                    recipient: DEAD, amountIn: amount, amountOutMinimum: minOut, sqrtPriceLimitX96: 0
                }));
                emit Allocated(Kind.BUYBACK_BURN, DEAD, amount, projectToken.balanceOf(DEAD) - before);
            } else if (al.kind == Kind.LIQUIDITY) {
                // Route to the project's Liquidity Forge, toll-free (Rule 3):
                // the forge honors tollFree only from official tools, and the
                // gross was already tolled above. Fund it, then trigger the
                // add.
                SafeT.safeTransfer(weth, al.dest, amount);
                TollyLiquidityForge(payable(al.dest)).addLiquidity(0, true);
                emit Allocated(Kind.LIQUIDITY, al.dest, amount, 0);
            } else {
                // TREASURY / REWARDS: the project's WETH share, sent directly to its address.
                SafeT.safeTransfer(weth, al.dest, amount);
                emit Allocated(al.kind, al.dest, amount, 0);
            }
        }
        // Any rounding remainder stays and rolls into the next batch.
    }

    function _claim() internal {
        if (address(locker).code.length == 0) { emit FeesClaimed(false, 0, 0); return; }
        try locker.collectFees(address(projectToken)) returns (uint256 a0, uint256 a1) {
            emit FeesClaimed(true, a0, a1);
        } catch { emit FeesClaimed(false, 0, 0); }
    }

    // ------------------------------------------------------------------
    // Views (bots / dashboard)
    // ------------------------------------------------------------------

    /// @notice Deposit funds that have already paid the toll upstream. Pulls
    ///         via transferFrom, so the caller approves first, the same shape
    ///         the Furnace uses for {depositToll}, and for the same reason: a
    ///         push arrives with no provenance, while a pull is authenticated
    ///         by construction.
    /// @dev    Restricted to the deployer's single official fee source.
    ///         Anyone else marking their own deposits prepaid would be
    ///         exempting themselves from the toll.
    function depositPrepaid(uint256 amount) external {
        require(msg.sender == deployer.officialFeeSource(), "!src");
        require(amount > 0, "zero");
        SafeT.safeTransferFrom(weth, msg.sender, address(this), amount);
        prepaidBalance += amount;
        emit PrepaidDeposit(msg.sender, amount);
    }

    function canProcess() external view returns (bool ready, uint256 wethAvailable, uint256 requiredWei, bool cooldownPassed) {
        wethAvailable = weth.balanceOf(address(this)) + address(this).balance;
        requiredWei = minProcessWeth;
        cooldownPassed = block.timestamp >= lastProcess + cooldown;
        ready = configurationLocked && cooldownPassed && wethAvailable >= requiredWei;
    }

    function previewDistribution(uint256 gross)
        external
        view
        returns (uint256 toll, uint256 callerPay, uint256 distributable, uint256[] memory perAllocation)
    {
        toll = (gross * TOLL_BPS) / BPS;
        uint256 projectSide = gross - toll;
        callerPay = gasRefund + (projectSide * callerRewardBps) / BPS;
        uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
        if (callerPay > maxPay) callerPay = maxPay;
        distributable = projectSide - callerPay;
        perAllocation = new uint256[](allocations.length);
        for (uint256 i; i < allocations.length; i++) {
            perAllocation[i] = (distributable * allocations[i].bps) / BPS;
        }
    }
}

// ---------------------------------------------------------------------------
// TollyRouterForge, self-service Revenue Routers for any launchpad
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice Mints Revenue Routers, exactly like TollyUniversalForge mints
 *         Burners: resolves the token's deepest WETH pool from the neutral V3
 *         factory (no registry read), and registers each router as an
 *         official tool so keepers and dashboards can discover it. A
 *         separate contract to stay under EIP-170.
 *
 *         Routers are not one-per-token: each is owned by its creator, who
 *         configures and locks it, then redirects fees to it. Nothing to squat.
 */
contract TollyRouterForge {
    TollyForgeDeployer public immutable deployer;
    address public immutable weth;
    address public immutable router;
    address public immutable furnace;
    address public immutable v3Factory;
    address public immutable positionManager;

    address[] public allRouters;
    bool private _lock;

    event RouterCreated(address indexed token, address indexed routerContract, address indexed owner, address launchLocker);

    constructor(address _deployer, address _weth, address _router, address _furnace, address _v3Factory, address _positionManager) {
        // Same furnace-wiring check the other factories make (constructor-only).
        TollyFurnace f = TollyFurnace(_furnace);
        require(address(f.weth()) == _weth && address(f.router()) == _router, "furnace wiring");
        deployer = TollyForgeDeployer(_deployer);
        weth = _weth;
        router = _router;
        furnace = _furnace;
        v3Factory = _v3Factory;
        positionManager = _positionManager;
    }

    /// @notice Mint a Revenue Router for any WETH-paired token, owned by the
    ///         caller, who then configures allocations and locks it.
    ///         Configure before redirecting the token's fees to it.
    function createRouter(address token, address launchLocker) external returns (address) {
        require(!_lock, "reentrancy");
        _lock = true;
        require(token != address(0) && token != weth, "bad token");
        require(token.code.length > 0, "token has no code");

        // One boundary, on the deployer, shared by all four consumers. It
        // authenticates rather than ranks: a pad token resolves through the pad,
        // an external one through the governed resolver, and anything else
        // reverts. There is no heuristic left to win.
        (address pool, uint24 poolFee) = deployer.resolveAuthenticatedPool(token, weth);
        require(pool != address(0), "no WETH pool");
        bool isToken0 = IUniswapV3Pool(pool).token0() == token;

        TollyRevenueRouter r = new TollyRevenueRouter(
            token, weth, launchLocker, router, poolFee, pool, isToken0, furnace, address(deployer), msg.sender,
            deployer.minProcessBase(), deployer.gasRefundBase(), deployer.nativeIsQuote()
        );
        allRouters.push(address(r));
        deployer.registerTool(address(r));
        emit RouterCreated(token, address(r), msg.sender, launchLocker);
        _lock = false;
        return address(r);
    }

    function routersCount() external view returns (uint256) { return allRouters.length; }


}

// ---------------------------------------------------------------------------
// TollyLiquidityForgeFactory, Tool 3's factory, split out of TollyRouterForge
// ---------------------------------------------------------------------------

/// @author TollyLabs
/// @notice A factory of its own rather than a second tool inside
///         TollyRouterForge. Carrying the creation bytecode of both the Router
///         and the LiquidityForge puts a single factory over the EIP-170 code
///         size limit, so each tool gets its own deployer and each stays
///         deployable as it grows.
contract TollyLiquidityForgeFactory {
    TollyForgeDeployer public immutable deployer;
    /// @notice See `TollyForgeDeployer.nativeIsQuote`.
    bool public immutable nativeIsQuote;
    address public immutable weth;
    address public immutable router;
    address public immutable furnace;
    address public immutable v3Factory;
    address public immutable positionManager;

    address[] public allLiquidityForges;
    bool private _lock;

    event LiquidityForgeCreated(address indexed token, address indexed forge, address launchLocker);

    constructor(address _deployer, address _weth, address _router, address _furnace, address _v3Factory, address _positionManager) {
        deployer = TollyForgeDeployer(_deployer);
        weth = _weth; router = _router; furnace = _furnace;
        v3Factory = _v3Factory; positionManager = _positionManager;
    }


    /// @notice Mint a Liquidity Forge (Tool 3) for any WETH-paired token,
    ///         owned by the caller (the project). Full-range strategy,
    ///         time-locked liquidity (>= MIN_LOCK), extendable or made
    ///         permanent by the owner. An independent instance, nothing to
    ///         squat.
    /// @param lockDuration seconds the liquidity is locked from now (>= 30 days).
    function createLiquidityForge(address token, address launchLocker, uint256 lockDuration) external returns (address) {
        require(!_lock, "reentrancy");
        _lock = true;
        require(token != address(0) && token != weth, "bad token");
        require(token.code.length > 0, "token has no code");
        // One boundary, on the deployer, shared by all four consumers. It
        // authenticates rather than ranks: a pad token resolves through the pad,
        // an external one through the governed resolver, and anything else
        // reverts. There is no heuristic left to win.
        (address pool, uint24 poolFee) = deployer.resolveAuthenticatedPool(token, weth);
        require(pool != address(0), "no WETH pool");
        bool isToken0 = IUniswapV3Pool(pool).token0() == token;

        TollyLiquidityForge lf = new TollyLiquidityForge(
            token, weth, launchLocker, router, poolFee, pool, isToken0, furnace, address(deployer), positionManager, msg.sender, lockDuration,
            deployer.minProcessBase(), deployer.gasRefundBase(), deployer.nativeIsQuote()
        );
        allLiquidityForges.push(address(lf));
        deployer.registerTool(address(lf));
        emit LiquidityForgeCreated(token, address(lf), launchLocker);
        _lock = false;
        return address(lf);
    }

    function liquidityForgesCount() external view returns (uint256) { return allLiquidityForges.length; }

}

// ---------------------------------------------------------------------------
// TollyLiquidityForge, Tool 3: fees to permanent locked V3 liquidity
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice Converts creator fees into time-locked liquidity in the project's
 *         own V3 pool. It mints a full-range position, holds the NFT, and the
 *         owner (the project) can reclaim it only after `unlockTime`; the
 *         lock can be extended but never shortened, or made permanent. Fees
 *         accrued by the locked position compound back in.
 *
 *         Standalone, it charges the 1% toll; called by an official Tolly
 *         tool (the Revenue Router) with `tollFree=true`, it skips the toll
 *         under Rule 3, gated by `deployer.isOfficialTool(msg.sender)` so an
 *         EOA cannot fake it.
 *
 *         Owned by its creator: an independent instance, not one-per-token in
 *         a squattable global slot.
 */
contract TollyLiquidityForge {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant TOLL_BPS = 100;          // 1%
    uint256 public constant MAX_IMPACT_BPS = 200;    // the zap swap moves price <= ~2%
    uint256 public constant BURN_SLIPPAGE_BPS = 500; // 5% zap-swap floor
    uint256 public constant MAX_CALLER_PAY_BPS = 1_000;
    /// @dev Immutable per deployment rather than `constant`, in raw base-asset
    ///      units: it is an amount of money, so the right value depends on the
    ///      decimals of the quote asset this deployment uses.
    uint256 public immutable MIN_PROCESS_WETH;
    uint256 public constant COOLDOWN = 1800;         // 30 min
    uint256 public immutable GAS_REFUND;
    uint256 public constant CALLER_REWARD_BPS = 100; // +1% executor bounty
    uint256 public constant MIN_LOCK = 30 days;      // no "1-second lock" rug
    int24 internal constant MAX_TICK = 887272;

    IERC20 public immutable projectToken;
    IERC20 public immutable weth;
    ILaunchLocker public immutable locker;
    ISwapRouterV3 public immutable swapRouter;
    uint24 public immutable poolFee;
    address public immutable projectPool;
    bool public immutable projectIsToken0;
    TollyFurnace public immutable furnace;
    TollyForgeDeployer public immutable deployer;
    /// @notice See `TollyForgeDeployer.nativeIsQuote`.
    bool public immutable nativeIsQuote;
    INonfungiblePositionManagerMin public immutable npm;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    address public immutable owner;
    uint256 public immutable lockDuration; // armed from the first real mint, not from deploy

    uint256 public positionId;   // 0 until the first mint; then grows via increaseLiquidity

    /// @notice Funds forwarded by the official fee source (the pad's locker),
    ///         which already paid the toll there. Exempt from this contract's
    ///         own 1%, the same mechanism as the Router and the DCA Treasury.
    ///         A regex-based review once claimed this contract took no toll;
    ///         the `skipToll ? 0 :` ternary had simply hidden the line from
    ///         it.
    uint256 public prepaidBalance;
    uint256 public lastProcess;
    uint256 public unlockTime;   // the position can be withdrawn only at/after this
    bool public permanent;       // once true, never withdrawable

    uint256 private _lockedFlag = 1;
    modifier nonReentrant() { require(_lockedFlag == 1, "reentrancy"); _lockedFlag = 2; _; _lockedFlag = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    event LiquidityAdded(address indexed caller, bool tollFree, uint256 gross, uint256 toll, uint256 liquidityMinted);
    event LpFeesCollected(uint256 wethCollected, uint256 tokenCollected);
    event FeesClaimed(bool success, uint256 amount0, uint256 amount1);
    event LockExtended(uint256 newUnlockTime);
    event MadePermanent();
    event PositionWithdrawn(address indexed to, uint256 positionId);
    event PrepaidDeposit(address indexed source, uint256 amount);

    constructor(
        address _projectToken,
        address _weth,
        address _locker,
        address _swapRouter,
        uint24 _poolFee,
        address _projectPool,
        bool _projectIsToken0,
        address _furnace,
        address _deployer,
        address _npm,
        address _owner,
        uint256 _lockDuration,
        uint256 _minProcessBase,
        uint256 _gasRefundBase,
        bool _nativeIsQuote
    ) {
        nativeIsQuote = _nativeIsQuote;
        require(_owner != address(0), "owner required");
        require(_lockDuration >= MIN_LOCK, "lock too short");
        projectToken = IERC20(_projectToken);
        weth = IERC20(_weth);
        locker = ILaunchLocker(_locker);
        swapRouter = ISwapRouterV3(_swapRouter);
        poolFee = _poolFee;
        projectPool = _projectPool;
        projectIsToken0 = _projectIsToken0;
        furnace = TollyFurnace(_furnace);
        deployer = TollyForgeDeployer(_deployer);
        require(_minProcessBase > 0, "min0");
        require(_gasRefundBase < _minProcessBase, "ref>min");
        MIN_PROCESS_WETH = _minProcessBase;
        GAS_REFUND = _gasRefundBase;
        npm = INonfungiblePositionManagerMin(_npm);
        owner = _owner;
        lockDuration = _lockDuration;
        unlockTime = block.timestamp + _lockDuration; // provisional; re-armed at the first real mint

        int24 spacing = _poolFee == 100 ? int24(1) : _poolFee == 500 ? int24(10) : _poolFee == 3000 ? int24(60) : int24(200);
        int24 usable = (MAX_TICK / spacing) * spacing;
        tickLower = -usable;
        tickUpper = usable;

        IERC20(_weth).approve(_swapRouter, type(uint256).max);
        IERC20(_weth).approve(_furnace, type(uint256).max);
        IERC20(_weth).approve(_npm, type(uint256).max);
        IERC20(_projectToken).approve(_npm, type(uint256).max);
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // Lock management (owner)
    // ------------------------------------------------------------------

    /// @notice Extend the lock. Can only move `unlockTime` FORWARD, never shorten.
    function extendLock(uint256 newUnlockTime) external onlyOwner {
        require(!permanent, "already permanent");
        require(newUnlockTime > unlockTime, "cannot shorten");
        unlockTime = newUnlockTime;
        emit LockExtended(newUnlockTime);
    }

    /// @notice Lock the liquidity forever, no withdraw path remains after this.
    function permanentLock() external onlyOwner {
        permanent = true;
        emit MadePermanent();
    }

    /// @notice Reclaim the position NFT, owner only, only once the lock has
    ///         expired, and only if it was never made permanent. Sends the
    ///         NFT directly to `to`, never through an intermediate wallet.
    function withdrawPosition(address to) external onlyOwner nonReentrant {
        require(!permanent, "permanent lock");
        require(block.timestamp >= unlockTime, "still locked");
        require(positionId != 0, "no position");
        require(to != address(0), "bad recipient");
        uint256 id = positionId;
        positionId = 0;
        npm.safeTransferFrom(address(this), to, id);
        emit PositionWithdrawn(to, id);
    }

    /// @notice Accept funds that already paid the toll upstream. Pull, not
    ///         push, gated on the deployer's one official source, the same
    ///         shape and reasons as TollyRevenueRouter.depositPrepaid.
    function depositPrepaid(uint256 amount) external {
        address src = deployer.officialFeeSource();
        require(src != address(0) && msg.sender == src, "!src");
        require(amount > 0, "zero");
        SafeT.safeTransferFrom(weth, msg.sender, address(this), amount);
        prepaidBalance += amount;
        emit PrepaidDeposit(msg.sender, amount);
    }

    /// @notice Zap creator fees into the locked full-range position. Permissionless.
    /// @param minTokenOut slippage floor for the internal zap swap (0 is safe,
    ///        the contract enforces its own spot floor).
    /// @param tollFree honored only when the caller is an official Tolly tool
    ///        (Rule 3: the Router already tolled). Ignored for anyone else.
    function addLiquidity(uint256 minTokenOut, bool tollFree) external nonReentrant {
        // Rule 3: the toll-free path is honored only for a registered
        // official tool (e.g. a Router). It also bypasses the cooldown/min
        // gate; those exist to throttle the standalone path, and the calling
        // tool already gated.
        bool skipToll = tollFree && deployer.isOfficialTool(msg.sender);

        if (!skipToll) require(block.timestamp >= lastProcess + COOLDOWN, "cooldown");
        _claim();

        // Nothing to wrap where native and quote are the same asset.
        if (!nativeIsQuote) {
            uint256 nativeBal = address(this).balance;
            if (nativeBal > 0) IWETH9Min(address(weth)).deposit{value: nativeBal}();
        }

        uint256 wethBal = weth.balanceOf(address(this));
        if (!skipToll) require(wethBal >= MIN_PROCESS_WETH, "below min");

        uint256 maxWei = PoolMath.maxImpactIn(projectPool, projectIsToken0, MAX_IMPACT_BPS);
        uint256 gross = wethBal > maxWei ? maxWei : wethBal;
        require(gross > 0, "no in-range pool liquidity");
        lastProcess = block.timestamp;

        // Money the official source forwarded was already tolled at the locker.
        uint256 exempt = gross < prepaidBalance ? gross : prepaidBalance;
        prepaidBalance -= exempt;
        uint256 toll = skipToll ? 0 : ((gross - exempt) * TOLL_BPS) / BPS;
        if (toll > 0) furnace.depositToll(address(projectToken), toll);

        uint256 projectSide = gross - toll;
        // Executor pay only on the standalone path; the toll-free path runs
        // inside another tool's transaction, which already paid its executor.
        uint256 callerPay;
        if (!skipToll) {
            callerPay = GAS_REFUND + (projectSide * CALLER_REWARD_BPS) / BPS;
            uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
            if (callerPay > maxPay) callerPay = maxPay;
            SafeT.safeTransfer(weth, msg.sender, callerPay);
        }

        // Zap: swap ~half the WETH to the project token, then add both sides.
        uint256 addable = projectSide - callerPay;
        uint256 half = addable / 2;
        if (half > 0) {
            uint256 spotFloor = (PoolMath.spotOut(projectPool, projectIsToken0, half) * (BPS - BURN_SLIPPAGE_BPS)) / BPS;
            uint256 minOut = spotFloor > minTokenOut ? spotFloor : minTokenOut;
            swapRouter.exactInputSingle(ISwapRouterV3.ExactInputSingleParams({
                tokenIn: address(weth), tokenOut: address(projectToken), fee: poolFee,
                recipient: address(this), amountIn: half, amountOutMinimum: minOut, sqrtPriceLimitX96: 0
            }));
        }
        uint256 liq = _addToPosition();
        emit LiquidityAdded(msg.sender, skipToll, gross, toll, liq);
    }

    /// @notice Collect the locked position's accrued LP fees into this
    ///         contract; they roll into the next `addLiquidity` call,
    ///         compounding, and are tolled at that point.
    function collectLpFees() external nonReentrant {
        require(positionId != 0, "no position");
        (uint256 a0, uint256 a1) = npm.collect(INonfungiblePositionManagerMin.CollectParams({
            tokenId: positionId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        emit LpFeesCollected(projectIsToken0 ? a1 : a0, projectIsToken0 ? a0 : a1);
    }

    function _addToPosition() internal returns (uint256 liq) {
        uint256 wBal = weth.balanceOf(address(this));
        uint256 tBal = projectToken.balanceOf(address(this));
        if (wBal == 0 || tBal == 0) return 0;
        (address t0, address t1, uint256 a0, uint256 a1) = projectIsToken0
            ? (address(projectToken), address(weth), tBal, wBal)
            : (address(weth), address(projectToken), wBal, tBal);

        if (positionId == 0) {
            (uint256 id, uint128 l,,) = npm.mint(INonfungiblePositionManagerMin.MintParams({
                token0: t0, token1: t1, fee: poolFee, tickLower: tickLower, tickUpper: tickUpper,
                amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0,
                recipient: address(this), deadline: block.timestamp
            }));
            positionId = id;
            // Arm the lock from the moment real liquidity first exists, and
            // re-arm after a post-unlock withdrawal resets positionId to 0.
            // Only ever moves unlockTime forward, so it cannot shorten an
            // extendLock.
            uint256 armed = block.timestamp + lockDuration;
            if (armed > unlockTime) unlockTime = armed;
            liq = l;
        } else {
            (uint128 l,,) = npm.increaseLiquidity(INonfungiblePositionManagerMin.IncreaseLiquidityParams({
                tokenId: positionId, amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
            liq = l;
        }
        // Leftover dust, the side the NPM did not fully use, stays and rolls forward.
    }

    function _claim() internal {
        if (address(locker).code.length == 0) { emit FeesClaimed(false, 0, 0); return; }
        try locker.collectFees(address(projectToken)) returns (uint256 a0, uint256 a1) {
            emit FeesClaimed(true, a0, a1);
        } catch { emit FeesClaimed(false, 0, 0); }
    }

    /// @notice ERC721 receiver; accepts the minted position NFT.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---- Views ----

    /// @notice The locked position's live liquidity, its unlock time, and
    ///         whether it was made permanent, in which case unlock is moot.
    function lockedLiquidity() external view returns (uint128 liquidity, uint256 unlockAt, bool isPermanent) {
        if (positionId != 0) {
            (,,,,,,, liquidity,,,,) = npm.positions(positionId);
        }
        unlockAt = unlockTime;
        isPermanent = permanent;
    }

    function canProcess() external view returns (bool ready, uint256 wethAvailable, uint256 requiredWei, bool cooldownPassed) {
        wethAvailable = weth.balanceOf(address(this)) + address(this).balance;
        requiredWei = MIN_PROCESS_WETH;
        cooldownPassed = block.timestamp >= lastProcess + COOLDOWN;
        ready = cooldownPassed && wethAvailable >= requiredWei;
    }
}

// ---------------------------------------------------------------------------
// TollyDcaTreasury, Tool 4: scheduled buys, configurable destination
// ---------------------------------------------------------------------------

/**
  * @author TollyLabs
 * @notice Uses creator fees to steadily buy the project token, dollar-cost
 *         averaging via capped batches on an interval, and routes the bought
 *         tokens per the owner's mode: BURN (0xdead), TREASURY (an address),
 *         SPLIT (both), or LOCK (held here forever). Equivalent to the Burner
 *         with a configurable destination.
 *
 *         1% toll always applies; the executor is paid from the project side;
 *         buys are impact-sized with a spot floor and no oracle. Owned by its
 *         creator; configure, then call `lockStrategy()`.
 */
contract TollyDcaTreasury {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant TOLL_BPS = 100;
    uint256 public constant MAX_IMPACT_BPS = 200;
    uint256 public constant BURN_SLIPPAGE_BPS = 500;
    uint256 public constant MAX_CALLER_PAY_BPS = 1_000;
    uint256 public immutable GAS_REFUND;
    uint256 public constant CALLER_REWARD_BPS = 100;

    enum Mode { BURN, TREASURY, SPLIT, LOCK }

    /// @notice See `TollyForgeDeployer.nativeIsQuote`.
    bool public immutable nativeIsQuote;

    IERC20 public immutable projectToken;
    IERC20 public immutable weth;
    ILaunchLocker public immutable locker;
    ISwapRouterV3 public immutable router;
    uint24 public immutable poolFee;
    address public immutable projectPool;
    bool public immutable projectIsToken0;
    TollyFurnace public immutable furnace;
    address public immutable owner;

    Mode public mode;
    address public treasuryDest;
    uint16 public splitBurnBps;          // SPLIT: % of bought tokens sent to 0xdead
    /// @dev Raw base-asset units, set per deployment. See the note in TollyBurner.
    uint256 public minProcessWeth;

    /// @notice Funds forwarded by the official fee source, which already paid
    ///         the toll there and must not pay it again here. Same mechanism
    ///         as TollyRevenueRouter, since a pad creator may point their
    ///         creator share at either one and the toll is charged once.
    address public immutable officialFeeSource;
    uint256 public prepaidBalance;
    event PrepaidDeposit(address indexed source, uint256 amount);
    uint256 public interval = 1 days;    // DCA cadence
    uint256 public maxBatchWeth = type(uint256).max; // per-execution WETH cap
    bool public strategyLocked;
    uint256 public lastExec;

    uint256 private _lockedFlag = 1;
    modifier nonReentrant() { require(_lockedFlag == 1, "reentrancy"); _lockedFlag = 2; _; _lockedFlag = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier notLocked() { require(!strategyLocked, "locked"); _; }

    event StrategySet(Mode mode, address treasuryDest, uint16 splitBurnBps);
    event ScheduleSet(uint256 interval, uint256 maxBatchWeth);
    event StrategyLocked();
    event FeesClaimed(bool success, uint256 amount0, uint256 amount1);
    event DcaExecuted(address indexed caller, uint256 gross, uint256 toll, uint256 bought, uint256 burned, uint256 toTreasury);

    constructor(
        address _projectToken, address _weth, address _locker, address _router,
        uint24 _poolFee, address _projectPool, bool _projectIsToken0, address _furnace, address _owner,
        uint256 _minProcessBase, uint256 _gasRefundBase, address _officialFeeSource,
        bool _nativeIsQuote
    ) {
        nativeIsQuote = _nativeIsQuote;
        require(_owner != address(0), "owner required");
        projectToken = IERC20(_projectToken);
        weth = IERC20(_weth);
        locker = ILaunchLocker(_locker);
        router = ISwapRouterV3(_router);
        poolFee = _poolFee;
        projectPool = _projectPool;
        projectIsToken0 = _projectIsToken0;
        furnace = TollyFurnace(_furnace);
        require(_minProcessBase > 0, "min0");
        require(_gasRefundBase < _minProcessBase, "ref>min");
        minProcessWeth = _minProcessBase;
        GAS_REFUND = _gasRefundBase;
        officialFeeSource = _officialFeeSource;
        owner = _owner;
        IERC20(_weth).approve(_router, type(uint256).max);
        IERC20(_weth).approve(_furnace, type(uint256).max);
    }

    receive() external payable {}

    // ---- Configuration (owner, until locked) ----

    function setStrategy(Mode _mode, address _treasuryDest, uint16 _splitBurnBps) external onlyOwner notLocked {
        if (_mode == Mode.TREASURY || _mode == Mode.SPLIT) require(_treasuryDest != address(0), "dest required");
        if (_mode == Mode.SPLIT) require(_splitBurnBps > 0 && _splitBurnBps < BPS, "bad split");
        mode = _mode;
        treasuryDest = _treasuryDest;
        splitBurnBps = _splitBurnBps;
        emit StrategySet(_mode, _treasuryDest, _splitBurnBps);
    }

    function setSchedule(uint256 _interval, uint256 _maxBatchWeth) external onlyOwner notLocked {
        // Lower bound on the interval: interval == 0 would let executeDca
        // fire every block, defeating the dollar-cost-average cadence and
        // letting a caller repeatedly extract the executor bounty in one
        // burst.
        require(_interval >= 1 hours && _interval <= 30 days && _maxBatchWeth > 0, "bounds");
        interval = _interval;
        maxBatchWeth = _maxBatchWeth;
        emit ScheduleSet(_interval, _maxBatchWeth);
    }

    function setMinProcess(uint256 _minWei) external onlyOwner notLocked {
        require(_minWei > 0, "zero");
        minProcessWeth = _minWei;
    }

    function lockStrategy() external onlyOwner {
        strategyLocked = true;
        emit StrategyLocked();
    }

    // ---- Execution (permissionless) ----

    function claimOnly() external nonReentrant { _claim(); }

    /// @notice One scheduled DCA buy, routed per the mode. Permissionless.
    function executeDca(uint256 minOut) external nonReentrant {
        require(strategyLocked, "configure & lock first");
        require(block.timestamp >= lastExec + interval, "not yet");
        _claim();

        // Nothing to wrap where native and quote are the same asset.
        if (!nativeIsQuote) {
            uint256 nativeBal = address(this).balance;
            if (nativeBal > 0) IWETH9Min(address(weth)).deposit{value: nativeBal}();
        }

        uint256 wethBal = weth.balanceOf(address(this));
        require(wethBal >= minProcessWeth, "below min");

        uint256 maxWei = PoolMath.maxImpactIn(projectPool, projectIsToken0, MAX_IMPACT_BPS);
        uint256 gross = wethBal < maxWei ? wethBal : maxWei;
        if (gross > maxBatchWeth) gross = maxBatchWeth; // DCA per-execution cap
        require(gross > 0, "no in-range pool liquidity");
        lastExec = block.timestamp;

        // 1% toll, once. What the official fee source forwarded already paid it.
        uint256 exempt = gross < prepaidBalance ? gross : prepaidBalance;
        prepaidBalance -= exempt;
        uint256 toll = ((gross - exempt) * TOLL_BPS) / BPS;
        if (toll > 0) furnace.depositToll(address(projectToken), toll);

        uint256 projectSide = gross - toll;
        uint256 callerPay = GAS_REFUND + (projectSide * CALLER_REWARD_BPS) / BPS;
        uint256 maxPay = (projectSide * MAX_CALLER_PAY_BPS) / BPS;
        if (callerPay > maxPay) callerPay = maxPay;
        SafeT.safeTransfer(weth, msg.sender, callerPay);

        // Buy the token to self, then route per mode.
        uint256 spend = projectSide - callerPay;
        uint256 spotFloor = (PoolMath.spotOut(projectPool, projectIsToken0, spend) * (BPS - BURN_SLIPPAGE_BPS)) / BPS;
        uint256 floor = spotFloor > minOut ? spotFloor : minOut;
        uint256 before = projectToken.balanceOf(address(this));
        router.exactInputSingle(ISwapRouterV3.ExactInputSingleParams({
            tokenIn: address(weth), tokenOut: address(projectToken), fee: poolFee,
            recipient: address(this), amountIn: spend, amountOutMinimum: floor, sqrtPriceLimitX96: 0
        }));
        uint256 bought = projectToken.balanceOf(address(this)) - before;

        // Route everything the tool holds, the swap output plus any
        // project-token the locker paid on claim (the fee token side), per
        // the mode. `before` was read after `_claim`, so `bought` above is
        // the swap output only (for the event), while the full balance is
        // what actually gets routed.
        (uint256 burned, uint256 toTreasury) = _route(projectToken.balanceOf(address(this)));
        emit DcaExecuted(msg.sender, gross, toll, bought, burned, toTreasury);
    }

    function _route(uint256 bought) internal returns (uint256 burned, uint256 toTreasury) {
        if (bought == 0) return (0, 0);
        if (mode == Mode.BURN) {
            SafeT.safeTransfer(projectToken, DEAD, bought);
            burned = bought;
        } else if (mode == Mode.TREASURY) {
            SafeT.safeTransfer(projectToken, treasuryDest, bought);
            toTreasury = bought;
        } else if (mode == Mode.SPLIT) {
            burned = (bought * splitBurnBps) / BPS;
            toTreasury = bought - burned;
            if (burned > 0) SafeT.safeTransfer(projectToken, DEAD, burned);
            if (toTreasury > 0) SafeT.safeTransfer(projectToken, treasuryDest, toTreasury);
        }
        // LOCK: tokens stay in this contract forever; no withdraw path exists.
    }

    function _claim() internal {
        if (address(locker).code.length == 0) { emit FeesClaimed(false, 0, 0); return; }
        try locker.collectFees(address(projectToken)) returns (uint256 a0, uint256 a1) {
            emit FeesClaimed(true, a0, a1);
        } catch { emit FeesClaimed(false, 0, 0); }
    }

    // ---- Views ----

    /// @notice Tokens accumulated in this contract (meaningful for LOCK mode;
    ///         for TREASURY mode the tokens live at treasuryDest).
    function treasuryBalance() external view returns (uint256) {
        return projectToken.balanceOf(address(this));
    }

    /// @notice Accept funds that already paid the toll upstream. Pull, not
    ///         push: a push arrives with no provenance. Restricted to the one
    ///         source, since anyone able to mark their own deposits prepaid
    ///         would be exempting themselves from the toll.
    function depositPrepaid(uint256 amount) external {
        require(officialFeeSource != address(0) && msg.sender == officialFeeSource, "!src");
        require(amount > 0, "zero");
        SafeT.safeTransferFrom(weth, msg.sender, address(this), amount);
        prepaidBalance += amount;
        emit PrepaidDeposit(msg.sender, amount);
    }

    function canProcess() external view returns (bool ready, uint256 wethAvailable, uint256 requiredWei, bool cooldownPassed) {
        wethAvailable = weth.balanceOf(address(this)) + address(this).balance;
        requiredWei = minProcessWeth;
        cooldownPassed = block.timestamp >= lastExec + interval;
        ready = strategyLocked && cooldownPassed && wethAvailable >= requiredWei;
    }
}
