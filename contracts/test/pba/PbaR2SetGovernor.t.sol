// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-019 (MEDIUM, COOP-B-005): setGovernor had no once-guard, so DEFAULT_ADMIN could re-point
/// the co-op's governor at any time and run lifecycle, admission and expulsion around the members.
contract PbaR2SetGovernorTest is PbaR2Base {
    function setUp() public {
        _deploy(3, 0);
    }

    function _trySet(address caller, address g) internal returns (bool ok) {
        return _trySetOn(coop, caller, g);
    }

    function _trySetOn(ModelCooperative m, address caller, address g) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(m).call(abi.encodeWithSelector(ModelCooperative.setGovernor.selector, g));
    }

    /// The finding's trace, inverted: the admin (the AdminSafe in production) cannot re-point the
    /// governor of a factory-wired co-op.
    function test_PBA_L2_019_admin_cannot_repoint_governor() public {
        assertTrue(coop.hasRole(coop.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(_trySet(admin, address(0xE7)), "setGovernor must be one-shot");
        assertEq(coop.governor(), c.governor);
    }

    /// The one legitimate call (factory wiring) still works on a fresh co-op, and a zero governor is refused.
    function test_PBA_L2_019_first_set_works_zero_refused() public {
        ModelCooperative fresh = new ModelCooperative(address(salt), address(kyc), address(ledger), keccak256("m"));
        assertFalse(_trySetOn(fresh, address(this), address(0)), "zero governor must be refused");
        assertTrue(_trySetOn(fresh, address(this), address(0x60)));
        assertEq(fresh.governor(), address(0x60));
        assertFalse(_trySetOn(fresh, address(this), address(0x61)));
        assertEq(fresh.governor(), address(0x60));
    }

    /// TRIPWIRE: after factory wiring the governor is immutable for every caller and every value.
    function testFuzz_PBA_L2_019_governor_immutable(address caller, address g) public {
        _trySet(caller, g);
        vm.prank(admin);
        (bool ok,) = address(coop).call(abi.encodeWithSelector(ModelCooperative.setGovernor.selector, g));
        assertFalse(ok);
        assertEq(coop.governor(), c.governor);
    }
}
