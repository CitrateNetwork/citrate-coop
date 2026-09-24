// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/ContributionRewardPool.sol";
import "../src/PatronageLedger.sol";
import "../src/MembershipSBT.sol";
import "./mocks/MockERC20.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice Tests for ContributionRewardPool (COOP-S1 WP-5).
///         Maps to features/coop_reward_pool.feature + ContributionRewardPool.tla.
contract ContributionRewardPoolTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ContributionRewardPool pool;

    address treasury = address(0x7EA5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant ANNUAL = 10_000_000 ether;
    uint64 constant VEST = 365 days;
    uint256 roundNonce;

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        pool = new ContributionRewardPool(address(salt), address(ledger), address(kyc), treasury, 2000, VEST);

        // fund the pool with the full 50M emission
        salt.mint(address(pool), 50_000_000 ether);
        // roles
        ledger.grantRole(ledger.SETTLER_ROLE(), address(this));
        ledger.grantRole(ledger.YEAR_KEEPER_ROLE(), address(pool)); // SETL-H1/M3: pool is the (least-privileged) year-keeper
        pool.grantRole(pool.YEAR_KEEPER_ROLE(), address(this));

        _admit(alice);
        _admit(bob);
    }

    function _admit(address a) internal {
        kyc.set(a, true, keccak256(abi.encode("id", a)));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(a, MembershipSBT.MemberClass.Worker, agents);
    }

    function _patronage(address a, uint256 compute) internal {
        bytes32 r = keccak256(abi.encode("round", roundNonce++));
        ledger.commitRound(r, keccak256(abi.encode("mh", r)));
        ledger.recordContribution(r, a, compute, 10000);
    }

    // coop_reward_pool: "reserve is skimmed from the cohort, not from revenue"
    function test_reserve_skim() public {
        assertEq(pool.distributable(), 8_000_000 ether); // 10M - 20%
        _patronage(alice, 100);
        pool.closeCurrentYear();
        assertEq(salt.balanceOf(treasury), 2_000_000 ether); // 20% of 10M
        assertEq(pool.reserveTaken(), 2_000_000 ether);
    }

    // coop_reward_pool: "annual cohort allocated by that year's patronage"
    function test_cohort_prorata() public {
        _patronage(alice, 1000); // 25%
        _patronage(bob, 3000);   // 75%
        pool.closeCurrentYear();
        // grants are of the distributable (8M)
        assertEq(pool.grantOf(0, alice), 2_000_000 ether); // 25% of 8M
        assertEq(pool.grantOf(0, bob), 6_000_000 ether);   // 75% of 8M
    }

    // coop_reward_pool: "grants vest linearly"
    function test_linear_vest() public {
        _patronage(alice, 1000);
        pool.closeCurrentYear();
        // half the window → half vested
        vm.warp(block.timestamp + VEST / 2);
        uint256 half = pool.claimableOf(alice);
        assertApproxEqAbs(half, pool.grantOf(0, alice) / 2, 1e9);
        // full window → fully vested, claimable in full
        vm.warp(block.timestamp + VEST / 2);
        assertEq(pool.claimableOf(alice), pool.grantOf(0, alice));

        vm.prank(alice);
        uint256 got = pool.claimCRP();
        assertEq(got, pool.grantOf(0, alice));
        assertEq(salt.balanceOf(alice), got);
    }

    // coop_reward_pool: "unvested grant is forfeitable on expulsion-for-cause"
    function test_forfeit_unvested() public {
        _patronage(alice, 1000);
        pool.closeCurrentYear();
        vm.warp(block.timestamp + VEST / 4); // 25% vested
        pool.forfeit(alice);                 // stop the clock
        vm.warp(block.timestamp + VEST);     // time passes, but forfeited
        uint256 grant = pool.grantOf(0, alice);
        assertApproxEqAbs(pool.claimableOf(alice), grant / 4, 1e12); // only the 25% vested at forfeit
    }

    // ContributionRewardPool.tla::Inv_TotalCap / Inv_NoOverEmission
    function test_total_cap_never_exceeded() public {
        // run all 5 cohorts, each fully patronized by alice
        for (uint256 y = 0; y < 5; y++) {
            _patronage(alice, 1000);
            pool.closeCurrentYear();
        }
        vm.warp(block.timestamp + VEST + 1); // everything vested
        vm.prank(alice);
        uint256 got = pool.claimCRP();
        // alice claims all 5 cohorts' distributable = 5 * 8M = 40M; reserve = 5 * 2M = 10M
        assertEq(got, 40_000_000 ether);
        assertEq(pool.reserveTaken(), 10_000_000 ether);
        assertEq(pool.totalGrantsClaimed() + pool.reserveTaken(), 50_000_000 ether); // exactly the cap
    }

    // adversarial: only the year-keeper closes a cohort
    function test_only_keeper_closes_year() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        pool.closeCurrentYear();
    }

    // adversarial: a 6th cohort close is out of range (only 5 cohorts exist)
    function test_sixth_year_out_of_range() public {
        for (uint256 y = 0; y < 5; y++) pool.closeCurrentYear();
        vm.expectRevert(ContributionRewardPool.YearOutOfRange.selector);
        pool.closeCurrentYear();
    }
}
