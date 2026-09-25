// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "./MembershipSBT.sol";
import "./ModelCooperative.sol"; // selectors only (PBA-L2-017 Kind derivation)

interface ICoopExec {
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory);
}

/// @title CooperativeGovernor — one-member-one-vote governance (RFC-CIT-COOP-0001)
/// @notice Democratic governance over the MembershipSBT: 1 vote per member (never SALT),
///         commit-reveal secret ballots (the chain's IPFSIncentivesV3 prevrandao pattern),
///         liquid-democracy delegation, and a timelock. Community investors get approval-only
///         rights over merger/sale/reorg/dissolution and may not propose (AB 816). Execution
///         runs through the cooperative, which is the model owner. See ADR-0005.
/// @dev Formal: specs/tla/coop/MembershipVoting.tla (Inv_VoteConservation, Inv_RevealNeedsCommit).
contract CooperativeGovernor {
    enum Kind { Standard, Approval } // Approval = merger/sale/reorg/dissolution
    enum Choice { None, Yes, No }

    uint64 public constant COMMIT_PERIOD = 1 days;
    uint64 public constant REVEAL_PERIOD = 1 days;
    uint64 public constant TIMELOCK = 1 days;
    uint16 public constant QUORUM_BPS = 3300; // 33% of members must vote
    /// PBA-L2-016: a passed proposal is executable only in [executeAfter, executeAfter + EXECUTION_WINDOW].
    /// After that it is expired and must be re-proposed and re-voted; a vote is never a standing licence.
    uint64 public constant EXECUTION_WINDOW = 7 days;

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        Kind kind;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 executeAfter;
        uint64 expiresAt;   // PBA-L2-016: last second the proposal may execute
        uint256 electorate; // PBA-L2-016: memberCount snapshotted at propose (the quorum denominator)
        uint256 voterCutoff; // PBA-L2-040 B-014: only token ids below this (seated before propose) vote
        uint256 yes;
        uint256 no;
        bytes32 randaoSeed; // prevrandao at creation (for optional sortition)
        bool executed;
    }

    MembershipSBT public immutable membership;
    ICoopExec public immutable coop;

    /// @dev Internal (read it with getProposal): the auto-generated getter for this many fields hits
    ///      "stack too deep" under the pinned legacy pipeline (PBA-L2-016/040 added snapshot fields).
    Proposal[] internal proposals;
    mapping(uint256 => mapping(address => bytes32)) public commitment; // proposal => voter => hash
    mapping(uint256 => mapping(address => bool)) public revealed;

    // delegation (liquid democracy)
    mapping(address => address) public delegateOf;   // member => representative (self if unset)
    mapping(address => uint256) public delegatorCount;
    /// PBA-L2-015/040: the rep's MembershipSBT token id at delegation time. A delegation is live only
    /// while the rep still holds THAT seat, so an expelled-and-readmitted rep (new token id at the same
    /// address) can never revive a stale delegation and re-form a chain.
    mapping(address => uint256) public delegateTokenOf;
    uint64 public lastVotingDeadline;                // no delegation changes while a vote is open
    mapping(address => uint64) public openProposalUntil; // PBA-L2-040 B-015: proposer's open ballot

    event ProposalCreated(uint256 indexed id, address indexed proposer, Kind kind, address target);
    event Delegated(address indexed member, address indexed rep);
    event Undelegated(address indexed member);
    event VoteCommitted(uint256 indexed id, address indexed voter);
    event VoteRevealed(uint256 indexed id, address indexed voter, Choice choice, uint256 weight);
    event ProposalExecuted(uint256 indexed id);

    error NotMember();
    error NotWorker();
    error InvestorCannotVoteStandard();
    error HasDelegated();
    error DelegationLocked();
    error NotCommitPhase();
    error NotRevealPhase();
    error AlreadyCommitted();
    error BadReveal();
    error AlreadyRevealed();
    error NotExecutable();
    error RepresentativeHasDelegators(); // PBA-L2-015: a rep carrying delegators may not delegate onward
    error KindMismatch(); // PBA-L2-017: an Approval-class action proposed as Standard
    error ProposalPending();   // PBA-L2-040 B-015: one open proposal per proposer
    error ClassMismatch();     // PBA-L2-040 B-016: delegation stays within the member class
    error NotMembership();     // PBA-L2-040 COOP-02: only the MembershipSBT calls the expel hook

    constructor(address membership_, address coop_) {
        membership = MembershipSBT(membership_);
        coop = ICoopExec(coop_);
    }

    // --- delegation ---

    /// @dev A member counts as delegated only while their rep holds the SAME seat they delegated to
    ///      (PBA-L2-040 COOP-02 dormancy on expel, bound to the token id per PBA-L2-015: an expelled rep
    ///      readmitted at the same address has a new token id, so the old delegation stays dead).
    function _liveRep(address m) internal view returns (address) {
        address d = delegateOf[m];
        if (d == address(0)) return address(0);
        uint256 t = membership.tokenOf(d);
        return (t != 0 && t == delegateTokenOf[m]) ? d : address(0);
    }

    function _isDelegated(address m) internal view returns (bool) {
        return _liveRep(m) != address(0);
    }

    /// @dev Drop m's delegation (live or stale). Only a LIVE delegation is still counted in the rep's
    ///      delegatorCount (an expelled rep's count is zeroed on expel), so only that one is decremented.
    function _clearDelegation(address m) internal {
        address cur = delegateOf[m];
        if (cur == address(0)) return;
        if (_liveRep(m) != address(0)) delegatorCount[cur] -= 1;
        delete delegateOf[m];
        delete delegateTokenOf[m];
        emit Undelegated(m);
    }

    /// @notice PBA-L2-040 (COOP-02): MembershipSBT.expel hook. Clears the expelled member's own
    ///         delegation (their vote leaves the rep's weight) and zeroes the weight parked on them as
    ///         a rep: those delegations are now permanently dead (token-bound), and their delegators
    ///         vote directly again. Never reverts for a valid expel, so it can never block one.
    /// @dev Called by MembershipSBT.expel AFTER the seat is removed (tokenOf(member) == 0), so every
    ///      delegation pointing at `member` is already non-live when its count is zeroed here.
    function onMemberExpelled(address member) external {
        if (msg.sender != address(membership)) revert NotMembership();
        _clearDelegation(member);
        delegatorCount[member] = 0;
    }

    function delegate(address rep) external {
        if (!membership.isMember(msg.sender)) revert NotMember();
        if (!membership.isMember(rep) || rep == msg.sender) revert NotMember();
        if (block.timestamp <= lastVotingDeadline) revert DelegationLocked();
        // PBA-L2-040 B-016: same class only (a worker's weight must stay in the Standard vote)
        if (membership.memberClass(rep) != membership.memberClass(msg.sender)) revert ClassMismatch();
        // flat delegation: a rep must be an active voter (not itself delegated)
        if (_isDelegated(rep)) revert HasDelegated();
        // PBA-L2-015: ...and a member who IS a rep (carries delegators) may not delegate onward:
        // they could no longer vote and their delegators were not re-pointed, so every vote parked
        // on them was silently lost. Delegators must leave first (undelegate) to keep it flat.
        if (delegatorCount[msg.sender] != 0) revert RepresentativeHasDelegators();
        _clearDelegation(msg.sender);
        delegateOf[msg.sender] = rep;
        delegateTokenOf[msg.sender] = membership.tokenOf(rep);
        delegatorCount[rep] += 1;
        emit Delegated(msg.sender, rep);
    }

    function undelegate() external {
        if (block.timestamp <= lastVotingDeadline) revert DelegationLocked();
        _clearDelegation(msg.sender);
    }

    // --- proposals ---

    function propose(address target, uint256 value, bytes calldata data, Kind kind)
        external
        returns (uint256 id)
    {
        // AB 816: only worker-members may propose; investors are approval-only.
        if (membership.memberClass(msg.sender) != MembershipSBT.MemberClass.Worker) revert NotWorker();
        // PBA-L2-017: the Kind is derived from the call, not trusted from the proposer. An
        // Approval-class action (merger/sale/reorg/dissolution) may never be routed as Standard.
        // Choosing Approval for a Standard action is allowed (it is strictly harder to pass).
        if (kind == Kind.Standard && requiredKind(target, data) == Kind.Approval) revert KindMismatch();
        // PBA-L2-040 B-015: one open proposal per proposer; spam kept pushing lastVotingDeadline out
        // and froze delegation for everyone.
        if (block.timestamp <= openProposalUntil[msg.sender]) revert ProposalPending();

        uint64 commitDeadline = uint64(block.timestamp) + COMMIT_PERIOD;
        uint64 revealDeadline = commitDeadline + REVEAL_PERIOD;
        uint64 executeAfter = revealDeadline + TIMELOCK;

        id = proposals.length;
        proposals.push(Proposal({
            proposer: msg.sender,
            target: target,
            value: value,
            data: data,
            kind: kind,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            executeAfter: executeAfter,
            expiresAt: executeAfter + EXECUTION_WINDOW,
            electorate: membership.memberCount(),
            voterCutoff: membership.nextTokenId(),
            yes: 0,
            no: 0,
            randaoSeed: blockhash(block.number - 1) ^ bytes32(block.prevrandao),
            executed: false
        }));
        if (revealDeadline > lastVotingDeadline) lastVotingDeadline = revealDeadline;
        openProposalUntil[msg.sender] = revealDeadline;
        emit ProposalCreated(id, msg.sender, kind, target);
    }

    // --- commit-reveal voting (one member, one vote; weight = 1 + delegators) ---

    function commitVote(uint256 id, bytes32 hash) external {
        Proposal storage p = proposals[id];
        if (block.timestamp > p.commitDeadline) revert NotCommitPhase();
        _requireEligible(msg.sender, p);
        if (_isDelegated(msg.sender)) revert HasDelegated(); // delegators don't vote directly
        if (commitment[id][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        commitment[id][msg.sender] = hash;
        emit VoteCommitted(id, msg.sender);
    }

    /// @notice Reveal a previously committed ballot. hash = commitVoteHash(id, choice, salt, voter).
    function revealVote(uint256 id, Choice choice, bytes32 salt) external {
        Proposal storage p = proposals[id];
        if (block.timestamp <= p.commitDeadline || block.timestamp > p.revealDeadline) revert NotRevealPhase();
        // PBA-L2-040 (COOP-02): eligibility is re-checked at reveal; a voter expelled after committing
        // no longer holds a seat and cannot cast it.
        _requireEligible(msg.sender, p);
        if (revealed[id][msg.sender]) revert AlreadyRevealed();
        bytes32 h = commitment[id][msg.sender];
        if (h == bytes32(0) || h != commitVoteHash(id, choice, salt, msg.sender)) revert BadReveal();

        revealed[id][msg.sender] = true;
        uint256 weight = 1 + delegatorCount[msg.sender]; // self + delegated votes
        if (choice == Choice.Yes) p.yes += weight;
        else if (choice == Choice.No) p.no += weight;
        emit VoteRevealed(id, msg.sender, choice, weight);
    }

    /// @notice The ballot commitment. PBA-L2-040 B-017: domain-separated by chain, governor and
    ///         proposal id, so a commitment can never be replayed onto another proposal, governor or
    ///         chain.
    function commitVoteHash(uint256 id, Choice choice, bytes32 salt, address voter) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), id, choice, salt, voter));
    }

    // --- execution ---

    function execute(uint256 id) external returns (bytes memory) {
        Proposal storage p = proposals[id];
        if (p.executed || block.timestamp < p.executeAfter || block.timestamp > p.expiresAt || !_passed(p)) {
            revert NotExecutable();
        }
        p.executed = true;
        emit ProposalExecuted(id);
        return coop.execute(p.target, p.value, p.data);
    }

    // --- views ---

    /// @notice The minimum Kind a call requires (PBA-L2-017). Approval-class (AB 816: merger, sale,
    ///         reorg, dissolution) is:
    ///           - the co-op's own terminal lifecycle moves: beginWindDown(), dissolve(address);
    ///           - any ownership / asset hand-off on ANY target (the model sale / merger path):
    ///             transferOwnership(address), renounceOwnership(), and the ERC-721/ERC-20
    ///             transferFrom / safeTransferFrom family.
    ///         Everything else is Standard.
    function requiredKind(address target, bytes calldata data) public view returns (Kind) {
        if (data.length < 4) return Kind.Standard;
        bytes4 sel = bytes4(data[:4]);
        if (
            target == address(coop)
                && (sel == ModelCooperative.beginWindDown.selector || sel == ModelCooperative.dissolve.selector)
        ) return Kind.Approval;
        if (
            sel == 0xf2fde38b // transferOwnership(address)
                || sel == 0x715018a6 // renounceOwnership()
                || sel == 0x23b872dd // transferFrom(address,address,uint256)
                || sel == 0x42842e0e // safeTransferFrom(address,address,uint256)
                || sel == 0xb88d4fde // safeTransferFrom(address,address,uint256,bytes)
        ) return Kind.Approval;
        return Kind.Standard;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function getTally(uint256 id) external view returns (uint256 yes, uint256 no) {
        return (proposals[id].yes, proposals[id].no);
    }

    function passed(uint256 id) external view returns (bool) {
        return _passed(proposals[id]);
    }

    /// @dev PBA-L2-016: the quorum denominator is the electorate snapshotted at propose, never the live
    ///      memberCount. Reading it live let an expulsion (or admission) after the vote flip the
    ///      outcome of a closed ballot.
    function _passed(Proposal storage p) internal view returns (bool) {
        uint256 total = p.yes + p.no;
        uint256 quorum = (p.electorate * QUORUM_BPS + 9_999) / 10_000;
        if (total < quorum) return false;
        if (p.kind == Kind.Approval) return p.yes * 3 >= total * 2; // 2/3 supermajority
        return p.yes > p.no;                                        // simple majority
    }

    function _requireEligible(address voter, Proposal storage p) internal view {
        // PBA-L2-040 B-014: only members seated before the proposal was created may vote on it, so the
        // registrar cannot swing an open ballot by admitting voters mid-vote.
        uint256 tokenId = membership.tokenOf(voter);
        if (tokenId == 0 || tokenId >= p.voterCutoff) revert NotMember();
        MembershipSBT.MemberClass c = membership.memberClass(voter);
        if (c == MembershipSBT.MemberClass.Worker) return;
        if (c == MembershipSBT.MemberClass.Investor) {
            if (p.kind != Kind.Approval) revert InvestorCannotVoteStandard();
            return;
        }
        revert NotMember();
    }
}
