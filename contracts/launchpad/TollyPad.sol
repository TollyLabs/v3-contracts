// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TollyToken} from "./TollyToken.sol";
import {TollyFeeLocker, INPMLocker} from "./TollyFeeLocker.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IV3FactoryPad {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface IUForgePad {
    function universalForge() external view returns (address);
    function createUniversalBurner(address token, address launchLocker) external returns (address);
}

interface IV3PoolPad {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function initialize(uint160 sqrtPriceX96) external;
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

interface INPMPad {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

/// @title  TollyPad
/// @author TollyLabs
/// @notice Launchpad with no bonding curve. Each launch mints a fixed 1B
///         supply directly into a permanently locked, single-sided Uniswap V3
///         position quoted in USDC:
///
///         1. `createToken` deploys a fixed-supply ERC-20 (whole supply held here).
///         2. Creates and initializes the token/USDC 1% pool at the start price.
///         3. Mints the entire supply as single-sided liquidity (token only,
///            zero USDC) across [tickLower, tickUpper]. The LP NFT is
///            transferred directly to {TollyFeeLocker}, locked permanently;
///            the position cannot be withdrawn, but fees remain collectable
///            indefinitely.
///         4. Optionally executes an atomic creator dev-buy on the fresh pool.
///
///         Price rises through the range as buyers bring USDC; the launch
///         supply sells single-sided out of the locked LP. Correct for both
///         token/USDC orderings.
/// @dev    Quote asset is USDC, not WETH: on Arc, USDC is both the native gas
///         asset and a first-class ERC-20, a single balance with two decimal
///         views (18 native, 6 ERC-20). Tokens are therefore priced in
///         dollars rather than a volatile base pair, and no wrapper contract
///         exists or is needed anywhere in this design.
///
contract TollyPad is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TokenInfo {
        address creator;
        address pool;
        uint256 lpTokenId;
    }

    /// @notice Launch metadata. Not stored on-chain; emitted and indexed off-chain.
    ///
    /// @dev Emitting rather than storing is a deliberate cost decision: a URI
    ///      held in storage costs roughly 20k gas per launch permanently, for
    ///      data only a frontend reads. Consequently the pad cannot return the
    ///      current metadata directly; an indexer replays TokenCreated, then
    ///      any subsequent TokenMetaUpdated.
    ///
    ///      `imageURI` is required at launch (see {MetaRequired}), which makes
    ///      the {updateMeta} escape hatch necessary as well: without it, a
    ///      mistyped URL or a dead image host would leave a token permanently
    ///      broken on the board, an outcome the required field would otherwise
    ///      make more likely. The two are designed together.
    struct TokenMeta {
        string imageURI;
        string website;
        string twitter;
        string telegram;
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint24 public constant POOL_FEE = 10_000; // Uniswap V3 1% tier
    int24 public constant TICK_SPACING = 200;

    /// @notice Anti-snipe max wallet: 3% of supply, enforced only during the
    ///         launch window (`antiSnipeSeconds`); unenforced thereafter.
    /// @dev    3%, not 5%: the cap exists so a single funded address cannot
    ///         take the opening price for itself, and at 5% three wallets
    ///         could still hold a seventh of supply before anyone else is
    ///         filled. This is a launch guard, not a permanent holding limit,
    ///         so the tighter figure costs a genuine buyer only a second
    ///         transaction once the window closes.
    uint256 public constant MAX_WALLET = (TOTAL_SUPPLY * 3) / 100;

    uint256 public constant MAX_SALT_TRIES = 64;

    /// @notice FDV targets, in raw quote units (6-decimal USDC).
    /// @dev    The unit is encoded in the name deliberately: passing an
    ///         18-decimal ("wei-thinking") value here would open every launch
    ///         at a price off by 10^12, and nothing downstream would catch it.
    ///         See {actualStartFdv} for the FDV the tick-aligned range
    ///         actually produces.
    uint256 public immutable targetStartFdvQuoteRaw;
    uint256 public immutable targetTopFdvQuoteRaw;
    uint256 public immutable actualStartFdv;
    uint256 public immutable actualTopFdv;

    int24 public immutable tickFloor;
    int24 public immutable tickCeil;
    uint256 public immutable antiSnipeSeconds;

    IV3FactoryPad public immutable v3Factory;
    INPMPad public immutable positionManager;
    /// @notice The quote asset (USDC); not WETH, there is no wrapper contract here.
    IERC20 public immutable quote;
    TollyFeeLocker public immutable locker;

