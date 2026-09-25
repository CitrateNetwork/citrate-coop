// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./PbaR2Base.sol";

/// PBA-L2-040 (MEDIUM, grouped KNOWN-OPEN prior findings, held on the unreachable
/// prep/rm-q-coop-medlow branch): one regression per item, at the real entry points.
/// New-API calls go through low-level calls so every test compiles (and fails for the finding's
/// reason) against the pre-fix code.

/// Governance-integrity items: COOP-02, COOP-03/B-014, B-015, B-016, B-017.
contract PbaR2GovernanceMedLowTest is PbaR2Base {
    function setUp() public {
        _deploy(6, 1);
    }

    function _try(address who, address to, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = to.call(data);
    }

    // COOP-02: a voter expelled after committing must not be able to reveal.
    function test_PBA_L2_040_COOP02_expelled_voter_cannot_reveal() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        _commit(id, workers[1], CooperativeGovernor.Choice.Yes);
        vm.warp(_commitDeadline(id) + 1);
        _expel(workers[1]);
        assertFalse(_try(workers[1], address(gov), abi.encodeWithSelector(CooperativeGovernor.revealVote.selector, id, CooperativeGovernor.Choice.Yes, BALLOT_SALT)), "expelled member revealed");
        (uint256 yes,) = gov.getTally(id);
        assertEq(yes, 0);
    }

    // COOP-02: an expelled delegator's vote must leave the rep's weight (stale delegation state).
    function test_PBA_L2_040_COOP02_expelled_delegator_weight_removed() public {
        vm.prank(workers[2]);
        gov.delegate(workers[1]);
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        _commit(id, workers[1], CooperativeGovernor.Choice.Yes);
        _expel(workers[2]);
        vm.warp(_commitDeadline(id) + 1);
        _reveal(id, workers[1], CooperativeGovernor.Choice.Yes);
        (uint256 yes,) = gov.getTally(id);
        assertEq(yes, 1, "expelled delegator still weighted");
        assertEq(gov.delegatorCount(workers[1]), 0);
    }

    // COOP-02: when a rep is expelled, their delegators get their vote back (not stranded).
    function test_PBA_L2_040_COOP02_delegators_of_expelled_rep_can_vote() public {
        vm.prank(workers[2]);
        gov.delegate(workers[1]);
        _expel(workers[1]);
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        bytes32 h = _ballot(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[2]);
        assertTrue(_try(workers[2], address(gov), abi.encodeWithSelector(CooperativeGovernor.commitVote.selector, id, h)), "delegator of an expelled rep is stranded");
    }

    // COOP-03/B-014: expel must re-check the AB 816 51% worker share.
    function test_PBA_L2_040_COOP03_expel_rechecks_worker_majority() public {
        // 6 workers + 1 investor. Admit investors up to the 51% edge: 6W/5I = 54.5%.
        for (uint256 i = 1; i < 5; i++) _admit(address(uint160(0x2000 + i)), MembershipSBT.MemberClass.Investor);
        assertEq(sbt.workerCount(), 6);
        assertEq(sbt.memberCount(), 11);
        // expelling a worker would leave 5W/5I = 50% < 51%
        assertFalse(_try(registrar, address(sbt), abi.encodeWithSelector(MembershipSBT.expel.selector, workers[5])), "expel broke the 51% worker share");
        assertEq(sbt.workerCount(), 6);
    }

    // COOP-03/B-014: a member admitted after propose cannot vote on it (registrar mid-vote swing).
    function test_PBA_L2_040_B014_member_admitted_mid_vote_cannot_vote() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        address late = _admit(address(uint160(0x5000)), MembershipSBT.MemberClass.Worker);
        bytes32 h = _ballot(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, late);
        assertFalse(_try(late, address(gov), abi.encodeWithSelector(CooperativeGovernor.commitVote.selector, id, h)), "late admission voted on an open proposal");
    }

    // B-015: one open proposal per proposer (spam kept extending lastVotingDeadline).
    function test_PBA_L2_040_B015_one_open_proposal_per_proposer() public {
        _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        vm.warp(block.timestamp + 1 hours);
        assertFalse(_try(workers[0], address(gov), abi.encodeWithSelector(CooperativeGovernor.propose.selector, address(target), uint256(0), _setValueCall(2), CooperativeGovernor.Kind.Standard)), "proposal spam not limited");
        // after the first ballot closes, the proposer may propose again
        vm.warp(block.timestamp + 3 days);
        assertTrue(_try(workers[0], address(gov), abi.encodeWithSelector(CooperativeGovernor.propose.selector, address(target), uint256(0), _setValueCall(2), CooperativeGovernor.Kind.Standard)));
    }

    // B-016: a Worker may not delegate to an Investor (worker weight would leave the Standard vote).
    function test_PBA_L2_040_B016_worker_cannot_delegate_to_investor() public {
        assertFalse(_try(workers[0], address(gov), abi.encodeWithSelector(CooperativeGovernor.delegate.selector, investors[0])), "cross-class delegation");
        assertEq(gov.delegatorCount(investors[0]), 0);
    }

    // B-017: a commitment made for one proposal cannot be replayed onto another (id in the domain).
    function test_PBA_L2_040_B017_ballot_bound_to_proposal_id() public {
        uint256 id0 = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        uint256 id1 = _propose(workers[1], address(target), _setValueCall(2), CooperativeGovernor.Kind.Standard);
        bytes32 forId0 = _ballot(id0, CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[2]);
        vm.prank(workers[2]);
        gov.commitVote(id1, forId0); // replayed onto proposal 1
        vm.warp(_commitDeadline(id1) + 1);
        assertFalse(_try(workers[2], address(gov), abi.encodeWithSelector(CooperativeGovernor.revealVote.selector, id1, CooperativeGovernor.Choice.Yes, BALLOT_SALT)), "cross-proposal ballot replay accepted");
    }

    // B-017: the ballot hash must carry the proposal/contract/chain domain; a domain-free
    // commitment (replayable across proposals, governors, chains) must not reveal.
    function test_PBA_L2_040_B017_domain_free_ballot_rejected() public {
        uint256 id = _propose(workers[0], address(target), _setValueCall(1), CooperativeGovernor.Kind.Standard);
        bytes32 bare = keccak256(abi.encode(CooperativeGovernor.Choice.Yes, BALLOT_SALT, workers[1]));
        vm.prank(workers[1]);
        gov.commitVote(id, bare);
        vm.warp(_commitDeadline(id) + 1);
        assertFalse(_try(workers[1], address(gov), abi.encodeWithSelector(CooperativeGovernor.revealVote.selector, id, CooperativeGovernor.Choice.Yes, BALLOT_SALT)), "domain-free ballot accepted");
    }

    /// TRIPWIRE (COOP-02 + PBA-L2-015 class guard, implementation-independent): after random
    /// delegate / undelegate / expel / admit / RE-ADMIT (same address, new seat) sequences, hold a real
    /// ballot where every seated member tries to vote Yes (members who cannot vote directly because
    /// they are delegated just fail to commit). The Yes tally must equal the member count: no vote is
    /// lost to a stale or re-formed delegation chain, and none is counted twice.
    function testFuzz_PBA_L2_040_weight_conserved_across_expulsions(uint256 seed) public {
        address[] memory pool_ = new address[](12);
        for (uint256 i = 0; i < 6; i++) pool_[i] = workers[i];
        for (uint256 i = 6; i < 12; i++) pool_[i] = address(uint160(0x6000 + i));
        uint256 admitted = 6;
        for (uint256 step = 0; step < 30; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address a = pool_[r % admitted];
            uint256 op = (r >> 8) % 6;
            if (op == 0 && admitted < 12) {
                _admit(pool_[admitted++], MembershipSBT.MemberClass.Worker);
            } else if (op == 1) {
                if (sbt.isMember(a)) _try(registrar, address(sbt), abi.encodeWithSelector(MembershipSBT.expel.selector, a));
            } else if (op == 2) {
                _try(a, address(gov), abi.encodeWithSelector(CooperativeGovernor.undelegate.selector));
            } else if (op == 3) {
                if (!sbt.isMember(a)) _admit(a, MembershipSBT.MemberClass.Worker); // re-admission, same address
            } else {
                _try(a, address(gov), abi.encodeWithSelector(CooperativeGovernor.delegate.selector, pool_[(r >> 16) % admitted]));
            }
        }
        _assertEveryVoteCounts(pool_, admitted);
    }

    function _assertEveryVoteCounts(address[] memory pool_, uint256 admitted) internal {
        address proposer;
        for (uint256 i = 0; i < admitted && proposer == address(0); i++) {
            if (sbt.isMember(pool_[i])) proposer = pool_[i]; // pool_ holds only workers
        }
        // Approval kind (allowed for any call) so the seated investor votes too.
        uint256 id = _propose(proposer, address(target), _setValueCall(1), CooperativeGovernor.Kind.Approval);
        address[] memory voters = new address[](admitted + 1);
        for (uint256 i = 0; i < admitted; i++) voters[i] = pool_[i];
        voters[admitted] = investors[0];
        bool[] memory committed = new bool[](voters.length);
        for (uint256 i = 0; i < voters.length; i++) {
            if (!sbt.isMember(voters[i])) continue;
            bytes32 h = _ballot(id, CooperativeGovernor.Choice.Yes, BALLOT_SALT, voters[i]);
            committed[i] = _try(voters[i], address(gov), abi.encodeWithSelector(CooperativeGovernor.commitVote.selector, id, h));
        }
        vm.warp(_commitDeadline(id) + 1);
        for (uint256 i = 0; i < voters.length; i++) {
            if (committed[i]) _reveal(id, voters[i], CooperativeGovernor.Choice.Yes);
        }
        (uint256 yes,) = gov.getTally(id);
        assertEq(yes, sbt.memberCount(), "a seated member's vote was lost or double counted");
    }
}
