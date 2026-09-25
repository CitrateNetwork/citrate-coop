// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./lib/Auth.sol";
import "./lib/IERC20.sol";
import "./MembershipSBT.sol"; // IKYCRegistry
import "./PatronageLedger.sol";

/// @title ContributionRewardPool — the 50M SALT emission (RFC-CIT-COOP-0001)
/// @notice 5% of supply = 50,000,000 SALT, released 10M/year for 5 years, each cohort
///         allocated by THAT year's patronage (read from PatronageLedger), linearly
///         vested, with a reserve skim from each cohort to the co-op treasury.
///         No founder equity (ADR-0004). The pool is the sole year-keeper of the ledger.
/// @dev Formal: specs/tla/coop/ContributionRewardPool.tla. Feature: features/coop_reward_pool.feature.
contract ContributionRewardPool is Auth {
    bytes32 public constant YEAR_KEEPER_ROLE = keccak256("YEAR_KEEPER_ROLE"); // the co-op (governance via execute), PBA-L2-038

    uint256 public constant ANNUAL = 10_000_000 ether; // 10M SALT
    uint8 public constant YEARS = 5;                    // 50M total
    uint256 public constant TOTAL = uint256(YEARS) * ANNUAL;

    IERC20 public immutable salt;
    PatronageLedger public immutable ledger;
    IKYCRegistry public immutable kyc;
    // SETL-H2: the reserve recipient. MUST be a treasury distinct from the ModelCooperative — the
    // factory asserts `reserveTreasury != address(coop)` so the held reserve is never reclassified as
    // member dividends by ModelCooperative.syncDirectRevenue.
    address public immutable coopTreasury; // reserve recipient (separate co-op treasury, NOT the coop)

    uint16 public reserveBps;        // skim from each cohort (default 20% = 2M/yr)
    uint64 public vestWindow;        // linear vest duration per cohort (default 365d)

    mapping(uint256 => uint64) public yearClosedAt;             // year => close timestamp (vest start)
    mapping(uint256 => mapping(address => uint256)) public claimedFromYear;
    mapping(address => uint64) public forfeitedAt;             // member => forfeiture time (0 = none)
    uint256 public reserveTaken;
    uint256 public totalGrantsClaimed;

    // PBA-L2-058: bookkeeping for the bounded sweep of SALT no member can ever claim.
    uint256 public closedCohorts;    // cohorts closed so far (== ledger.currentYear, the pool is sole keeper)
    uint256 public allocatedTotal;   // sum of distributable() over closed cohorts that had patronage
    uint256 public forfeitReleased;  // unvested remainders of forfeited grants, released from the obligation
    mapping(uint256 => mapping(address => bool)) public forfeitSettled; // year => member => released

    event YearClosed(uint256 indexed year, uint64 closedAt, uint256 reserveSwept);
    event CRPClaimed(address indexed member, uint256 amount);
    event Forfeited(address indexed member, uint64 at);
    event ForfeitReleased(address indexed member, uint256 year, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error YearOutOfRange();
    error YearAlreadyClosed();
    error NotKyc();
    error Nothing();
    error AlreadyForfeited(); // PBA-L2-058: forfeiture is one-shot (re-forfeiting would extend vesting)
    error NotForfeited();
    error BadReserveBps(); // PBA-L2-040 COOP-05: > 10_000 made distributable() underflow

    constructor(
        address salt_,
        address ledger_,
        address kyc_,
        address coopTreasury_,
        uint16 reserveBps_,
        uint64 vestWindow_
    ) {
        salt = IERC20(salt_);
        ledger = PatronageLedger(ledger_);
        kyc = IKYCRegistry(kyc_);
        coopTreasury = coopTreasury_;
        if (reserveBps_ > 10_000) revert BadReserveBps();
        reserveBps = reserveBps_;
        vestWindow = vestWindow_;
    }

    /// @notice Member-distributable amount per cohort (ANNUAL minus the reserve skim).
    function distributable() public view returns (uint256) {
        return ANNUAL - (ANNUAL * reserveBps) / 10_000;
    }

    /// @notice Close the current cohort: skim its reserve to the co-op treasury, stamp the
    ///         vest start, and advance the ledger's year. The pool is the sole year-keeper.
    function closeCurrentYear() external onlyRole(YEAR_KEEPER_ROLE) {
        uint256 y = ledger.currentYear();
        if (y >= YEARS) revert YearOutOfRange();
        if (yearClosedAt[y] != 0) revert YearAlreadyClosed();

        yearClosedAt[y] = uint64(block.timestamp);
        closedCohorts = y + 1;
        // A cohort closed with zero patronage allocates nothing: its distributable is unclaimable.
        if (ledger.yearTotalUnits(y) != 0) allocatedTotal += distributable();
        uint256 reserve = (ANNUAL * reserveBps) / 10_000;
        reserveTaken += reserve;
        if (reserve > 0) require(salt.transfer(coopTreasury, reserve), "reserve xfer");
        ledger.advanceYear();

        emit YearClosed(y, uint64(block.timestamp), reserve);
    }

    /// @notice Forfeit a member's UNVESTED CRP (governance, expulsion-for-cause). Already-vested
    ///         amounts remain claimable; future vesting stops at `forfeitedAt`.
    function forfeit(address member) external onlyRole(YEAR_KEEPER_ROLE) {
        // PBA-L2-058: one-shot. A later second forfeit would move forfeitedAt forward and re-vest
        // SALT that releaseForfeited already returned to the sweepable surplus (pool insolvency).
        if (forfeitedAt[member] != 0) revert AlreadyForfeited();
        forfeitedAt[member] = uint64(block.timestamp);
        emit Forfeited(member, uint64(block.timestamp));
    }

    /// @notice PBA-L2-058: release a forfeited member's UNVESTED remainder (per closed cohort, once)
    ///         from the pool's obligation, so the sweep can recover it. Permissionless and idempotent:
    ///         it only ever moves SALT the member can no longer vest. Call again after later cohorts
    ///         close (their whole grant is unvested for a member forfeited before the close).
    function releaseForfeited(address member) external returns (uint256 released) {
        uint64 f = forfeitedAt[member];
        if (f == 0) revert NotForfeited();
        for (uint256 y = 0; y < closedCohorts; y++) {
            if (forfeitSettled[y][member]) continue;
            forfeitSettled[y][member] = true;
            uint256 grant = grantOf(y, member);
            uint256 unvested = grant - _vestedAt(y, grant, f);
            if (unvested > 0) {
                released += unvested;
                emit ForfeitReleased(member, y, unvested);
            }
        }
        forfeitReleased += released;
    }

    /// @notice SALT the pool still owes (or will owe): every allocated closed cohort in full, every
    ///         not-yet-closed cohort at ANNUAL (its reserve is not skimmed yet), less what was
    ///         claimed and what forfeiture released. Rounding dust inside allocated cohorts stays
    ///         counted, so the bound is conservative.
    function outstandingObligation() public view returns (uint256) {
        return allocatedTotal + (uint256(YEARS) - closedCohorts) * ANNUAL - totalGrantsClaimed - forfeitReleased;
    }

    /// @notice PBA-L2-058: sweep SALT no member can ever claim (zero-patronage cohorts, released
    ///         forfeited remainders, over-funding) to the co-op treasury. Governance only (the
    ///         year-keeper), fixed destination, and bounded by outstandingObligation() so it can never
    ///         reach SALT a member is owed.
    function sweepUnallocatable() external onlyRole(YEAR_KEEPER_ROLE) returns (uint256 amount) {
        uint256 bal = salt.balanceOf(address(this));
        uint256 owed = outstandingObligation();
        if (bal <= owed) revert Nothing();
        amount = bal - owed;
        require(salt.transfer(coopTreasury, amount), "sweep xfer");
        emit Swept(coopTreasury, amount);
    }

    /// @notice Claim all vested CRP across closed cohorts. KYC re-checked at claim.
    function claimCRP() external returns (uint256 total) {
        if (!kyc.isVerified(msg.sender)) revert NotKyc();
        uint256 lastYear = ledger.currentYear(); // years [0, lastYear) may be closed
        uint256 bound_ = lastYear < YEARS ? lastYear : YEARS;
        for (uint256 y = 0; y < bound_; y++) {
            uint256 amt = _claimableYear(y, msg.sender);
            if (amt > 0) {
                claimedFromYear[y][msg.sender] += amt;
                total += amt;
            }
        }
        if (total == 0) revert Nothing();
        totalGrantsClaimed += total;
        require(salt.transfer(msg.sender, total), "claim xfer");
        emit CRPClaimed(msg.sender, total);
    }

    /// @notice The amount currently claimable by `member` across all closed cohorts.
    function claimableOf(address member) external view returns (uint256 total) {
        uint256 lastYear = ledger.currentYear();
        uint256 bound_ = lastYear < YEARS ? lastYear : YEARS;
        for (uint256 y = 0; y < bound_; y++) total += _claimableYear(y, member);
    }

    /// @notice A member's total grant for cohort `y` (pro-rata by that year's patronage).
    function grantOf(uint256 y, address member) public view returns (uint256) {
        uint256 denom = ledger.yearTotalUnits(y);
        if (denom == 0) return 0;
        return (distributable() * ledger.yearUnits(y, member)) / denom;
    }

    function _claimableYear(uint256 y, address member) internal view returns (uint256) {
        uint64 closedAt = yearClosedAt[y];
        if (closedAt == 0) return 0; // cohort not closed → not yet vesting
        uint256 grant = grantOf(y, member);
        if (grant == 0) return 0;

        uint256 endRef = block.timestamp;
        uint64 f = forfeitedAt[member];
        if (f != 0 && f < endRef) endRef = f; // vesting stops at forfeiture

        uint256 vested = _vestedAt(y, grant, endRef);
        uint256 claimed = claimedFromYear[y][member];
        return vested > claimed ? vested - claimed : 0;
    }

    /// @dev The part of `grant` (cohort `y`) vested by time `t` (linear from the cohort close).
    function _vestedAt(uint256 y, uint256 grant, uint256 t) internal view returns (uint256) {
        uint64 closedAt = yearClosedAt[y];
        if (closedAt == 0 || t <= closedAt) return 0;
        uint256 elapsed = t - closedAt;
        return elapsed >= vestWindow ? grant : (grant * elapsed) / vestWindow;
    }
}