    mapping(address => TokenInfo) public tokens;
    address[] public allTokens;

    address internal _expectedPoolCallback;

    /// @notice Maintains the name/symbol blacklist. The sole privileged role;
    ///         it can only block new launches by name and cannot touch
    ///         existing tokens, funds, pools, or launches. Tokens remain
    ///         ownerless.
    address public owner;
    mapping(bytes32 => bool) public banned;

    /// @notice Emitted when the launch also mints the token's buy-and-burn
    ///         engine, so the advertised 5% project buyback burns from block
    ///         one rather than accruing to the creator until claimed.
    event BurnerAutoMinted(address indexed token, address indexed burner);

    event TokenCreated(
        address indexed token, address indexed creator, string name, string symbol,
        address pool, string imageURI, string website, string twitter, string telegram
    );
    event Launched(address indexed token, address indexed pool, uint256 lpTokenId, uint128 liquidity, uint256 tokenSeeded);
    event DevBuy(address indexed token, address indexed creator, uint256 quoteIn, uint256 tokensOut);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BannedSet(bytes32 indexed wordHash, bool banned);
    /// @notice The creator updated a token's off-chain metadata. Indexers
    ///         apply the latest of these over what TokenCreated carried.
    event TokenMetaUpdated(
        address indexed token, address indexed creator,
        string imageURI, string website, string twitter, string telegram
    );

    error InvalidConfig();
    error UnexpectedCallback();
    error NotSingleSided();
    error SeedFailed();
    error TickRangeInvalid();
    error LaunchGriefed();
    error Banned();
    /// @dev Reverts a launch with no logo. Required because a token with no
    ///      image renders as a blank tile on every board that lists it, and
    ///      metadata is emitted once; there is no add-it-later path other
    ///      than {updateMeta}.
    error MetaRequired();
    /// @dev Bounds metadata length so a single launch cannot emit an unbounded
    ///      blob and impose that decoding cost on every indexer that replays
    ///      the log.
    error MetaTooLong();
    error NotCreator();
    error OnlyOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        uint256 startFdvQuoteRaw_,
        uint256 topFdvQuoteRaw_,
        uint256 antiSnipeSeconds_,
        IV3FactoryPad v3Factory_,
        INPMPad positionManager_,
        IERC20 quote_,
        address owner_,
        string[] memory initialBannedWords_
    ) {
        if (
            owner_ == address(0) || startFdvQuoteRaw_ == 0 || topFdvQuoteRaw_ == 0
                || topFdvQuoteRaw_ <= startFdvQuoteRaw_ || address(v3Factory_) == address(0)
                || address(positionManager_) == address(0) || address(quote_) == address(0)
        ) revert InvalidConfig();

        targetStartFdvQuoteRaw = startFdvQuoteRaw_;
        targetTopFdvQuoteRaw = topFdvQuoteRaw_;
        antiSnipeSeconds = antiSnipeSeconds_;
        v3Factory = v3Factory_;
        positionManager = positionManager_;
        quote = quote_;

        int24 rawFloor = TickMath.getTickAtSqrtRatio(_sqrtPriceX96FromFdv(startFdvQuoteRaw_));
        int24 rawCeil = TickMath.getTickAtSqrtRatio(_sqrtPriceX96FromFdv(topFdvQuoteRaw_));
        int24 floor_ = _alignToSpacing(rawFloor);
        int24 ceil_ = _alignToSpacing(rawCeil);
        if (floor_ >= ceil_) revert TickRangeInvalid();
        tickFloor = floor_;
        tickCeil = ceil_;

        actualStartFdv = _fdvFromSqrtPriceX96(TickMath.getSqrtRatioAtTick(floor_));
        actualTopFdv = _fdvFromSqrtPriceX96(TickMath.getSqrtRatioAtTick(ceil_));

        locker = new TollyFeeLocker(INPMLocker(address(positionManager_)), quote_, owner_);

        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        for (uint256 i; i < initialBannedWords_.length; ++i) {
            banned[_normHash(bytes(initialBannedWords_[i]))] = true;
        }
    }

