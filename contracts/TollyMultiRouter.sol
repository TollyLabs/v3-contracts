// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IFurnace {
    function depositToll(address project, uint256 amount) external;
    function weth() external view returns (address);
}

/// The pad's own registry: `pool != 0` means we launched this token.
interface IPadTokens {
    function tokens(address) external view returns (address creator, address pool, uint256 lpTokenId);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title  TollyMultiRouter
/// @author TollyLabs
///
/// @notice Swaps one token for another through a single Uniswap V3 pool or a
///         single Uniswap V2 pair, taking a 0.2% interface fee to the Tolly
///         Furnace in the same transaction.
///
/// @dev    Fee rule: charged only when the input is the quote asset, and never
///         on a token launched by the pad. Both conditions are evaluated on
///         chain by `tollFor`, which is public so a caller can be quoted the
///         figure the swap will apply.
///
///         Properties this contract is built to hold:
///
///         - It custodies nothing. Every token that enters in a call leaves in
///           the same call, and swap output is sent to the trader directly.
///         - No owner, no setter, no upgrade path, no rescue function.
///         - `FEE_BPS` is a compile-time constant, so an allowance granted here
///           is an allowance to these economics permanently.
///         - The single `transferFrom` hardcodes `from = msg.sender`: an
///           allowance can be spent by nobody but the account that granted it.
///         - Every amount is measured from balances rather than assumed, so a
///           token that delivers less than it was sent cannot leave a remainder
///           behind.
///         - `_isOurs` fails closed: a pad that cannot be read yields no fee.
///
///         Scope is deliberately one pool in one direction. Multi-hop and
///         exact-output are out of scope.
///
///         The quote asset on this deployment is both the native gas token at
///         18 decimals and an ERC-20 at 6, and its transfer executes no code at
///         the recipient. Native units may therefore be pushed here by anyone;
///         balance-delta measurement means such a balance is never read, never
///         swapped and never counted.
contract TollyMultiRouter {
    using SafeERC20 for IERC20;

    /// @notice Interface fee in basis points of the input.
    /// @dev    `constant`, not `immutable` and not settable. A user approving
    ///         this contract is approving these exact economics forever.
    uint256 public constant FEE_BPS = 20;
    uint256 private constant BPS = 10_000;

    /// @notice Upper bound on the V2 swap fee accepted as a parameter.
    /// @dev    A sanity bound rather than a policy: it keeps the constant-
    ///         product arithmetic away from its degenerate end. The trader is
    ///         protected by `amountOutMinimum`, not by this.
    uint16 public constant MAX_V2_FEE_BPS = 1_000;

    /// @notice The V3 SwapRouter02. Immutable by design.
    address public immutable SWAP_ROUTER;
    /// @notice The Furnace. Interface fees have no other destination.
    address public immutable FURNACE;
    /// @notice The quote asset (USDC on Arc).
    address public immutable QUOTE;
    /// @notice The pad registry, consulted only to classify a token.
    address public immutable PAD;

    error ZeroAddress();
    error NothingReceived();
    error NothingToSwap();
    error QuoteMismatch();
    error Reentrancy();
    error PadUnreadable();
    error NoPair();
    error FeeTooHigh();
    error InsufficientOutput();

    event SwappedWithToll(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 toll,
        uint256 amountOut,
        uint8 venue // 3 = Uniswap V3, 2 = a Uniswap V2 fork
    );

    constructor(address swapRouter_, address furnace_, address quote_, address pad_) {
        if (swapRouter_ == address(0) || furnace_ == address(0) || quote_ == address(0) || pad_ == address(0)) {
            revert ZeroAddress();
        }
        // The Furnace pulls the asset it is configured with; a mismatch would
        // revert every fee-bearing swap for the life of the contract.
        if (IFurnace(furnace_).weth() != quote_) revert QuoteMismatch();
        // The pad must answer. Since `_isOurs` fails closed, an unreadable pad
        // would otherwise yield a router that charges nothing, permanently.
        (bool padOk, bytes memory padRet) = pad_.staticcall(
            abi.encodeWithSelector(IPadTokens.tokens.selector, address(0))
        );
        if (!padOk || padRet.length < 96) revert PadUnreadable();
        SWAP_ROUTER = swapRouter_;
        FURNACE = furnace_;
        QUOTE = quote_;
        PAD = pad_;
    }

    /// @notice The interface fee that `amountIn` of `tokenIn` would be charged.
    /// @dev    Identical on both venues: the rule is a property of the trade,
    ///         not of where it executes.
    function tollFor(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        // The Furnace accepts the quote asset, which only a buy pays in.
        if (tokenIn != QUOTE) return 0;
        // A pad launch already pays a share of its pool fee to the Furnace.
        if (_isOurs(tokenOut)) return 0;
        // Integer division floors to zero below 1/FEE_BPS of a unit, which is
        // intended: `depositToll` rejects zero and a swap must not revert over
        // a rounding artefact.
        return (amountIn * FEE_BPS) / BPS;
    }

    /// @notice The constant-product output for `amountIn` at `feeBps`, with the
    ///         fee taken off the input.
    /// @dev    Exposed so a caller can quote from the same arithmetic the swap
    ///         will execute.
    function v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint16 feeBps)
        public
        pure
        returns (uint256)
    {
        if (feeBps > MAX_V2_FEE_BPS) revert FeeTooHigh();
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inAfterFee = amountIn * (BPS - feeBps);
        return (inAfterFee * reserveOut) / (reserveIn * BPS + inAfterFee);
    }

