// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
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

/// @notice Tests for ModelCooperative (COOP-S1 WP-3).
///         Maps to coop_revenue_dividend.feature + CoopLifecycle/PatronageDividend.tla.
contract ModelCooperativeTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 roundNonce;

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        coop = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("model"));

        ledger.grantRole(ledger.SETTLER_ROLE(), address(this));
        ledger.grantRole(ledger.COOP_ROLE(), address(coop));
        coop.setGovernor(address(this)); // test acts as governor

        _admit(alice);
        _admit(bob);
        coop.activate();
    }

    function _admit(address a) internal {
        kyc.set(a, true, keccak256(abi.encode("id", a)));
        bytes32[] memory agents = new bytes32[](0);
        sbt.mint(a, MembershipSBT.MemberClass.Worker, agents);
    }

    function _patronage(address a, uint256 compute) internal {
        bytes32 r = keccak256(abi.encode("round", roundNonce++));
        ledger.commitRound(r, keccak256(abi.encode("mh", r)));
        ledger.recordContribution(r, a, compute, 10000); // 100% quality → units == compute
    }

    function _deposit(uint256 amount) internal {
        salt.mint(address(this), amount);
        salt.approve(address(coop), amount);
        coop.depositRevenue(amount);
    }

    // coop_revenue_dividend: "revenue is distributed pro-rata by patronage"
    function test_dividend_prorata() public {
        _patronage(alice, 1000);
        _patronage(bob, 3000);
        _deposit(4000);
        assertEq(coop.pendingDividendOf(alice), 1000);
        assertEq(coop.pendingDividendOf(bob), 3000);

        vm.prank(alice);
        coop.claimDividend();
        assertEq(salt.balanceOf(alice), 1000);
    }

    // coop_revenue_dividend: "no retroactive dividend for late contributors"
    function test_no_retroactive() public {
        _patronage(alice, 1000);
        _deposit(1000);                 // all to alice
        _patronage(bob, 1000);          // bob joins AFTER the first distribution
        assertEq(coop.pendingDividendOf(bob), 0); // nothing from the earlier revenue
        _deposit(2000);                 // split 50/50 now
        assertEq(coop.pendingDividendOf(bob), 1000);
        assertEq(coop.pendingDividendOf(alice), 2000); // 1000 earlier + 1000 now
    }

    // coop_revenue_dividend: "claims are KYC-gated at claim time"
    function test_claim_kyc_gated() public {
        _patronage(alice, 1000);
        _deposit(1000);
        kyc.set(alice, false, keccak256(abi.encode("id", alice))); // revoked after accruing
        vm.prank(alice);
        vm.expectRevert(ModelCooperative.NotKyc.selector);
        coop.claimDividend();
    }

    // coop_revenue_dividend: "claim is recorded for patronage-dividend reporting"
    function test_claim_emits_record() public {
        _patronage(alice, 1000);
        _deposit(1000);
        vm.expectEmit(true, false, false, true);
        emit ModelCooperative.DividendClaimed(alice, 1000);
        vm.prank(alice);
        coop.claimDividend();
    }

    // CoopLifecycle.tla::Inv_NoRevenueBeforeActive — revenue can't be taken while Forming
    function test_revenue_before_active_reverts() public {
        ModelCooperative fresh = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("m2"));
        fresh.setGovernor(address(this));
        salt.mint(address(this), 100);
        salt.approve(address(fresh), 100);
        vm.expectRevert(ModelCooperative.WrongState.selector);
        fresh.depositRevenue(100); // still Forming
    }

    // CoopLifecycle.tla::Inv_ContribClosedAfterWind — wind-down closes the window
    function test_winddown_closes_contributions() public {
        assertTrue(ledger.contributionsOpen());
        coop.beginWindDown();
        assertFalse(ledger.contributionsOpen());
        // and a new contribution now reverts
        bytes32 r = keccak256("late-round");
        ledger.commitRound(r, keccak256("mh"));
        vm.expectRevert(PatronageLedger.WindowClosed.selector);
        ledger.recordContribution(r, alice, 1000, 10000);
    }

    // adversarial: only the governor drives lifecycle
    function test_only_governor_lifecycle() public {
        ModelCooperative fresh = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("m3"));
        fresh.setGovernor(address(0x60));
        vm.expectRevert(ModelCooperative.NotGovernor.selector);
        fresh.activate();
    }

    // conservation at the unit level: everyone claims → coop holds only dust (0 here)
    function test_conservation_after_full_claim() public {
        _patronage(alice, 1000);
        _patronage(bob, 3000);
        _deposit(4000);
        vm.prank(alice); coop.claimDividend();
        vm.prank(bob); coop.claimDividend();
        assertEq(salt.balanceOf(address(coop)), 0); // all 4000 distributed
        assertEq(ledger.totalDividendClaimed(), 4000);
    }

    // --- SETL-C1: dissolve() must NOT sweep unclaimed member dividends ---

    // The core regression: a member who has not yet claimed can STILL claim their full dividend
    // after the co-op is dissolved. Under the old code (sweep the whole balance) this reverted.
    function test_dissolve_preserves_unclaimed_member_dividends() public {
        _patronage(alice, 1000);
        _patronage(bob, 3000);
        _deposit(4000); // alice owed 1000, bob owed 3000 — none claimed yet
        coop.beginWindDown();
        coop.dissolve(address(0xDEAD)); // residual treasury

        // The owed floor (4000) stayed in the contract, so both claims still pay out in full.
        vm.prank(alice); coop.claimDividend();
        vm.prank(bob); coop.claimDividend();
        assertEq(salt.balanceOf(alice), 1000);
        assertEq(salt.balanceOf(bob), 3000);
        assertEq(salt.balanceOf(address(0xDEAD)), 0); // nothing was owed-free to sweep
    }

    // The surplus ABOVE the owed floor (e.g. a stray direct transfer) IS swept to residual, while
    // the owed dividends remain claimable.
    function test_dissolve_sweeps_only_surplus_above_owed_floor() public {
        _patronage(alice, 1000);
        _deposit(1000);                 // alice owed 1000 (owed floor)
        salt.mint(address(coop), 500);  // a stray 500 SALT, never credited → pure surplus
        coop.beginWindDown();
        coop.dissolve(address(0xDEAD));
        assertEq(salt.balanceOf(address(0xDEAD)), 500); // only the surplus swept
        vm.prank(alice); coop.claimDividend();
        assertEq(salt.balanceOf(alice), 1000);          // dividend intact
    }

    // --- SETL-C2: execute() may not reach the ledger or the SALT treasury ---

    function test_execute_cannot_credit_unbacked_revenue_on_ledger() public {
        // The old hole: governor mints dividends with no SALT deposited.
        bytes memory data = abi.encodeCall(PatronageLedger.creditRevenue, (1_000_000 ether));
        vm.expectRevert(ModelCooperative.ExecForbidden.selector);
        coop.execute(address(ledger), 0, data);
    }

    function test_execute_cannot_drain_the_salt_treasury() public {
        salt.mint(address(coop), 5000);
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", address(0xBAD), 5000);
        vm.expectRevert(ModelCooperative.ExecForbidden.selector);
        coop.execute(address(salt), 0, data);
        assertEq(salt.balanceOf(address(coop)), 5000); // untouched
    }

    // execute() to any OTHER target still works (governance's legitimate use).
    function test_execute_allows_non_money_targets() public {
        Dummy d = new Dummy();
        coop.execute(address(d), 0, abi.encodeCall(Dummy.ping, ()));
        assertEq(d.pinged(), 1);
    }

    // --- SETL-M1: no revenue credited before units exist (no first-minter windfall) ---

    function test_deposit_reverts_before_any_units() public {
        salt.mint(address(this), 1000);
        salt.approve(address(coop), 1000);
        vm.expectRevert(PatronageLedger.NoUnits.selector);
        coop.depositRevenue(1000); // totalUnits == 0 → cannot credit
        // once units exist, revenue distributes pro-rata (no concentration on the first member)
        _patronage(alice, 1000);
        _patronage(bob, 1000);
        _deposit(2000);
        assertEq(coop.pendingDividendOf(alice), 1000);
        assertEq(coop.pendingDividendOf(bob), 1000);
    }

    // --- SETL-M2: earned dividends are vested — claim needs KYC, not membership ---

    function test_expelled_member_can_still_claim_earned_dividends() public {
        _patronage(alice, 1000);
        _deposit(1000); // alice owed 1000
        sbt.expel(alice); // this test holds REGISTRAR_ROLE → alice is no longer a member
        assertFalse(sbt.isMember(alice));
        vm.prank(alice);
        coop.claimDividend(); // vested earnings survive expulsion (membership NOT re-checked)
        assertEq(salt.balanceOf(alice), 1000);
    }

    function test_kyc_loss_does_not_confiscate_earned_dividends() public {
        _patronage(alice, 1000);
        _deposit(1000);
        kyc.set(alice, false, keccak256(abi.encode("id", alice))); // KYC revoked
        vm.prank(alice);
        vm.expectRevert(ModelCooperative.NotKyc.selector);
        coop.claimDividend();
        assertEq(coop.pendingDividendOf(alice), 1000); // still owed, not confiscated
        kyc.set(alice, true, keccak256(abi.encode("id", alice))); // KYC restored
        vm.prank(alice);
        coop.claimDividend();
        assertEq(salt.balanceOf(alice), 1000); // claimable again, full amount
    }
}

/// A benign execute() target for the C2 allow-path test.
contract Dummy {
    uint256 public pinged;
    function ping() external { pinged += 1; }
}