    /// @notice Launches a token: deploys the ERC-20, opens its USDC pool at the
    ///         start price, mints the entire supply as permanently locked
    ///         single-sided LP, and optionally executes an atomic creator
    ///         dev-buy.
    /// @dev    Reverts on a banned name or symbol, or on missing/oversized
    ///         metadata.
    /// @param  name Token name.
    /// @param  symbol Token symbol.
    /// @param  meta Off-chain metadata (logo required; see {MetaRequired}).
    /// @param  salt Fresh random value per call; makes the token's CREATE2
    ///         address unpredictable so a griefer cannot pre-poison its pool.
    /// @param  devBuyQuote Amount of quote asset (6-decimal USDC) to spend
    ///         buying the caller's own token in the same transaction, pulled
    ///         from the caller via `transferFrom` (requires prior approval).
    ///         Zero to skip.
    ///
    ///         This is an explicit 6-decimal ERC-20 amount rather than
    ///         `msg.value`. Arc's native USDC balance uses 18 decimals while
    ///         its ERC-20 view and this pool use 6 decimals, so a payable path
    ///         would introduce a second unit system and a 1e12 conversion.
    ///         Pulling the ERC-20 view via `transferFrom` keeps the launch,
    ///         approval and pool accounting in one unit system.
    /// @return token Address of the newly deployed token.
    function createToken(
        string calldata name,
        string calldata symbol,
        TokenMeta calldata meta,
        bytes32 salt,
        uint256 devBuyQuote
    ) external nonReentrant returns (address token) {
        if (banned[_normHash(bytes(name))] || banned[_normHash(bytes(symbol))]) revert Banned();
        _checkMeta(meta);

        // 1. CREATE2-deploy at an address with no pre-existing pool and no code.
        //    Plain CREATE is predictable, and Uniswap lets anyone initialize a
        //    pool for a not-yet-deployed
        //    token, and a reverted launch would roll the nonce back onto the
        //    same poisoned address forever. A random salt plus a walk past
        //    taken candidates keeps a clean launch always one retry away.
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(TollyToken).creationCode,
                abi.encode(
                    name, symbol, TOTAL_SUPPLY, address(this),
                    address(positionManager), address(locker), MAX_WALLET, antiSnipeSeconds
                )
            )
        );

        uint256 seed = uint256(keccak256(abi.encode(msg.sender, salt)));
        uint256 tries;
        address predicted;
        for (; tries < MAX_SALT_TRIES;) {
            predicted = _computeTokenAddress(bytes32(seed), initCodeHash);
            if (v3Factory.getPool(predicted, address(quote), POOL_FEE) == address(0) && predicted.code.length == 0) {
                break;
            }
            unchecked { ++tries; ++seed; }
        }
        if (tries == MAX_SALT_TRIES) revert LaunchGriefed();

        token = address(
            new TollyToken{salt: bytes32(seed)}(
                name, symbol, TOTAL_SUPPLY, address(this),
                address(positionManager), address(locker), MAX_WALLET, antiSnipeSeconds
            )
        );
        assert(token == predicted);

        bool tokenIs0 = token < address(quote);
        (int24 tickLower, int24 tickUpper, int24 initTick) = _rangeFor(tokenIs0);

        // 2. Create the pool (verified above to not yet exist).
        address pool = v3Factory.getPool(token, address(quote), POOL_FEE);
        if (pool == address(0)) pool = v3Factory.createPool(token, address(quote), POOL_FEE);
        TollyToken(token).setPool(pool);

        // 3. Initialize exactly on the tick boundary; this is what makes the
        //    mint consume precisely zero USDC.
        (uint160 existing,,,,,,) = IV3PoolPad(pool).slot0();
        if (existing == 0) IV3PoolPad(pool).initialize(TickMath.getSqrtRatioAtTick(initTick));

        // 4. Mint the entire supply single-sided into the locker.
        (uint256 lpTokenId, uint128 liquidity, uint256 tokenSeeded) =
            _mintSingleSided(token, tokenIs0, tickLower, tickUpper);

        tokens[token] = TokenInfo({creator: msg.sender, pool: pool, lpTokenId: lpTokenId});
        allTokens.push(token);
        locker.register(lpTokenId, token, msg.sender);

