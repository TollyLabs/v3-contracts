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

/// @title  TollySwapRouter
/// @author TollyLabs
///
/// @notice Swap through Arc's shared Uniswap V3 in one transaction, paying a
///         0.2% interface fee to the Tolly Furnace on the way. The fee is
///         charged only when the input is the quote asset and only on tokens
///         that were not launched on Tolly; anything else pays nothing.
///
/// @dev    THE CONTRACT HOLDS NOTHING. Every token entering in a call leaves in
///         the same call, and the swap output goes straight to the trader
///         without touching this contract. There is no owner, no setter, no
///         upgrade path and no rescue function -- a rescue function is an owner
///         by another name, and with nothing held there is nothing to rescue.
///         `FEE_BPS` is a compile-time constant, so an approval to this
///         contract is an approval to these economics permanently.
///
///         The only `transferFrom` hardcodes `from = msg.sender`, so an
///         allowance granted here can be spent by nobody but its owner.
///
///         ON ARC, "holds nothing" needs one qualification. USDC is both the
///         native gas token (18 decimals) and an ERC-20 (6 decimals), and its
///         `transfer` moves value through a node precompile that executes no
///         code at the recipient -- so an absent `receive()` is never consulted
///         and anyone may push native USDC here. It is not exploitable: the
///         balance-delta measurement below means a donation is invisible to
///         every calculation, never swapped and never counted. It simply sits,
///         unreachable by anyone including us.
///
///         DELIBERATELY ABSENT: multi-hop, exactOutput, and any path that is
///         not one pool in one direction. Every extra route is extra surface
///         for a fee that is 0.2%.
///
contract TollySwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Interface fee in basis points of the input.
    /// @dev    `constant`, not `immutable` and not settable. A user approving
    ///         this contract is approving these exact economics forever.
    uint256 public constant FEE_BPS = 20;
    uint256 private constant BPS = 10_000;

    /// @notice Arc's shared SwapRouter02. Immutable: a swap router that could be
    ///         repointed is a contract that can be told to send funds anywhere.
    address public immutable SWAP_ROUTER;
    /// @notice The Furnace. Fees go here and nowhere else.
    address public immutable FURNACE;
    /// @notice The quote asset (USDC on Arc).
    /// @dev    The fee is charged ONLY when this is the input. The Furnace takes
    ///         the quote asset, so a sell -- which pays in the project token --
    ///         has nothing to give it, and taking a cut of one would mean
    ///         holding that token and swapping it, which is custody. Encoding
    ///         the rule here rather than in the frontend makes it structural:
    ///         a caller cannot ask to be charged on the wrong side.
    address public immutable QUOTE;
    /// @notice The pad. Used to answer one question: did WE launch this token?
    /// @dev    See `tollFor`. Immutable and read-only; this contract never
    ///         calls anything that writes.
    address public immutable PAD;

    error ZeroAddress();
    error NothingReceived();
    error NothingToSwap();
    error QuoteMismatch();
    error Reentrancy();
    error PadUnreadable();

    event SwappedWithToll(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 toll,
        uint256 amountOut
    );

    constructor(address swapRouter_, address furnace_, address quote_, address pad_) {
        if (swapRouter_ == address(0) || furnace_ == address(0) || quote_ == address(0) || pad_ == address(0)) {
            revert ZeroAddress();
        }
        // The Furnace pulls ITS asset, not ours. Mismatched, every buy reverts
        // forever while sells keep working -- a half-dead contract with no owner
        // to fix it. The Furnace's own constructor sets this precedent by
        // refusing to deploy without its pool.
        if (IFurnace(furnace_).weth() != quote_) revert QuoteMismatch();
        // AND PROVE THE PAD ANSWERS. `_isOurs` fails closed, so a pad that
        // cannot be read would produce a router charging nobody, forever,
        // silently and immutably. A zero-address check does not catch that.
        (bool padOk, bytes memory padRet) = pad_.staticcall(
            abi.encodeWithSelector(IPadTokens.tokens.selector, address(0))
        );
        if (!padOk || padRet.length < 96) revert PadUnreadable();
        SWAP_ROUTER = swapRouter_;
        FURNACE = furnace_;
        QUOTE = quote_;
        PAD = pad_;
    }

    /// @notice What `amountIn` of `tokenIn` would be charged.
    /// @dev    Pure and public so a frontend and this contract can never
    ///         disagree about the number, and so the quote a user is shown is
    ///         the one the chain will apply.
    function tollFor(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        // A sell pays in the project token and the Furnace takes the quote, so
        // there is nothing to give it. Structural rather than a frontend rule:
        // a caller cannot ask to be charged on a side we cannot bank.
        if (tokenIn != QUOTE) return 0;
        // AND NOT ON OUR OWN LAUNCHES. A token launched on Tolly already pays
        // 1% to its pool, split five ways with 9% of it buying and burning
        // TOLLY. Charging 0.2% on top would be taking twice for one trade.
        //
        // Fails CLOSED: a pad that cannot be read yields no fee at all, because
        // the cost of guessing wrong in the other direction is charging a user
        // for something they do not owe.
        if (_isOurs(tokenOut)) return 0;
        uint256 t = (amountIn * FEE_BPS) / BPS;
        // Integer division floors, so anything under 500 units of input pays
        // nothing. That is deliberate: `depositToll` rejects zero, and charging
        // a rounding artefact would revert a user's whole swap over a fraction
        // of a cent.
        return t;
    }

    /// @dev Did the pad launch this token? A static call that treats ANY failure
    ///      as "cannot tell", which `tollFor` reads as "do not charge".
    ///
    ///      THE WORD IS READ BY HAND, not with `abi.decode`. A call that
    ///      SUCCEEDS with 96 bytes whose address words carry dirty upper bits
    ///      makes `abi.decode` revert INSIDE this frame -- and this frame is
    ///      reached from a swap, so a fee calculation would take the user's
    ///      trade down with it. That is failing OPEN into a denial of service,
    ///      in the exact case the sentence above promises is handled. Masking
    ///      to 160 bits cannot revert and cannot be fooled by the high bits.
    ///
    ///      Not reachable at the intended pad, whose `tokens` is an
    ///      auto-generated getter returning exactly 96 clean bytes.
    function _isOurs(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) = PAD.staticcall(
            abi.encodeWithSelector(IPadTokens.tokens.selector, token)
        );
        if (!ok || ret.length < 96) return true; // unreadable: assume ours, charge nothing
        uint256 word;
        assembly ("memory-safe") { word := mload(add(ret, 0x40)) } // the `pool` slot
        return uint160(word) != 0;
    }

    /// @dev Transient reentrancy guard (EIP-1153; Arc is a Prague-era chain).
    ///      No theft path is known: every frame satisfies
    ///      `delta = received - toll - toSwap = 0`, and `received` is a delta so
    ///      nested frames contribute exactly zero. The guard is here because
    ///      that argument rests on SwapRouter02's payer semantics and on V3
    ///      paying the recipient BEFORE its callback, neither of which this
    ///      contract controls.
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

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut`, paying the interface
    ///         fee to the Furnace in the same transaction.
    /// @dev    ATTRIBUTION IS DERIVED, NOT ACCEPTED. The token the fee is
    ///         booked against is `tokenOut`, computed here. There is no
    ///         caller-supplied project argument, because one would let somebody
    ///         pay a real fee and book it against any address they liked,
    ///         inflating a counter that is read as a record of contribution.
    /// @param  amountOutMinimum the caller's slippage floor. Passed through
    ///         untouched: this contract never chooses it, and a zero here is the
    ///         caller's own decision to make.
    function swapWithToll(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external nonReentrant returns (uint256 amountOut) {
        // Measure rather than assume. A fee-on-transfer token delivers less than
        // it was sent, and every figure below has to be what ARRIVED or this
        // contract ends the call still holding something.
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        uint256 toll = tollFor(tokenIn, tokenOut, received);
        if (toll > 0) {
            // forceApprove, not approve: a token that reverts on a non-zero to
            // non-zero allowance change (USDT-style) would otherwise brick this
            // path the second time it is used.
            IERC20(tokenIn).forceApprove(FURNACE, toll);
            // The traded token, whichever side it is on.
            IFurnace(FURNACE).depositToll(tokenIn == QUOTE ? tokenOut : tokenIn, toll);
            // The allowance is consumed exactly, but clear it anyway: a Furnace
            // that ever pulled less than it was approved would leave a standing
            // allowance from this contract, and standing allowances are how a
            // contract that holds nothing starts holding something.
            IERC20(tokenIn).forceApprove(FURNACE, 0);
        }

        uint256 toSwap = received - toll;
        // NEVER hand SwapRouter02 a zero. `Constants.CONTRACT_BALANCE == 0`, so
        // it reads `amountIn == 0` as "swap my OWN balance, payer = self" --
        // with the output going to our caller. Unreachable while the fee is
        // 20 bps of the input, but it is unreachable by arithmetic somewhere
        // else in the file, which is the kind of protection that disappears the
        // day somebody edits the fee.
        if (toSwap == 0) revert NothingToSwap();
        IERC20(tokenIn).forceApprove(SWAP_ROUTER, toSwap);
        amountOut = ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                // STRAIGHT TO THE TRADER. The output never touches this
                // contract, so there is no window in which it holds the thing
                // people came for.
                recipient: msg.sender,
                amountIn: toSwap,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
        // A router that consumed less than approved would leave this contract
        // standing behind an allowance it does not need.
        IERC20(tokenIn).forceApprove(SWAP_ROUTER, 0);

        emit SwappedWithToll(msg.sender, tokenIn, tokenOut, received, toll, amountOut);
    }
}
