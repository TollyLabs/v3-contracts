// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  TollyTreasury
/// @author TollyLabs
/// @notice Destination for the protocol's fee share (the locker's
///         PROTOCOL_BPS). The locker has no setter for this destination; the
///         address is fixed at the locker's initialization and cannot
///         subsequently be changed by the locker or any other party.
/// @dev    Governance is deliberately isolated to this contract rather than
///         the locker. The two-step transfer protects against handing ownership
///         to a mistyped address because the recipient must accept. It does not
///         recover a lost or compromised current owner: a lost owner strands the
///         held balance and future fee stream at this fixed destination. Had the
///         locker instead taken a settable destination address, a compromised
///         key there could redirect every project's protocol share at once. The
///         contract is
///         deliberately minimal: hold, withdraw, hand over ownership. No
///         upgrade path, no delegatecall, no arbitrary external calls, so the
///         only asset reachable by an attacker is the held balance itself.
contract TollyTreasury {
    using SafeERC20 for IERC20;

    address public owner;
    address public pendingOwner;

    event Withdrawn(address indexed asset, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Withdraw an ERC-20 balance held by this contract.
    /// @dev    An `amount` of 0 is treated as the full balance; this is the
    ///         common case and avoids a read-then-write race between querying
    ///         the balance and submitting the withdrawal.
    function withdraw(address asset, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 amt = (amount == 0 || amount > bal) ? bal : amount;
        if (amt == 0) return;
        IERC20(asset).safeTransfer(to, amt);
        emit Withdrawn(asset, to, amt);
    }

    /// @notice Withdraw the native-currency balance held by this contract.
    /// @dev    Relevant on chains where the quote asset is also the gas token
    ///         (on Arc, USDC is both). Same zero-amount-means-full-balance
    ///         semantics as {withdraw}.
    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        uint256 amt = (amount == 0 || amount > bal) ? bal : amount;
        if (amt == 0) return;
        (bool ok,) = to.call{value: amt}("");
        require(ok, "native transfer failed");
        emit Withdrawn(address(0), to, amt);
    }

    /// @notice Begin a two-step ownership transfer by nominating `to` as
    ///         pending owner.
    /// @dev    A single-step transfer to a mistyped address could permanently
    ///         strand the protocol's revenue. Requiring the nominated address
    ///         to call {acceptOwnership} prevents that specific transfer error;
    ///         it does not provide recovery if the current owner's key is lost.
    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }

    receive() external payable {}
}