        // Mints the token's buy-and-burn engine as part of the launch, so the
        // advertised "5% buys and burns your token" holds from block one. The
        // locker resolves the 5% share to this burner; without it, that share
        // is parked on the creator instead, silently dropping the
        // project-burn leg and handing it to the creator. This is a
        // push-model burner (launchLocker = 0): the locker transfers its
        // share in, so there is nothing to self-claim.
        //
        // Skipped only when the protocol is not yet wired, i.e. for TOLLY
        // itself (token #0), which is deployed before the forge exists and
        // receives its own toll-exempt burner during protocol setup. This
        // explicit bootstrap guard is not a generic failure catch: once the
        // forge is wired, every launch must create its burner or revert.
        address forge = locker.universalForge();
        if (forge != address(0)) {
            // Deliberately not wrapped in try/catch. Once the forge is wired,
            // a launch must create its burner or revert; silently continuing
            // would route the advertised project-burn share to the creator.
            // The explicit forge == 0 branch above is the bootstrap exception.
            address burner = IUForgePad(forge).createUniversalBurner(token, address(0));
            emit BurnerAutoMinted(token, burner);
        }

        emit TokenCreated(token, msg.sender, name, symbol, pool, meta.imageURI, meta.website, meta.twitter, meta.telegram);
        emit Launched(token, pool, lpTokenId, liquidity, tokenSeeded);

