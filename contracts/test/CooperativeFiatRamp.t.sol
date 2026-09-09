// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/CooperativeFiatRamp.sol";
import "../src/ModelCooperative.sol";
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

/// @notice Tests for CooperativeFiatRamp (COOP-S1 WP-7, rail C).
///         Maps to features/coop_revenue_routing.feature (fiat scenarios).
///         The off-chain MSB custodian is out of scope; here we test the on-chain half.
contract CooperativeFiatRampTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;
    CooperativeFiatRamp ramp;

    address attestor = address(0xA77E5704);
    address alice = address(0xA11CE);
    uint64 constant HOLD = 5 days;
    bytes32 constant REF = keccak256("stripe:pi_123");

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        coop = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("model"));
        ramp = new CooperativeFiatRamp(address(salt), address(coop), HOLD);

        ledger.grantRole(ledger.SETTLER_ROLE(), address(this));
        ledger.grantRole(ledger.COOP_ROLE(), address(coop));
        coop.setGovernor(address(this));
        ramp.grantRole(ramp.ATTESTOR_ROLE(), attestor);

        // alice = sole patron
        kyc.set(alice, true, keccak256("id:alice"));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(alice, MembershipSBT.MemberClass.Worker, agents);
        bytes32 r = keccak256("r");
        ledger.commitRound(r, keccak256("mh"));
        ledger.recordContribution(r, alice, 1000, 10000);
        coop.activate();

        // custodian funds the ramp with wSALT bought from the fiat
        salt.mint(address(ramp), 1_000_000);
    }

    // coop_revenue_routing: "fiat purchase credits the co-op after the hold period"
    function test_fiat_credit_after_hold() public {
        vm.prank(attestor);
        ramp.creditFromFiat(REF, 1000, 1000 /* $10.00 */);
        // before the hold elapses → cannot release
        vm.expectRevert(CooperativeFiatRamp.HoldNotElapsed.selector);
        ramp.release(REF);
        // after the hold → releases into the dividend
        vm.warp(block.timestamp + HOLD + 1);
        ramp.release(REF);
        assertEq(coop.pendingDividendOf(alice), 1000);
    }

    // coop_revenue_routing: "a chargeback does not claw back distributed dividends"
    function test_chargeback_isolation() public {
        vm.prank(attestor);
        ramp.creditFromFiat(REF, 1000, 1000);
        // chargeback before release → absorbed by ramp reserve, members get nothing
        vm.prank(attestor);
        ramp.chargeback(REF);
        assertEq(ramp.rampReserve(), 1000);
        assertEq(coop.pendingDividendOf(alice), 0);
        // and it can no longer be released
        vm.warp(block.timestamp + HOLD + 1);
        vm.expectRevert(CooperativeFiatRamp.UnknownOrSettled.selector);
        ramp.release(REF);
    }

    // adversarial: a released credit can never be charged back (no clawback from members)
    function test_no_chargeback_after_release() public {
        vm.prank(attestor);
        ramp.creditFromFiat(REF, 1000, 1000);
        vm.warp(block.timestamp + HOLD + 1);
        ramp.release(REF);
        vm.prank(attestor);
        vm.expectRevert(CooperativeFiatRamp.AlreadyReleased.selector);
        ramp.chargeback(REF);
    }

    // adversarial: only the custodian (attestor) can credit
    function test_only_attestor_credits() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        ramp.creditFromFiat(REF, 1000, 1000);
    }
}
