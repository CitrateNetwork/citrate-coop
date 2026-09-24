// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/ModelCooperative.sol";
import "../../src/PatronageLedger.sol";
import "../../src/MembershipSBT.sol";
import "../mocks/MockERC20.sol";

contract MockKYC is IKYCRegistry {
    mapping(address => bool) public ok;
    mapping(address => bytes32) public id;
    function set(address a, bool v, bytes32 ident) external { ok[a] = v; id[a] = ident; }
    function isVerified(address a) external view returns (bool) { return ok[a]; }
    function identityOf(address a) external view returns (bytes32) { return id[a]; }
}

/// @notice Stateful fuzz handler: random patronage mints, revenue deposits, and claims.
contract Handler is Test {
    ModelCooperative public coop;
    PatronageLedger public ledger;
    MockERC20 public salt;
    address[] public members;
    uint256 public roundNonce;

    constructor(ModelCooperative c, PatronageLedger l, MockERC20 s, address[] memory m) {
        coop = c; ledger = l; salt = s; members = m;
    }

    function addPatronage(uint256 who, uint256 compute, uint16 qBps) external {
        address m = members[who % members.length];
        compute = bound(compute, 0, 1e12);
        qBps = uint16(bound(qBps, 0, 10000));
        bytes32 r = keccak256(abi.encode("r", roundNonce++));
        ledger.commitRound(r, keccak256(abi.encode("mh", r)));
        ledger.recordContribution(r, m, compute, qBps);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        salt.mint(address(this), amount);
        salt.approve(address(coop), amount);
        coop.depositRevenue(amount);
    }

    function claim(uint256 who) external {
        address m = members[who % members.length];
        if (coop.pendingDividendOf(m) == 0) return;
        vm.prank(m);
        coop.claimDividend();
    }

    // SETL-C1: let the fuzzer dissolve the co-op at any point. The solvency invariant must still hold
    // afterwards — i.e. dissolve() may NOT sweep the SALT backing members' unclaimed dividends. Under
    // the old (whole-balance) sweep this broke invariant_solvent.
    function windDownAndDissolve() external {
        if (coop.state() != ModelCooperative.CoopState.Active) return;
        address gov = coop.governor();
        vm.prank(gov); coop.beginWindDown();
        vm.prank(gov); coop.dissolve(address(0xDEAD));
    }

    function pendingSum() external view returns (uint256 s) {
        for (uint256 i = 0; i < members.length; i++) s += coop.pendingDividendOf(members[i]);
    }
}

/// @notice Invariant suite for the dividend accumulator (COOP-S1 WP-3 / g5-audit).
///         Solidity-level mirror of PatronageDividend.tla::Inv_Conservation.
contract DividendConservationTest is Test {
    MockERC20 salt;
    MockKYC kyc;
    MembershipSBT sbt;
    PatronageLedger ledger;
    ModelCooperative coop;
    Handler handler;

    function setUp() public {
        salt = new MockERC20();
        kyc = new MockKYC();
        bytes32[] memory models = new bytes32[](0);
        sbt = new MembershipSBT(address(kyc), models);
        ledger = new PatronageLedger(address(kyc), address(sbt));
        coop = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("model"));
        coop.setGovernor(address(this));

        address[] memory m = new address[](3);
        m[0] = address(0xA1); m[1] = address(0xB2); m[2] = address(0xC3);
        for (uint256 i = 0; i < 3; i++) {
            kyc.set(m[i], true, keccak256(abi.encode("id", m[i])));
            bytes32[] memory agents = new bytes32[](0);
            sbt.mint(m[i], MembershipSBT.MemberClass.Worker, agents);
        }
        coop.activate();

        handler = new Handler(coop, ledger, salt, m);
        ledger.grantRole(ledger.SETTLER_ROLE(), address(handler));
        ledger.grantRole(ledger.COOP_ROLE(), address(coop));

        targetContract(address(handler));
    }

    /// Solvency: the co-op always holds enough SALT to pay every member's pending dividend.
    function invariant_solvent() public view {
        assertGe(salt.balanceOf(address(coop)), handler.pendingSum());
    }

    /// No over-distribution: claimed + still-pending + unallocated never exceeds credited.
    function invariant_no_overdistribution() public view {
        uint256 accountedOut = ledger.totalDividendClaimed() + handler.pendingSum();
        assertLe(accountedOut, ledger.totalRevenueCredited());
    }

    /// Coop SALT balance equals exactly (credited - claimed): every wei is conserved.
    function invariant_balance_is_credited_minus_claimed() public view {
        assertEq(
            salt.balanceOf(address(coop)),
            ledger.totalRevenueCredited() - ledger.totalDividendClaimed()
        );
    }
}
