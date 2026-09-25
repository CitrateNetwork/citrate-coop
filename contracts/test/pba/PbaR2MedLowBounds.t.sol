// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";
import "../../src/CooperativeFiatRamp.sol";

/// PBA-L2-040 (MEDIUM, grouped KNOWN-OPEN prior findings, held on the unreachable
/// prep/rm-q-coop-medlow branch): one regression per item, at the real entry points.
/// New-API calls go through low-level calls so every test compiles (and fails for the finding's
/// reason) against the pre-fix code.

/// Parameter-bound items: B-010, B-018, B-019, COOP-05; B-013 (ramp rescue); B-025 (last admin).
contract PbaR2BoundsMedLowTest is PbaR2Base {
    function setUp() public {
        _deploy(2, 0);
        vm.prank(settler);
        ledger.commitRound(keccak256("r"), keccak256("mh"));
    }

    function _try(address who, address to, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = to.call(data);
    }

    // B-010: dataQualityBps is a basis-point fraction; > 10_000 inflated patronage.
    function test_PBA_L2_040_B010_quality_capped() public {
        assertFalse(_try(settler, address(ledger), abi.encodeWithSelector(PatronageLedger.recordContribution.selector, keccak256("r"), workers[0], uint256(1000), uint16(20_000))), "quality > 100% accepted");
        assertTrue(_try(settler, address(ledger), abi.encodeWithSelector(PatronageLedger.recordContribution.selector, keccak256("r"), workers[0], uint256(1000), uint16(10_000))));
    }

    // B-018: setWeights is bounded to basis points.
    function test_PBA_L2_040_B018_weights_bounded() public {
        assertFalse(_try(admin, address(ledger), abi.encodeWithSelector(PatronageLedger.setWeights.selector, uint16(60_000), uint16(10_000))), "unbounded wCompute");
        assertFalse(_try(admin, address(ledger), abi.encodeWithSelector(PatronageLedger.setWeights.selector, uint16(10_000), uint16(0))), "zero weight erases all patronage");
        assertTrue(_try(admin, address(ledger), abi.encodeWithSelector(PatronageLedger.setWeights.selector, uint16(5_000), uint16(10_000))));
    }

    // B-018: the ramp hold period is bounded (0 erases the ACH-return window; huge freezes credits).
    function test_PBA_L2_040_B018_hold_period_bounded() public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days);
        assertFalse(_try(address(this), address(ramp), abi.encodeWithSelector(CooperativeFiatRamp.setHoldPeriod.selector, uint64(0))), "zero hold accepted");
        assertFalse(_try(address(this), address(ramp), abi.encodeWithSelector(CooperativeFiatRamp.setHoldPeriod.selector, uint64(3650 days))), "decade hold accepted");
        assertTrue(_try(address(this), address(ramp), abi.encodeWithSelector(CooperativeFiatRamp.setHoldPeriod.selector, uint64(7 days))));
    }

    // B-019: an absurd computeMetered let units * accDividendPerUnit overflow and brick the
    // member's dividend accounting; it is capped at record time.
    function test_PBA_L2_040_B019_compute_capped() public {
        assertFalse(_try(settler, address(ledger), abi.encodeWithSelector(PatronageLedger.recordContribution.selector, keccak256("r"), workers[0], uint256(2) ** 200, uint16(10_000))), "absurd compute accepted");
    }

    // COOP-05: reserveBps > 10_000 made distributable() underflow (every claim reverts).
    function test_PBA_L2_040_COOP05_reserve_bps_bounded() public {
        vm.expectRevert();
        new ContributionRewardPool(address(salt), address(ledger), address(kyc), reserveTreasury, 20_000, 365 days);
    }

    // B-013: after dissolution a pending fiat credit can never be released (depositRevenue reverts
    // WrongState); the custodian must be able to charge it back and recover the wSALT.
    function test_PBA_L2_040_B013_ramp_rescue_after_dissolve() public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days);
        address attestor = address(0xA77E);
        ramp.grantRole(ramp.ATTESTOR_ROLE(), attestor);
        salt.mint(address(ramp), 1_000);
        vm.prank(attestor);
        ramp.creditFromFiat(keccak256("ref"), 1_000, 100);
        // the co-op no longer takes revenue (Dissolved in production; Forming here, the same
        // WrongState dead end in depositRevenue), so the release path is dead
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(ModelCooperative.WrongState.selector);
        ramp.release(keccak256("ref"));
        vm.prank(attestor);
        ramp.chargeback(keccak256("ref"));
        address refundTo = address(0xF1A7);
        assertTrue(_try(address(this), address(ramp), abi.encodeWithSignature("withdrawRampFunds(address,uint256)", refundTo, uint256(1_000))), "no rescue path for ramp wSALT");
        assertEq(salt.balanceOf(refundTo), 1_000);
    }

    // B-013 safety twin: the rescue can never touch wSALT backing a still-pending credit.
    function test_PBA_L2_040_B013_rescue_cannot_touch_pending() public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days);
        address attestor = address(0xA77E);
        ramp.grantRole(ramp.ATTESTOR_ROLE(), attestor);
        salt.mint(address(ramp), 1_500);
        vm.prank(attestor);
        ramp.creditFromFiat(keccak256("ref"), 1_000, 100);
        assertFalse(_try(address(this), address(ramp), abi.encodeWithSignature("withdrawRampFunds(address,uint256)", address(0xF1A7), uint256(501))));
    }

    // B-025: Auth had no last-admin guard; revoking the only DEFAULT_ADMIN bricked administration.
    function test_PBA_L2_040_B025_last_admin_cannot_be_revoked() public {
        assertFalse(_try(admin, address(ledger), abi.encodeWithSelector(Auth.revokeRole.selector, bytes32(0), admin)), "last admin revoked");
        assertTrue(ledger.hasRole(0x00, admin));
    }
}

