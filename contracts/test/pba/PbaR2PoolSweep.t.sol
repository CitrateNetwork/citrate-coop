// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-058 (LOW): ContributionRewardPool had no recovery path for SALT that can never be claimed
/// (a cohort closed with zero patronage, forfeited unvested remainders, over-funding), so it was
/// locked forever. The fix adds a bounded sweep to the co-op treasury that can never touch what
/// members are still owed.
contract PbaR2PoolSweepTest is PbaR2Base {
    uint256 constant EXTRA = 1_000 ether; // over-funding above the 50M

    function setUp() public {
        _deploy(4, 0);
        salt.mint(address(pool), pool.TOTAL() + EXTRA);
    }

    function _patronage(bytes32 round, address m, uint256 compute) internal {
        if (ledger.roundMergedHash(round) == bytes32(0)) {
            vm.prank(settler);
            ledger.commitRound(round, keccak256(abi.encode(round)));
        }
        vm.prank(settler);
        ledger.recordContribution(round, m, compute, 10_000);
    }

    function _asCoop(bytes memory data) internal returns (bool ok) {
        vm.prank(address(coop)); // the YEAR_KEEPER (governance caller, PBA-L2-038)
        (ok,) = address(pool).call(data);
    }

    function _close() internal {
        assertTrue(_asCoop(abi.encodeWithSelector(ContributionRewardPool.closeCurrentYear.selector)));
    }

    function _release(address m) internal returns (bool ok) {
        (ok,) = address(pool).call(abi.encodeWithSignature("releaseForfeited(address)", m));
    }

    function _sweep() internal returns (bool ok, uint256 got) {
        uint256 before = salt.balanceOf(reserveTreasury);
        ok = _asCoop(abi.encodeWithSignature("sweepUnallocatable()"));
        got = salt.balanceOf(reserveTreasury) - before;
    }

    /// The finding, inverted: over-funding and a zero-patronage cohort are recoverable.
    function test_PBA_L2_058_unallocatable_salt_is_recoverable() public {
        _patronage(keccak256("r0"), workers[0], 100);
        _close(); // cohort 0: allocated
        _close(); // cohort 1: no patronage -> its whole distributable is unallocatable
        uint256 reserveSoFar = salt.balanceOf(reserveTreasury);
        (bool ok, uint256 got) = _sweep();
        assertTrue(ok, "no recovery path for unclaimable SALT");
        assertEq(got, EXTRA + pool.distributable(), "sweep = over-funding + the empty cohort");
        assertEq(salt.balanceOf(reserveTreasury), reserveSoFar + got);
        // members are still whole: worker0 can claim the full cohort-0 grant after vesting
        vm.warp(block.timestamp + 365 days);
        vm.prank(workers[0]);
        assertEq(pool.claimCRP(), pool.distributable());
    }

    /// A forfeited member's unvested remainder becomes recoverable, and only that remainder.
    function test_PBA_L2_058_forfeited_remainder_recoverable() public {
        _patronage(keccak256("r0"), workers[0], 100);
        _patronage(keccak256("r0"), workers[1], 100);
        _close();
        vm.warp(block.timestamp + 365 days / 4); // 25% vested
        assertTrue(_asCoop(abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, workers[1])));
        _release(workers[1]);
        (bool ok, uint256 got) = _sweep();
        assertTrue(ok);
        uint256 grant = pool.grantOf(0, workers[1]);
        assertEq(got, EXTRA + grant - grant / 4, "sweep = over-funding + 75% unvested of the forfeited grant");
        vm.warp(block.timestamp + 365 days);
        vm.prank(workers[0]);
        assertEq(pool.claimCRP(), pool.grantOf(0, workers[0]));
        vm.prank(workers[1]);
        assertEq(pool.claimCRP(), grant / 4); // already-vested stays claimable
    }

    /// Verifier nit: a cohort the pool never closed (the ledger year advanced outside the pool by an
    /// admin) was never added to allocatedTotal, so releaseForfeited must not release its "grant";
    /// otherwise the obligation is understated and the sweep can reach SALT members are owed.
    function test_PBA_L2_058_release_skips_unclosed_cohort() public {
        _patronage(keccak256("r0"), workers[1], 100);        // year-0 patronage
        bytes32 ledgerKeeper = ledger.YEAR_KEEPER_ROLE();
        vm.prank(admin);
        ledger.grantRole(ledgerKeeper, address(this));
        ledger.advanceYear();                                 // year 0 skipped by the pool (never closed)
        _patronage(keccak256("r1"), workers[0], 100);        // year-1 patronage, not the forfeited member
        _close();                                             // pool closes year 1 -> closedCohorts == 2
        assertEq(pool.yearClosedAt(0), 0);
        assertTrue(_asCoop(abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, workers[1])));
        uint256 before = pool.outstandingObligation();
        assertTrue(_release(workers[1]));
        assertEq(pool.forfeitReleased(), 0, "released a grant from a cohort the pool never closed");
        assertEq(pool.outstandingObligation(), before);
    }

    /// Forfeiture is one-shot: a second forfeit must not restart (extend) vesting.
    function test_PBA_L2_058_forfeit_is_one_shot() public {
        assertTrue(_asCoop(abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, workers[1])));
        uint64 f = pool.forfeitedAt(workers[1]);
        vm.warp(block.timestamp + 30 days);
        assertFalse(_asCoop(abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, workers[1])));
        assertEq(pool.forfeitedAt(workers[1]), f);
    }

    /// Only the year-keeper (governance) may sweep, and only to the co-op treasury.
    function test_PBA_L2_058_sweep_is_governance_only() public {
        vm.prank(address(0xBAD));
        (bool ok,) = address(pool).call(abi.encodeWithSignature("sweepUnallocatable()"));
        assertFalse(ok);
        vm.prank(admin);
        (ok,) = address(pool).call(abi.encodeWithSignature("sweepUnallocatable()"));
        assertFalse(ok);
    }

    /// TRIPWIRE (the audit's "balance - obligations is always recoverable by a named path", plus
    /// its safety twin): under random patronage, closes, forfeits, releases, sweeps and claims,
    /// (1) a sweep never leaves the pool unable to pay every member everything they can still
    /// vest, and (2) after a final sweep only rounding dust (< 1 wei per member per cohort) remains.
    function testFuzz_PBA_L2_058_sweep_never_touches_owed(uint256 seed) public {
        for (uint256 step = 0; step < 16; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            address m = workers[(r >> 8) % 4];
            if (op == 0) {
                if (ledger.currentYear() < 5) _patronage(keccak256(abi.encode("r", step)), m, 1 + ((r >> 16) % 1e6));
            } else if (op == 1) {
                if (ledger.currentYear() < 5) _close();
            } else if (op == 2) {
                _asCoop(abi.encodeWithSelector(ContributionRewardPool.forfeit.selector, m));
                _release(m);
            } else if (op == 3) {
                _sweep();
            } else if (op == 4) {
                vm.prank(m);
                (bool ok,) = address(pool).call(abi.encodeWithSelector(ContributionRewardPool.claimCRP.selector));
                ok;
            } else {
                vm.warp(block.timestamp + ((r >> 16) % 200 days));
            }
        }
        for (uint256 i = 0; i < 4; i++) {
            if (pool.forfeitedAt(workers[i]) != 0) _release(workers[i]);
        }
        _sweep();
        vm.warp(block.timestamp + 5 * 365 days); // everything that can vest has vested
        for (uint256 i = 0; i < 4; i++) {
            uint256 due = pool.claimableOf(workers[i]);
            if (due == 0) continue;
            vm.prank(workers[i]);
            assertEq(pool.claimCRP(), due, "a member could not be paid after a sweep");
        }
        // only closed cohorts' rounding dust and not-yet-closed cohorts remain
        uint256 unclosed = (5 - ledger.currentYear()) * pool.ANNUAL();
        assertLe(salt.balanceOf(address(pool)), unclosed + 4 * 5, "unallocatable SALT left unrecoverable");
    }
}