        // 5. Optional atomic dev-buy.
        if (devBuyQuote > 0) _devBuy(token, pool, tokenIs0, tickLower, tickUpper, devBuyQuote);
    }

    // ---------------------------------------------------------------- admin --

    /// @notice Maximum length accepted per metadata field.
    /// @dev    These strings are emitted, and every indexer that replays the
    ///         log pays to decode them. Left unbounded, a single launch could
    ///         make that replay arbitrarily expensive for everyone
    ///         permanently. 512 fits an IPFS URI or a long CDN path with room
    ///         to spare.
    uint256 public constant MAX_META_LEN = 512;

    /// @dev A logo is required; the remaining fields are optional. This
    ///      deliberately does not attempt to validate that the string is a
    ///      working URL: on-chain validation is both expensive and futile
    ///      (a string such as "x" would pass any cheap check), and the real
    ///      validation is the launch form loading the image before allowing
    ///      submission. What this does guarantee is that nobody launches with
    ///      an empty logo by accident, an error a prior deploy script made.
    function _checkMeta(TokenMeta calldata meta) internal pure {
        if (bytes(meta.imageURI).length == 0) revert MetaRequired();
        if (
            bytes(meta.imageURI).length > MAX_META_LEN || bytes(meta.website).length > MAX_META_LEN
                || bytes(meta.twitter).length > MAX_META_LEN || bytes(meta.telegram).length > MAX_META_LEN
        ) revert MetaTooLong();
    }

    /// @notice Re-points a token's logo and links. Creator only.
    /// @dev    The escape hatch that makes a required logo safe. Without it,
    ///         a mistyped URL, a dead image host, or a rebrand would leave
    ///         the token broken on every board for the rest of its life, an
    ///         outcome the required field would otherwise make more likely.
    ///
    ///         Emits rather than stores, like the launch itself, so indexers
    ///         apply the latest TokenMetaUpdated over what TokenCreated
    ///         carried. Nothing about the token, its pool, or its liquidity
    ///         is touched: this function cannot move funds, and the creator
    ///         holds no other power here.
    function updateMeta(address token, TokenMeta calldata meta) external {
        if (tokens[token].creator != msg.sender) revert NotCreator();
        _checkMeta(meta);
        emit TokenMetaUpdated(token, msg.sender, meta.imageURI, meta.website, meta.twitter, meta.telegram);
    }

    function setBanned(string calldata word, bool isBanned) external onlyOwner {
        bytes32 h = _normHash(bytes(word));
        banned[h] = isBanned;
        emit BannedSet(h, isBanned);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _normHash(bytes memory b) internal pure returns (bytes32) {
        uint256 len = b.length;
        uint256 start = 0;
        while (start < len && b[start] == 0x20) ++start;
        uint256 end = len;
        while (end > start && b[end - 1] == 0x20) --end;
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            bytes1 c = b[i];
            if (c >= 0x41 && c <= 0x5A) c = bytes1(uint8(c) + 32);
            out[i - start] = c;
        }
        return keccak256(out);
    }

    // ----------------------------------------------------------- LP seeding --

    function _mintSingleSided(address token, bool tokenIs0, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 tokenUsed)
    {
        uint256 supply = IERC20(token).balanceOf(address(this));
        IERC20(token).forceApprove(address(positionManager), supply);

        (uint256 amount0Desired, uint256 amount1Desired) =
            tokenIs0 ? (supply, uint256(0)) : (uint256(0), supply);

        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = positionManager.mint(
            INPMPad.MintParams({
                token0: tokenIs0 ? token : address(quote),
                token1: tokenIs0 ? address(quote) : token,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );

        IERC20(token).forceApprove(address(positionManager), 0);

        uint256 quoteUsed;
        if (tokenIs0) { (tokenUsed, quoteUsed) = (used0, used1); }
        else { (tokenUsed, quoteUsed) = (used1, used0); }

        // The seed must be pure token: zero quote, real liquidity, approximately the whole supply.
        if (quoteUsed != 0) revert NotSingleSided();
        if (liquidity == 0 || tokenUsed < supply - supply / 1000) revert SeedFailed();
    }

    // ------------------------------------------------------------- dev-buy --

    /// @dev Pulls `quoteIn` (6-decimal) from the creator and swaps it for the
    ///      token on the fresh pool, delivering the output directly to the
    ///      creator. Unspent quote (the swap can stop at the range edge) is
    ///      refunded.
    function _devBuy(address token, address pool, bool tokenIs0, int24 tickLower, int24 tickUpper, uint256 quoteIn)
        internal
    {
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);

        bool zeroForOne = !tokenIs0;
        uint160 sqrtLimit = TickMath.getSqrtRatioAtTick(tokenIs0 ? tickUpper : tickLower);

        _expectedPoolCallback = pool;
        (int256 amount0, int256 amount1) =
            IV3PoolPad(pool).swap(msg.sender, zeroForOne, int256(quoteIn), sqrtLimit, abi.encode(token));
        _expectedPoolCallback = address(0);

        uint256 quoteSpent = uint256(tokenIs0 ? amount1 : amount0);
        uint256 tokensOut = uint256(-(tokenIs0 ? amount0 : amount1));
        emit DevBuy(token, msg.sender, quoteSpent, tokensOut);

        uint256 refund = quoteIn - quoteSpent;
        if (refund > 0) quote.safeTransfer(msg.sender, refund);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _expectedPoolCallback || _expectedPoolCallback == address(0)) revert UnexpectedCallback();
        address token = abi.decode(data, (address));
        bool tokenIs0 = token < address(quote);

        if (amount0Delta > 0) IERC20(tokenIs0 ? token : address(quote)).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(tokenIs0 ? address(quote) : token).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ------------------------------------------------------------ tick math --

    function _rangeFor(bool tokenIs0) internal view returns (int24 tickLower, int24 tickUpper, int24 initTick) {
        if (tokenIs0) return (tickFloor, tickCeil, tickFloor);
        return (-tickCeil, -tickFloor, -tickFloor);
    }

    /// @dev sqrtPriceX96 for a token0-convention price of `fdv / TOTAL_SUPPLY`.
    ///      This formula defines the launch-price invariant; changing it changes that price.
    ///
    ///      The formula is decimal-agnostic because it operates entirely in
    ///      raw (smallest-unit) amounts: the raw pool ratio is quoteRaw per
    ///      tokenRaw, and `fdv / TOTAL_SUPPLY`, with fdv in raw 6-decimal
    ///      USDC and TOTAL_SUPPLY in raw 18-decimal token units, already
    ///      equals it. Do not "correct" this with a decimal multiplier;
    ///      doing so would break it.
    function _sqrtPriceX96FromFdv(uint256 fdv) internal pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(fdv, 1 << 192, TOTAL_SUPPLY);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @dev Inverse of the above: FDV in raw quote units implied by a token0-convention sqrtPriceX96.
    function _fdvFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 p = uint256(sqrtPriceX96);
        return Math.mulDiv(p * p, TOTAL_SUPPLY, 1 << 192);
    }

    function _computeTokenAddress(bytes32 salt, bytes32 initCodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _alignToSpacing(int24 tick) internal pure returns (int24) {
        int24 spacing = TICK_SPACING;
        int24 q = tick / spacing;
        int24 r = tick % spacing;
        if (r >= spacing / 2) { q += 1; }
        else if (r <= -spacing / 2) { q -= 1; }
        return q * spacing;
    }

    // ---------------------------------------------------------------- views --

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function getTokens(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = allTokens.length;
        if (offset >= n) return new address[](0);
        uint256 end = Math.min(offset + limit, n);
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) page[i - offset] = allTokens[i];
    }
}
