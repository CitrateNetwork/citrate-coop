// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./lib/Auth.sol";
import "./lib/IERC20.sol";

interface ICoopRevenue {
    function depositRevenue(uint256 amount) external;
}

/// @title CooperativeFiatRamp — rail C: Stripe/Plaid fiat → on-chain revenue (RFC-CIT-COOP-0001)
/// @notice On-chain half of the fiat ramp. A licensed MSB custodian takes USD (Stripe cards /
///         Plaid ACH), converts to wSALT, funds this ramp, and signs a settlement attestation
///         that escrows a credit here. After a hold period (≥ the ACH-return window) anyone may
///         release it into the co-op's patronage dividend. A chargeback BEFORE release is
///         absorbed by the ramp reserve; an already-released credit is never clawed back from
///         members. See ADR-0006. The off-chain custodian + oracle wiring is owner-gated (WP-7).
/// @dev Feature: features/coop_revenue_routing.feature (rail C scenarios).
contract CooperativeFiatRamp is Auth {
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE"); // custodian key

    enum Status { None, Pending, Released, ChargedBack }

    struct Credit {
        uint256 amount;     // wSALT
        uint64 releaseAt;   // now + holdPeriod
        uint32 usdCents;    // record for reconciliation / reporting
        Status status;
    }

    IERC20 public immutable salt;
    ICoopRevenue public immutable coop;
    /// PBA-L2-040 B-018: the hold must cover the ACH-return window but never freeze credits for good.
    uint64 public constant MIN_HOLD = 1 days;
    uint64 public constant MAX_HOLD = 90 days;

    uint64 public holdPeriod;     // e.g. 5 business days for ACH
    uint256 public rampReserve;   // wSALT absorbing chargebacks/returns
    uint256 public pendingTotal;  // wSALT owed to not-yet-released pending credits

    mapping(bytes32 => Credit) public credits; // settlement ref => credit

    event FiatCredited(bytes32 indexed ref, uint256 amount, uint32 usdCents, uint64 releaseAt);
    event FiatReleased(bytes32 indexed ref, uint256 amount);
    event FiatChargedBack(bytes32 indexed ref, uint256 amount);
    event RampFundsWithdrawn(address indexed to, uint256 amount);
    event HoldPeriodSet(uint64 holdPeriod);

    error UnknownOrSettled();
    error HoldNotElapsed();
    error AlreadyReleased();
    error InsufficientRampFunds();
    error BadHoldPeriod();
    error ZeroRecipient();

    constructor(address salt_, address coop_, uint64 holdPeriod_) {
        salt = IERC20(salt_);
        coop = ICoopRevenue(coop_);
        if (holdPeriod_ < MIN_HOLD || holdPeriod_ > MAX_HOLD) revert BadHoldPeriod();
        holdPeriod = holdPeriod_;
    }

    /// @notice Custodian attests a settled fiat payment; escrows a pending wSALT credit.
    ///         The ramp must already hold the wSALT (custodian funded it from the fiat).
    function creditFromFiat(bytes32 ref, uint256 wSaltAmount, uint32 usdCents)
        external
        onlyRole(ATTESTOR_ROLE)
    {
        if (credits[ref].status != Status.None) revert UnknownOrSettled();
        // funds backing all pending credits + the reserve + this one must be on hand
        if (salt.balanceOf(address(this)) < pendingTotal + rampReserve + wSaltAmount) {
            revert InsufficientRampFunds();
        }
        pendingTotal += wSaltAmount;
        credits[ref] = Credit({
            amount: wSaltAmount,
            releaseAt: uint64(block.timestamp) + holdPeriod,
            usdCents: usdCents,
            status: Status.Pending
        });
        emit FiatCredited(ref, wSaltAmount, usdCents, uint64(block.timestamp) + holdPeriod);
    }

    /// @notice After the hold period, release a pending credit into the co-op dividend.
    function release(bytes32 ref) external {
        Credit storage cr = credits[ref];
        if (cr.status != Status.Pending) revert UnknownOrSettled();
        if (block.timestamp < cr.releaseAt) revert HoldNotElapsed();
        cr.status = Status.Released;
        pendingTotal -= cr.amount;
        salt.approve(address(coop), cr.amount);
        coop.depositRevenue(cr.amount);
        emit FiatReleased(ref, cr.amount);
    }

    /// @notice Custodian charges back a pending (un-released) credit. Funds stay in the ramp
    ///         reserve; nothing was credited to members. An already-released credit cannot be
    ///         charged back — the loss is the ramp's, never the members'.
    function chargeback(bytes32 ref) external onlyRole(ATTESTOR_ROLE) {
        Credit storage cr = credits[ref];
        if (cr.status == Status.Released) revert AlreadyReleased();
        if (cr.status != Status.Pending) revert UnknownOrSettled();
        cr.status = Status.ChargedBack;
        pendingTotal -= cr.amount;
        rampReserve += cr.amount; // absorbed by the ramp, not clawed from dividends
        emit FiatChargedBack(ref, cr.amount);
    }

    function setHoldPeriod(uint64 h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (h < MIN_HOLD || h > MAX_HOLD) revert BadHoldPeriod();
        holdPeriod = h;
        emit HoldPeriodSet(h);
    }

    /// @notice PBA-L2-040 B-013: the ramp had no way out for wSALT once the co-op stopped taking
    ///         revenue (after Dissolved, release() reverts forever). The admin (the custodian's
    ///         AdminSafe) may withdraw anything NOT backing a still-pending credit: charged-back
    ///         reserve (to refund the payer) and over-funding. Pending credits stay fully backed.
    function withdrawRampFunds(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroRecipient();
        uint256 bal = salt.balanceOf(address(this));
        if (bal < pendingTotal || amount > bal - pendingTotal) revert InsufficientRampFunds();
        rampReserve -= amount < rampReserve ? amount : rampReserve;
        require(salt.transfer(to, amount), "withdraw xfer");
        emit RampFundsWithdrawn(to, amount);
    }
}
