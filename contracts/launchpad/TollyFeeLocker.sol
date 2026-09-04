// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INPMLocker {
    struct CollectParams {
        uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max;
    }
    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96, address, address token0, address token1, uint24, int24, int24, uint128,
        uint256, uint256, uint128, uint128
    );
}

interface IFurnaceLock {
    function depositToll(address project, uint256 amount) external;
    /// @dev The Furnace's base asset. Read at wiring time to prove it matches
    ///      this locker's `quote`, see the check in {initialize}.
    function weth() external view returns (address);
}

interface IUniversalForgeLock {
    function universalBurnerForToken(address token) external view returns (address);
    function createUniversalBurner(address token, address launchLocker) external returns (address);
}

/// @title  TollyFeeLocker
/// @author TollyLabs
/// @notice Permanent vault for a launched Uniswap V3 LP position and the fee
///         splitter for its accrued swap fees.
/// @dev    The position NFT is minted directly to this contract at launch and
///         can never leave it: there is no transfer function and no path to
///         `decreaseLiquidity`, so principal is locked permanently. Only
///         accrued swap fees are collectable, and {collect} is permissionless.
///
///         Fee split on the quote (USDC) side: 64% creator, 12% sent to the
///         holder vault with per-project booking attempted, 10% protocol treasury, 9% to
///         the Furnace (buys and burns TOLLY), and 5% to the token's own
///         TollyBurner. The locker does not choose holder recipients or enforce
///         a weighting policy. On the project-token side, 100% is burned outright.
///
///         This locker does not charge a separate 1% toll; that fee applies
///         only to the tools in TollyForge.sol, which serve a different case
///         (a token launched elsewhere redirecting fees it already earns).
///
///         The project-token side is burned rather than routed through a
///         buyback because those fees are already denominated in the
///         project's own token: swapping token for token to "buy back" the
///         same token would only pay fees to convert it into itself. The 5%
///         USDC share is what funds an actual buyback, via the project's
///         burner.
///
///         The toll (in TollyForge.sol) is taken only from the quote side
///         because the Furnace buys TOLLY with its base asset; a toll
///         denominated in a project's own token would require a swap before
///         it could reach the Furnace.
contract TollyFeeLocker is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockedPosition {
        address creator;
        address token0;
        address token1;
    }

    // These five constants define the full quote-side fee split for a launch on
    // this pad. They are `constant` so that none of them, including the deploying
    // team, can be changed after deployment.
    //
    // This is a distinct fee schedule from the 1% toll charged by the tools in
    // TollyForge.sol, which apply to a token launched elsewhere that redirects
    // fees it already earns. The two schedules serve different cases and are not
    // additive.

    /// @notice Share routed to the Furnace to buy and burn TOLLY.
    uint256 public constant TOLLY_BURN_BPS = 900; // 9%
    /// @notice Share routed to the project's own burner, to buy and burn the project token.
    uint256 public constant PROJECT_BURN_BPS = 500; // 5%
    /// @notice Share sent to the holder vault, with booking against this project attempted.
    ///         Reserved from the first collect; recipient selection and any
    ///         weighting policy belong to the separately bound distributor.
    uint256 public constant HOLDER_BPS = 1_200; // 12%
    /// @notice Protocol treasury fee, disclosed and fixed at deployment.
    uint256 public constant PROTOCOL_BPS = 1_000; // 10%
    /// @notice Creator's share of collected quote-side fees.
    uint256 public constant CREATOR_BPS = 6_400; // 64%
    uint256 internal constant BPS = 10_000;

    /// @notice Burn sink. Must be a normal (unspendable) address, OZ ERC20
    ///         reverts on transfers to address(0).
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable pad;
    INPMLocker public immutable positionManager;
    /// @notice The quote asset, USDC on Arc. Named `quote`, not `weth`: this
    ///         protocol is denominated in dollars, and there is no wrapper.
    IERC20 public immutable quote;

    /// @notice The shared Furnace that buys and burns TOLLY. Set once, after
    ///         deployment, because the pad is deployed before the protocol
    ///         (TOLLY itself is launched through the pad as token #0).
    address public furnace;
    /// @notice Resolves each project's own burner. Set at the same time.
    address public universalForge;
    /// @notice Where the protocol fee is delivered. An address here and nothing
    ///         else: the locker can never redirect it, and withdrawal authority
    ///         is governed by that contract, outside this one. This isolates
    ///         treasury ownership rotation from the immutable locker destination;
    ///         it does not make a lost or compromised treasury owner recoverable.
    address public treasury;
    /// @notice Receives the holder-reward reserve. This locker attempts to book
    ///         it per token. Distribution is a separate trust boundary; no
    ///         recipient weighting happens here.
    address public holderVault;
    address public initializer;

    mapping(uint256 => LockedPosition) public positions;

    /// @notice asset => beneficiary => claimable. Holds the creator's
    ///         pull-payments, plus any share that could not be pushed.
    mapping(address => mapping(address => uint256)) public claimable;

    /// @notice Delivery destination for each creator's share on collect. Unset
    ///         (address(0)) means the default pull-payment: the share is parked
    ///         as claimable. Pointed at a Revenue Router or DCA treasury, the
    ///         creator's 64% is delivered there directly; the split percentages
    ///         are unaffected, only the destination of the creator's own share
    ///         changes.
    mapping(address => address) public payoutOf;

    event PositionLocked(uint256 indexed tokenId, address indexed launchedToken, address indexed creator);
    event FeesCollected(uint256 indexed tokenId, address indexed caller, uint256 amount0, uint256 amount1);
    event TollPaid(address indexed project, uint256 amount);
    event ProjectBurnRouted(address indexed project, address indexed burner, uint256 amount);
    event ProjectBurnUnrouted(address indexed project, uint256 amount);
    event FeesClaimed(address indexed asset, address indexed beneficiary, uint256 amount);
    event PayoutSet(address indexed creator, address indexed payout);
    event CreatorPaid(address indexed creator, address indexed payout, uint256 amount);
    event CreatorPayFailed(address indexed creator, address indexed payout, uint256 amount);
    event TokenFeesBurned(address indexed asset, uint256 amount);
    event Initialized(address furnace, address universalForge, address treasury, address holderVault);
    event ProtocolFeePaid(address indexed project, uint256 amount);
    event HolderRewardsAccrued(address indexed project, uint256 amount);

    error OnlyPad();
    error OnlyInitializer();
    error AlreadyInitialized();
    error NotInitialized();
    /// @dev The Furnace's base asset is not this locker's `quote`. See {initialize}.
    error DenominationMismatch();
    error UnknownPosition();
    error NothingToClaim();

    constructor(INPMLocker positionManager_, IERC20 quote_, address initializer_) {
        pad = msg.sender;
        positionManager = positionManager_;
        quote = quote_;
        initializer = initializer_;
    }

    /// @notice Wires the locker to the Tolly protocol. Callable once; after it is
    ///         set, the Furnace destination cannot be changed.
    function initialize(address furnace_, address universalForge_, address treasury_, address holderVault_)
        external
    {
        if (msg.sender != initializer) revert OnlyInitializer();
        if (furnace != address(0)) revert AlreadyInitialized();
        if (furnace_ == address(0) || universalForge_ == address(0)) revert NotInitialized();
        // Same one-shot pattern as the furnace address: these are deployed after
        // the pad, so they are set here rather than in the constructor, and are
        // immutable once set.
        if (treasury_ == address(0) || holderVault_ == address(0)) revert NotInitialized();

        // Denomination check: the Furnace pulls its own base asset in depositToll
        // (`safeTransferFrom(weth, msg.sender, ...)`), while this locker approves
        // and sends `quote`. If the two differ, every {collect} reverts inside
        // depositToll, and collect() is the only path to the fees, so every leg
        // of the split (TOLLY burn, project burn, holder rewards, protocol share,
        // creator share) would become permanently unreachable; the LP would keep
        // accruing fees that can never be harvested.
        //
        // Because `initializer` is burned below on success, this wiring is
        // immutable once set, so the check is enforced here rather than relied
        // upon. The Forge-side siblings enforce the equivalent invariant
        // (`require(address(f.weth()) == _weth, "furnace weth mismatch")`); this
        // mirrors that check for the locker.
        if (IFurnaceLock(furnace_).weth() != address(quote)) revert DenominationMismatch();

        furnace = furnace_;
        universalForge = universalForge_;
        treasury = treasury_;
        holderVault = holderVault_;
        initializer = address(0); // burn the key
        emit Initialized(furnace_, universalForge_, treasury_, holderVault_);
    }

    /// @notice Sets the delivery destination for the caller's creator share
    ///         (a Router, a DCA treasury, a multisig, or any other address).
    ///         Passing address(0) restores the default claim-based payout.
    ///         Self-service and changeable at any time; applies only to the
    ///         creator's own 64% share, never to the other four legs of the split.
    function setPayout(address to) external {
        payoutOf[msg.sender] = to;
        emit PayoutSet(msg.sender, to);
    }

    /// @notice Registers a freshly minted LP position. Pad only.
    function register(uint256 tokenId, address launchedToken, address creator) external {
        if (msg.sender != pad) revert OnlyPad();
        (,, address token0, address token1,,,,,,,,) = positionManager.positions(tokenId);
        positions[tokenId] = LockedPosition({creator: creator, token0: token0, token1: token1});
        emit PositionLocked(tokenId, launchedToken, creator);
    }

    /// @notice Harvests accrued swap fees and splits them. Permissionless.
    /// @dev Reverts before {initialize}. That is deliberate and safe: uncollected
    ///      fees simply stay accrued inside the Uniswap position, which is the
    ///      one place they cannot be misrouted. Nothing is lost by waiting.
    function collect(uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (furnace == address(0)) revert NotInitialized();
        LockedPosition memory pos = positions[tokenId];
        if (pos.creator == address(0)) revert UnknownPosition();

        (amount0, amount1) = positionManager.collect(
            INPMLocker.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        address projectToken = pos.token0 == address(quote) ? pos.token1 : pos.token0;
        _distribute(pos.token0, projectToken, pos.creator, amount0);
        _distribute(pos.token1, projectToken, pos.creator, amount1);

        emit FeesCollected(tokenId, msg.sender, amount0, amount1);
    }

    /// @notice Withdraws the caller's claimable balance of `asset`.
    function claim(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimable[asset][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[asset][msg.sender] = 0;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit FeesClaimed(asset, msg.sender, amount);
    }

    /// @dev The five-way split on the quote side; a straight burn on the token side.
    function _distribute(address asset, address projectToken, address creator, uint256 amount) internal {
        if (amount == 0) return;

        // Project-token side: already denominated in the token, so burn it outright.
        if (asset != address(quote)) {
            IERC20(asset).safeTransfer(DEAD, amount);
            emit TokenFeesBurned(asset, amount);
            return;
        }

        uint256 tollyBurn = (amount * TOLLY_BURN_BPS) / BPS;
        uint256 toBurn = (amount * PROJECT_BURN_BPS) / BPS;
        uint256 toHolders = (amount * HOLDER_BPS) / BPS;
        uint256 toProtocol = (amount * PROTOCOL_BPS) / BPS;
        // The creator receives the remainder, so integer-division rounding dust
        // accrues to the creator rather than to any other leg of the split.
        uint256 toCreator = amount - tollyBurn - toBurn - toHolders - toProtocol;

        // 9% to the Furnace. Approve-then-deposit, since the Furnace pulls funds.
        if (tollyBurn != 0) {
            IERC20(asset).forceApprove(furnace, tollyBurn);
            IFurnaceLock(furnace).depositToll(projectToken, tollyBurn);
            IERC20(asset).forceApprove(furnace, 0);
            emit TollPaid(projectToken, tollyBurn);
        }

        // 10% to the protocol treasury. Plain transfer to an address fixed at
        // initialize; there is no setter, so this share cannot be redirected
        // after wiring.
        if (toProtocol != 0) {
            IERC20(asset).safeTransfer(treasury, toProtocol);
            emit ProtocolFeePaid(projectToken, toProtocol);
        }

        // 12% to the holder-reward reserve for this token. This locker attempts
        // to book it against the project; it neither selects recipients nor
        // implements a weighting policy.
        if (toHolders != 0) {
            IERC20(asset).safeTransfer(holderVault, toHolders);
            // Book the accrual against this project. Non-reverting: a vault that
            // rejects the bookkeeping call must not block collection for the
            // other legs. The funds have already moved to the vault; on failure,
            // HolderRewardsAccrued preserves off-chain evidence of the intended
            // credit, but it does not update the vault's on-chain release ledger.
            (bool booked,) = holderVault.call(
                abi.encodeWithSignature("bookAccrual(address,address,uint256)", projectToken, asset, toHolders)
            );
            booked; // intentionally ignored; the event is evidence, not a ledger write
            emit HolderRewardsAccrued(projectToken, toHolders);
        }

        // 5% to the project's own buyback engine, if one has been created.
        if (toBurn != 0) {
            address burner = IUniversalForgeLock(universalForge).universalBurnerForToken(projectToken);
            if (burner != address(0)) {
                IERC20(asset).safeTransfer(burner, toBurn);
                emit ProjectBurnRouted(projectToken, burner, toBurn);
            } else {
                // No burner exists yet. The share is parked as claimable by the
                // creator rather than transferred elsewhere; the creator can mint
                // a burner (permissionless) and it is routed correctly on the
                // next collect.
                claimable[asset][creator] += toBurn;
                emit ProjectBurnUnrouted(projectToken, toBurn);
            }
        }

        if (toCreator != 0) {
            address to = payoutOf[creator];
            if (to == address(0)) {
                claimable[asset][creator] += toCreator;
            } else {
                // This share has already paid the fees deducted above. If the
                // payout destination is a Tolly tool with its own 1% toll, a
                // plain transfer would be charged that toll again on arrival,
                // which would be the common case for a pad creator routing to a
                // strategy, not an edge case. The prepaid route is attempted
                // first: a tool implementing `depositPrepaid` books the funds
                // toll-exempt.
                // Known limitation: a payout contract can consume the allowance
                // via `depositPrepaid` without retaining the funds (e.g. a
                // self-transfer), which would be recorded as paid while the
                // funds remain uncredited in this contract. This is bounded to
                // creators who point their own payout at a hostile or faulty
                // contract, which was already a way to lose one's share before
                // this mechanism existed, so it is documented rather than
                // guarded against; the guard would be a balance-delta check on
                // `to`, which a legitimate forwarding tool would fail.
                // Measure what the destination took. `allowance == 0` cannot
                // tell "declined" from "took all but one unit", and paying the
                // second case again draws on other creators' `claimable`.
                IERC20(asset).forceApprove(to, toCreator);
                (bool okPre,) = to.call(abi.encodeWithSignature("depositPrepaid(uint256)", toCreator));
                uint256 pulled = okPre ? toCreator - IERC20(asset).allowance(address(this), to) : 0;
                IERC20(asset).forceApprove(to, 0);

                if (pulled > 0) {
                    emit CreatorPaid(creator, to, pulled);
                    toCreator -= pulled;
                }

                if (toCreator > 0) {
                    // Ordinary destination (a wallet, a multisig, or a contract
                    // that does not implement `depositPrepaid`). Non-reverting
                    // push: a payout destination that cannot receive the
                    // transfer must not block collection for other legs, so on
                    // any failure the share is parked as claimable instead.
                    (bool ok, bytes memory ret) =
                        asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, toCreator));
                    if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) {
                        emit CreatorPaid(creator, to, toCreator);
                    } else {
                        claimable[asset][creator] += toCreator;
                        emit CreatorPayFailed(creator, to, toCreator);
                    }
                }
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Accepts native USDC (it is the gas token on Arc).
    receive() external payable {}
}