/// PBA-L2-040 bounds tripwires (property tests over the whole input space of each bounded setter).
contract PbaR2BoundsTripwireTest is PbaR2Base {
    function setUp() public {
        _deploy(2, 0);
        vm.prank(settler);
        ledger.commitRound(keccak256("r"), keccak256("mh"));
    }

    function testFuzz_PBA_L2_040_ledger_inputs_bounded(uint256 compute, uint16 q, uint16 wc, uint16 wd) public {
        vm.prank(settler);
        (bool ok,) = address(ledger).call(abi.encodeWithSelector(PatronageLedger.recordContribution.selector, keccak256("r"), workers[0], compute, q));
        assertEq(ok, q <= 10_000 && compute <= 1e30 /* MAX_COMPUTE_PER_RECORD */);
        vm.prank(admin);
        (ok,) = address(ledger).call(abi.encodeWithSelector(PatronageLedger.setWeights.selector, wc, wd));
        assertEq(ok, wc > 0 && wd > 0 && wc <= 10_000 && wd <= 10_000);
    }

    function testFuzz_PBA_L2_040_hold_and_reserve_bounded(uint64 h, uint16 bps) public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days);
        (bool ok,) = address(ramp).call(abi.encodeWithSelector(CooperativeFiatRamp.setHoldPeriod.selector, h));
        assertEq(ok, h >= 1 days && h <= 90 days);
        try new ContributionRewardPool(address(salt), address(ledger), address(kyc), reserveTreasury, bps, 365 days) returns (ContributionRewardPool p) {
            assertLe(bps, 10_000);
            assertLe(p.distributable(), p.ANNUAL());
        } catch {
            assertGt(bps, 10_000);
        }
    }

    /// Ramp rescue never under-backs a pending credit, whatever is credited, charged back or withdrawn.
    function testFuzz_PBA_L2_040_ramp_withdraw_keeps_pending_backed(uint96 fund, uint96 credit, uint96 take, bool chargeBack) public {
        CooperativeFiatRamp ramp = new CooperativeFiatRamp(address(salt), address(coop), 5 days);
        address attestor = address(0xA77E);
        ramp.grantRole(ramp.ATTESTOR_ROLE(), attestor);
        salt.mint(address(ramp), fund);
        vm.prank(attestor);
        (bool ok,) = address(ramp).call(abi.encodeWithSelector(CooperativeFiatRamp.creditFromFiat.selector, keccak256("ref"), uint256(credit), uint32(1)));
        if (ok && chargeBack) {
            vm.prank(attestor);
            ramp.chargeback(keccak256("ref"));
        }
        (ok,) = address(ramp).call(abi.encodeWithSignature("withdrawRampFunds(address,uint256)", address(0xF1A7), uint256(take)));
        assertGe(salt.balanceOf(address(ramp)), ramp.pendingTotal(), "withdrawal under-backed a pending credit");
    }

    /// Whatever grant/revoke sequence the admins run, some DEFAULT_ADMIN always remains.
    function testFuzz_PBA_L2_040_admin_never_stranded(uint256 seed) public {
        address[3] memory who = [admin, address(0xA2), address(0xA3)];
        for (uint256 step = 0; step < 12; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address caller = who[r % 3];
            address subject = who[(r >> 8) % 3];
            vm.prank(caller);
            if ((r >> 16) % 2 == 0) {
                (bool ok,) = address(ledger).call(abi.encodeWithSelector(Auth.grantRole.selector, bytes32(0), subject));
                ok;
            } else {
                (bool ok,) = address(ledger).call(abi.encodeWithSelector(Auth.revokeRole.selector, bytes32(0), subject));
                ok;
            }
        }
        assertTrue(ledger.hasRole(0x00, who[0]) || ledger.hasRole(0x00, who[1]) || ledger.hasRole(0x00, who[2]), "administration stranded");
    }
}
