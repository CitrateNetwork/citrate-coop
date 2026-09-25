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

    event YearClosed(uint256 indexed year, uint64 closedAt, uint256 reserveSwept);
    event CRPClaimed(address indexed member, uint256 amount);
    event Forfeited(address indexed member, uint64 at);

    error YearOutOfRange();
    error YearAlreadyClosed();
    error NotKyc();
    error Nothing();

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
        uint256 reserve = (ANNUAL * reserveBps) / 10_000;
        reserveTaken += reserve;
        if (reserve > 0) require(salt.transfer(coopTreasury, reserve), "reserve xfer");
        ledger.advanceYear();

        emit YearClosed(y, uint64(block.timestamp), reserve);
    }

    /// @notice Forfeit a member's UNVESTED CRP (governance, expulsion-for-cause). Already-vested
    ///         amounts remain claimable; future vesting stops at `forfeitedAt`.
    function forfeit(address member) external onlyRole(YEAR_KEEPER_ROLE) {
        forfeitedAt[member] = uint64(block.timestamp);
        emit Forfeited(member, uint64(block.timestamp));
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

        if (endRef <= closedAt) return 0; // nothing vested yet
        uint256 elapsed = endRef - closedAt;
        uint256 vested = elapsed >= vestWindow ? grant : (grant * elapsed) / vestWindow;
        uint256 claimed = claimedFromYear[y][member];
        return vested > claimed ? vested - claimed : 0;
    }
}
