// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-016 (HIGH, COOP-B-002): quorum read the LIVE memberCount and proposals never expired, so a
/// sub-quorum (failed) proposal became executable once the electorate shrank, at any later time.
contract PbaR2QuorumSnapshotTest is PbaR2Base {
    function setUp() public {
        _deploy(10, 0); // 10 workers -> quorum = ceil(10 * 33%) = 4
    }

    /// The audit's trace, turned into a test and inverted: 3 Yes of 10 is below quorum (4). Expelling
    /// two members who never voted drops the live count to 8 (quorum 3). Before the fix the failed
    /// proposal then passed and executed. It must stay failed.
    function test_PBA_L2_016_expel_does_not_revive_failed_proposal() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(7), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 3, 0);
        assertFalse(gov.passed(id), "3/10 is below the 33% quorum");

        _expel(workers[8]);
        _expel(workers[9]);

        assertFalse(gov.passed(id), "shrinking the electorate must not revive a failed proposal");
        vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
        gov.execute(id);
        assertEq(target.value(), 0);
    }

    /// The mirror image: admitting members after the vote must not sink a proposal that passed.
    function test_PBA_L2_016_admission_does_not_sink_passed_proposal() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(9), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 4, 0);
        assertTrue(gov.passed(id));
        for (uint256 i = 0; i < 5; i++) _admit(address(uint160(0x3000 + i)), MembershipSBT.MemberClass.Worker);
        assertTrue(gov.passed(id), "the quorum denominator is fixed at propose time");
        gov.execute(id);
        assertEq(target.value(), 9);
    }

    /// Proposals expire: a passed proposal nobody executed is not a standing licence.
    function test_PBA_L2_016_stale_passed_proposal_expires() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(5), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 4, 0);
        assertTrue(gov.passed(id));
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
        gov.execute(id);
        assertEq(target.value(), 0);
    }

    /// Window boundaries: executable at executeAfter and at expiresAt, not one second later.
    function test_PBA_L2_016_execution_window_bounds() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, 4, 0);
        uint256 lastOk = _executeAfter(id) + 7 days; // EXECUTION_WINDOW, pinned by value
        vm.warp(lastOk + 1);
        vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
        gov.execute(id);
        vm.warp(lastOk);
        gov.execute(id);
        assertEq(target.value(), 1);
    }

    /// TRIPWIRE (class guard, "quorum denominator immutable after propose"): whatever the registrar
    /// does to the roll after the ballot closes (expel up to 6, admit up to 6, in any mix), the
    /// outcome of a closed ballot never changes.
    function testFuzz_PBA_L2_016_outcome_immutable_after_propose(uint8 yes, uint8 no, uint8 expelN, uint8 admitN) public {
        yes = uint8(bound(yes, 0, 5));
        no = uint8(bound(no, 0, 10 - uint256(yes) > 4 ? 4 : 10 - uint256(yes)));
        expelN = uint8(bound(expelN, 0, 10 - uint256(yes) - uint256(no)));
        admitN = uint8(bound(admitN, 0, 6));
        uint256 id = _propose(workers[0], address(target), _setValueCall(3), CooperativeGovernor.Kind.Standard);
        _voteWorkers(id, yes, no);
        bool before = gov.passed(id);
        for (uint256 i = 0; i < expelN; i++) _expel(workers[9 - i]); // non-voters, from the back
        for (uint256 i = 0; i < admitN; i++) _admit(address(uint160(0x4000 + i)), MembershipSBT.MemberClass.Worker);
        assertEq(gov.passed(id), before, "closed-ballot outcome moved with the live roll");
        if (!before) {
            vm.expectRevert(CooperativeGovernor.NotExecutable.selector);
            gov.execute(id);
        }
    }
}
