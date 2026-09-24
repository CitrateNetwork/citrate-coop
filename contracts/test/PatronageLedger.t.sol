// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice Tests for PatronageLedger (COOP-S1 WP-2).
///         Maps to features/coop_patronage.feature + PatronageDividend/CoopLifecycle.tla.
contract PatronageLedgerTest is Test {
    PatronageLedger ledger;
    MembershipSBT sbt;
    MockKYC kyc;
    address alice = address(0xA11CE);
    bytes32 round = keccak256("round-1");
    bytes32 mergedHash = keccak256("merged-hash-1");

    function setUp() public {
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        // this test contract is admin → grant itself the settler + coop + year-keeper roles
        ledger.grantRole(ledger.SETTLER_ROLE(), address(this));
        ledger.grantRole(ledger.COOP_ROLE(), address(this));
        ledger.grantRole(ledger.YEAR_KEEPER_ROLE(), address(this)); // SETL-H1: advanceYear now needs this
        // alice is a KYC-verified worker-member
        kyc.set(alice, true, keccak256("identity:alice"));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
    }

    // coop_patronage: "patronage unit equals compute times data quality"
    function test_unit_is_compute_times_quality() public {
        ledger.commitRound(round, mergedHash);
        ledger.recordContribution(round, alice, 1000, 5000); // 50% quality
        assertEq(ledger.units(alice), 500); // 1000 * 0.50
    }

    // coop_patronage: "zero data-quality score yields zero patronage units"
    function test_zero_quality_zero_units() public {
        ledger.commitRound(round, mergedHash);
        ledger.recordContribution(round, alice, 1000, 0);
        assertEq(ledger.units(alice), 0);
    }

    // coop_patronage: "patronage is anchored to a verified round"
    function test_requires_committed_round() public {
        vm.expectRevert(PatronageLedger.RoundNotCommitted.selector);
        ledger.recordContribution(round, alice, 1000, 10000);
    }

    // coop_patronage: "a contribution is counted at most once"
    function test_idempotent() public {
        ledger.commitRound(round, mergedHash);
        ledger.recordContribution(round, alice, 1000, 10000);
        vm.expectRevert(PatronageLedger.DoubleCount.selector);
        ledger.recordContribution(round, alice, 1000, 10000);
    }

    // coop_patronage: "patronage closes at wind-down" (CoopLifecycle.tla::Inv_ContribClosedAfterWind)
    function test_window_closed() public {
        ledger.commitRound(round, mergedHash);
        ledger.closeContributionWindow(); // co-op enters WindingDown
        vm.expectRevert(PatronageLedger.WindowClosed.selector);
        ledger.recordContribution(round, alice, 1000, 10000);
    }

    // --- adversarial (FEATURE step 6) ---

    function test_only_settler_records() public {
        ledger.commitRound(round, mergedHash);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        ledger.recordContribution(round, alice, 1000, 10000);
    }

    function test_non_member_rejected() public {
        address stranger = address(0x57A4);
        kyc.set(stranger, true, keccak256("identity:stranger")); // KYC ok but not a member
        ledger.commitRound(round, mergedHash);
        vm.expectRevert(PatronageLedger.NotMember.selector);
        ledger.recordContribution(round, stranger, 1000, 10000);
    }

    function test_per_year_accounting() public {
        ledger.commitRound(round, mergedHash);
        ledger.recordContribution(round, alice, 1000, 10000); // year 0
        assertEq(ledger.yearUnits(0, alice), 1000);
        ledger.advanceYear();
        bytes32 r2 = keccak256("round-2");
        ledger.commitRound(r2, keccak256("mh2"));
        ledger.recordContribution(r2, alice, 2000, 10000); // year 1
        assertEq(ledger.yearUnits(1, alice), 2000);
        assertEq(ledger.units(alice), 3000); // lifetime
    }

    function testFuzz_units_monotonic(uint64 compute, uint16 qualityBps) public {
        qualityBps = uint16(bound(qualityBps, 0, 10000));
        ledger.commitRound(round, mergedHash);
        ledger.recordContribution(round, alice, compute, qualityBps);
        assertEq(ledger.units(alice), (uint256(compute) * qualityBps) / 10000);
        assertEq(ledger.totalUnits(), ledger.units(alice));
    }

    // SETL-H1/M3: advanceYear is gated by the DEDICATED YEAR_KEEPER_ROLE, not the broad COOP_ROLE.
    // A COOP_ROLE holder (e.g. the ModelCooperative) can no longer advance the cohort year and skip
    // the ContributionRewardPool's vest-start stamp — which used to strand a whole cohort's grant.
    function test_advanceYear_requires_year_keeper_not_coop_role() public {
        address coopOnly = address(0xC00B);
        bytes32 ykRole = ledger.YEAR_KEEPER_ROLE(); // precompute BEFORE the prank (else it consumes it)
        ledger.grantRole(ledger.COOP_ROLE(), coopOnly); // has COOP_ROLE but NOT the year-keeper role
        vm.expectRevert(abi.encodeWithSelector(Auth.Unauthorized.selector, ykRole, coopOnly));
        vm.prank(coopOnly);
        ledger.advanceYear();

        // granting the dedicated role lets it through
        ledger.grantRole(ledger.YEAR_KEEPER_ROLE(), coopOnly);
        vm.prank(coopOnly);
        ledger.advanceYear();
        assertEq(ledger.currentYear(), 1);
    }
}
