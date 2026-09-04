// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  TollyHolderVault
/// @author TollyLabs
/// @notice Custody and per-project accounting for the holder-reward share of
///         collected fees (the locker's HOLDER_BPS). Balances accrue per project
///         and per asset; payout is delegated to a distributor contract set once
///         after deployment.
/// @dev    This contract holds funds and maintains the `accrued` ledger only; it
///         exposes no owner or setter withdrawal path. While `distributor` is unset,
///         the balance is immobile by construction, which allows accrual to begin
///         before the payout mechanism is deployed and its address is known.
///         Once set, the distributor can both book accrual and release funds from
///         commingled custody. Correctness therefore depends on that one-shot
///         distributor; the per-project ledger is not isolation from a faulty or
///         malicious distributor.
contract TollyHolderVault {
    using SafeERC20 for IERC20;

    /// @notice The distributor authorised to book and move accrued balances for
    ///         payout. Set once by `setter` and immutable thereafter: the address
    ///         cannot be replaced, but its authority is not otherwise reduced by
    ///         the one-shot binding.
    address public distributor;

    /// @notice The account permitted to set `distributor` and `locker`.
    address public immutable setter;

    /// @notice The fee locker authorised to book accruals, in addition to the
    ///         distributor. Set once by `setter`.
    address public locker;

    /// @notice Accrued balance by project, then by asset. Written only by the
    ///         locker and the distributor. `bookAccrual` assumes the corresponding
    ///         asset has already reached the vault; it does not verify a transfer
    ///         or balance delta itself.
    mapping(address => mapping(address => uint256)) public accrued;

    event Accrued(address indexed project, address indexed asset, uint256 amount);
    event DistributorSet(address indexed distributor);
    event LockerSet(address indexed locker);

    error NotSetter();
    error AlreadySet();
    error ZeroAddress();
    error NotDistributor();
    error NotBooker();
    error InsufficientAccrual();

    constructor(address setter_) {
        if (setter_ == address(0)) revert ZeroAddress();
        setter = setter_;
    }

    /// @notice Book funds expected to have already reached the vault against a project.
    /// @dev    Restricted to `locker` and `distributor`, but the transfer is not
    ///         enforced here. An authorised caller that books without funding can
    ///         break the intended invariant
    ///         `sum_p accrued[p][asset] == asset.balanceOf(this)` and let an
    ///         inflated ledger for a dormant project be released, draining the
    ///         commingled balance of live projects.
    function bookAccrual(address project, address asset, uint256 amount) external {
        if (msg.sender != locker && msg.sender != distributor) revert NotBooker();
        if (project == address(0) || asset == address(0)) revert ZeroAddress();
        accrued[project][asset] += amount;
        emit Accrued(project, asset, amount);
    }

    /// @notice Set the payout distributor. Callable once, by `setter`.
    function setDistributor(address distributor_) external {
        if (msg.sender != setter) revert NotSetter();
        if (distributor != address(0)) revert AlreadySet();
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    /// @notice Set the fee locker. Callable once, by `setter`. Must be set at
    ///         deployment, before any collect routes holder rewards to the vault.
    function setLocker(address locker_) external {
        if (msg.sender != setter) revert NotSetter();
        if (locker != address(0)) revert AlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    /// @notice Release a project's recorded accrued balance to the distributor.
    /// @dev    This call is bounded by that project's current ledger entry. Because
    ///         the distributor can also write the ledger and all projects share
    ///         custody, this is an accounting bound, not isolation from a faulty
    ///         or malicious distributor.
    function releaseTo(address project, address asset, uint256 amount) external {
        if (msg.sender != distributor) revert NotDistributor();
        uint256 owed = accrued[project][asset];
        if (amount > owed) revert InsufficientAccrual();
        accrued[project][asset] = owed - amount;
        IERC20(asset).safeTransfer(distributor, amount);
    }

    receive() external payable {}
}
