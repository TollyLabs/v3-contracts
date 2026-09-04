// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  TollyToken
/// @author TollyLabs
/// @notice Fixed-supply ERC-20 minted entirely to the pad at genesis. No
///         owner, no mint, no pause, no blacklist, and no transfer tax. Its only
///         additional transfer rule is the temporary anti-snipe cap below.
/// @dev    The only deviation from a vanilla ERC-20 is a time-boxed anti-snipe
///         max-wallet cap: for a fixed window after launch, no non-exempt
///         address may end a transfer holding more than `maxWallet` tokens.
///         This throttles bots from acquiring the single-sided launch supply
///         in the first blocks. The cap is enforced solely on the receiving
///         balance, exempts the launch infrastructure (pad, pool, position
///         manager, locker), and becomes a no-op once `antiSnipeDeadline`
///         passes, so it never affects normal trading afterward.
///
///         The window is measured in seconds, not blocks, so its duration is
///         fixed on chain regardless of block time and does not need to be
///         estimated off chain from the chain's block interval. The deadline is
///         a coarse launch guard, not a timing source for financial settlement.
///
contract TollyToken is ERC20 {
    /// @notice The launchpad that deployed this token (holds the full supply at genesis).
    address public immutable pad;
    /// @notice Max tokens a non-exempt wallet may hold during the anti-snipe window.
    uint256 public immutable maxWallet;
    /// @notice Unix timestamp (inclusive) through which the max-wallet cap is
    ///         enforced. Expressed in absolute time so the window's duration
    ///         is fixed on chain and does not need to be inferred off chain.
    uint256 public immutable antiSnipeDeadline;

    /// @notice Addresses exempt from the anti-snipe cap (launch infrastructure).
    mapping(address => bool) public antiSnipeExempt;

    /// @notice The token's Uniswap V3 pool. Set once by the pad after the pool
    ///         is created, since its address is not known at construction time.
    address public pool;

    error OnlyPad();
    error PoolAlreadySet();
    error MaxWalletExceeded();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address pad_,
        address positionManager_,
        address locker_,
        uint256 maxWallet_,
        uint256 antiSnipeSeconds_
    ) ERC20(name_, symbol_) {
        pad = pad_;
        maxWallet = maxWallet_;
        antiSnipeDeadline = block.timestamp + antiSnipeSeconds_;

        antiSnipeExempt[pad_] = true;
        antiSnipeExempt[positionManager_] = true;
        antiSnipeExempt[locker_] = true;

        _mint(pad_, supply_);
    }

    /// @notice One-time hook for the pad to register the pool as exempt once it
    ///         exists. The pool must be exempt because it custodies nearly the
    ///         entire supply as single-sided LP.
    function setPool(address pool_) external {
        if (msg.sender != pad) revert OnlyPad();
        if (pool != address(0)) revert PoolAlreadySet();
        pool = pool_;
        antiSnipeExempt[pool_] = true;
    }

    /// @dev Enforces the max-wallet cap on the recipient, active only during
    ///      the anti-snipe window.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (block.timestamp <= antiSnipeDeadline && to != address(0) && !antiSnipeExempt[to]) {
            if (balanceOf(to) > maxWallet) revert MaxWalletExceeded();
        }
    }
}