    /// @dev Whether the pad launched this token. Any failure of the static call
    ///      is treated as "cannot tell", which `tollFor` reads as "do not
    ///      charge".
    ///
    ///      The word is masked by hand rather than decoded: a successful return
    ///      whose address word carries dirty upper bits would make `abi.decode`
    ///      revert in this frame, and this frame is reached from a swap.
    function _isOurs(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) = PAD.staticcall(
            abi.encodeWithSelector(IPadTokens.tokens.selector, token)
        );
        if (!ok || ret.length < 96) return true; // unreadable: assume ours, charge nothing
        uint256 word;
        assembly ("memory-safe") { word := mload(add(ret, 0x40)) } // the `pool` slot
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(word) != 0;
    }

    /// @dev Transient reentrancy guard (EIP-1153).
    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(0) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @dev Pulls the input, measures what arrived, and banks the fee. Shared
    ///      by both venues so the rule cannot diverge between them.
    ///
    ///      The amount is measured because a fee-on-transfer input delivers less
    ///      than it was sent; every figure downstream is the measured one, so
    ///      no remainder can be left in this contract.
    function _pullAndBank(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 received, uint256 toll, uint256 toSwap)
    {
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        received = IERC20(tokenIn).balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        toll = tollFor(tokenIn, tokenOut, received);
        if (toll > 0) {
            // forceApprove: a token that rejects a non-zero to non-zero
            // allowance change would otherwise break this path on reuse.
            IERC20(tokenIn).forceApprove(FURNACE, toll);
            IFurnace(FURNACE).depositToll(tokenIn == QUOTE ? tokenOut : tokenIn, toll);
            // Cleared even though it is consumed exactly: no standing
            // allowance survives a call.
            IERC20(tokenIn).forceApprove(FURNACE, 0);
        }

        toSwap = received - toll;
        if (toSwap == 0) revert NothingToSwap();
    }

    /// @notice Swaps through one Uniswap V3 pool, taking the interface fee.
    /// @param  amountOutMinimum the caller's slippage floor, passed through
    ///         untouched and enforced by the V3 router.
    function swapWithToll(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external nonReentrant returns (uint256 amountOut) {
        (uint256 received, uint256 toll, uint256 toSwap) = _pullAndBank(tokenIn, tokenOut, amountIn);

        // `toSwap` is non-zero by the check in `_pullAndBank`, and must stay
        // so: SwapRouter02 reads `amountIn == 0` as a sentinel meaning "spend
        // this contract's own balance".
        IERC20(tokenIn).forceApprove(SWAP_ROUTER, toSwap);
        amountOut = ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                // The output never touches this contract.
                recipient: msg.sender,
                amountIn: toSwap,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(SWAP_ROUTER, 0);

        emit SwappedWithToll(msg.sender, tokenIn, tokenOut, received, toll, amountOut, 3);
    }

    /// @notice Swaps through one Uniswap V2 pair, taking the interface fee.
    ///
    /// @param  factory the pair's factory. The pair is derived from it, never
    ///         accepted as a parameter.
    /// @param  feeBps  that pair's swap fee, which V2 exposes no getter for.
    ///         Either error is safe: too high asks the pair for less than it
    ///         would give and the output floor catches it, too low makes the
    ///         pair's own invariant check revert.
    ///
    /// @dev    `factory` is caller-supplied, so the pair it names is untrusted
    ///         code and the computed output is not evidence of anything. The
    ///         floor is therefore enforced against the trader's own balance
    ///         delta: the call reverts unless they were actually paid.
    function swapWithTollV2(
        address tokenIn,
        address tokenOut,
        address factory,
        uint16 feeBps,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external nonReentrant returns (uint256 amountOut) {
        if (factory == address(0)) revert ZeroAddress();
        if (feeBps > MAX_V2_FEE_BPS) revert FeeTooHigh();

        address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert NoPair();

        (uint256 received, uint256 toll, uint256 toSwap) = _pullAndBank(tokenIn, tokenOut, amountIn);

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        bool inIsToken0 = IUniswapV2Pair(pair).token0() == tokenIn;
        (uint256 reserveIn, uint256 reserveOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // PRICED AGAINST THE STORED RESERVE, DELIBERATELY, AND NOT AGAINST THE
        // PAIR'S BALANCE.
        //
        // The two differ by whatever a pair holds unsynced, which is a quantity
        // any stranger can raise for free and take back with `skim`. Pricing
        // off it would put a manipulable absolute balance in the middle of a
        // quote, and it would cost the trader that ratio on every fill even
        // when nobody is attacking: the reserve is also what an off-chain quote
        // reads, so the two would disagree by a number outside our control.
        //
        // Against a pair that credits `balance - reserve` this asks for less
        // than it would give, which its own invariant accepts. Against one that
        // credits only what arrives -- which is what the forks here do -- it is
        // exact.
        uint256 pairBefore = IERC20(tokenIn).balanceOf(pair);

        // V2 has no `transferFrom` step of its own: the pair pays out whatever
        // the caller has already given it, so the input goes to the pair first
        // and `swap` is what releases the other side.
        IERC20(tokenIn).safeTransfer(pair, toSwap);

        // What the pair was actually credited. A fee-on-transfer input delivers
        // less than it was sent, and computing on the sent figure asks the pair
        // for more than its invariant allows, which reverts.
        uint256 delivered = IERC20(tokenIn).balanceOf(pair) - pairBefore;
        if (delivered == 0) revert NothingToSwap();

        uint256 expected = v2AmountOut(delivered, reserveIn, reserveOut, feeBps);
        if (expected == 0) revert NothingToSwap();

        uint256 outBefore = IERC20(tokenOut).balanceOf(msg.sender);
        IUniswapV2Pair(pair).swap(
            inIsToken0 ? 0 : expected,
            inIsToken0 ? expected : 0,
            msg.sender,
            ""
        );
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - outBefore;
        // ZERO IS NOT A FILL, whatever floor the caller passed.
        //
        // On the V3 path the venue is derived from the token pair, so a floor
        // of zero costs at most the depth of a real pool. Here the venue is
        // named by the caller, so the balance delta is the ONLY evidence that
        // anything happened, and `0 < 0` is false -- a pair that keeps the
        // input and pays nothing would otherwise return success.
        if (amountOut == 0) revert NothingReceived();
        if (amountOut < amountOutMinimum) revert InsufficientOutput();

        emit SwappedWithToll(msg.sender, tokenIn, tokenOut, received, toll, amountOut, 2);
    }
}
