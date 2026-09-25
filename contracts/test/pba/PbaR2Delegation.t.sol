// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-015 (MEDIUM, COOP-B-001): a representative who already carries delegators could delegate
/// onward. They then could not vote (HasDelegated) and their delegators were not re-pointed, so
/// every delegated vote parked on them was silently annihilated.
contract PbaR2DelegationTest is PbaR2Base {
    bytes4 constant REP_HAS_DELEGATORS = bytes4(keccak256("RepresentativeHasDelegators()"));

    function setUp() public {
        _deploy(6, 0);
    }

    function _tryDelegate(address from, address rep) internal returns (bool ok, bytes4 err) {
        vm.prank(from);
        bytes memory ret;
        (ok, ret) = address(gov).call(abi.encodeWithSelector(CooperativeGovernor.delegate.selector, rep));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    /// The audit PoC (test_PBA_onward_delegation_annihilates_votes_still_open), inverted.
    function test_PBA_L2_015_rep_with_delegators_cannot_delegate_onward() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]); // A -> B
        (bool ok, bytes4 err) = _tryDelegate(workers[1], workers[2]); // B -> C must be refused
        assertFalse(ok, "a rep carrying delegators must not delegate onward");
        assertEq(err, REP_HAS_DELEGATORS);
        assertEq(gov.delegatorCount(workers[1]), 1);
        assertEq(gov.delegatorCount(workers[2]), 0);
    }

    /// Once the delegators leave, the former rep may delegate normally.
    function test_PBA_L2_015_rep_can_delegate_after_delegators_leave() public {
        vm.prank(workers[0]);
        gov.delegate(workers[1]);
        vm.prank(workers[0]);
        gov.undelegate();
        vm.prank(workers[1]);
        gov.delegate(workers[2]);
        assertEq(gov.delegatorCount(workers[2]), 1);
    }

    /// TRIPWIRE (the audit's "sum of attainable weight == memberCount"): after any sequence of
    /// delegate/undelegate calls, the weight the active voters can cast (1 + delegators each)
    /// accounts for every member exactly once.
    function testFuzz_PBA_L2_015_attainable_weight_conserved(uint256 seed) public {
        uint256 n = workers.length;
        for (uint256 step = 0; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address from = workers[r % n];
            if ((r >> 8) % 4 == 0) {
                vm.prank(from);
                gov.undelegate();
            } else {
                _tryDelegate(from, workers[(r >> 16) % n]);
            }
        }
        uint256 attainable;
        for (uint256 i = 0; i < n; i++) {
            if (gov.delegateOf(workers[i]) == address(0)) attainable += 1 + gov.delegatorCount(workers[i]);
        }
        assertEq(attainable, sbt.memberCount(), "delegated votes were lost or double counted");
    }
}
