// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "./MembershipSBT.sol";

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

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        Kind kind;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 executeAfter;
        uint256 yes;
        uint256 no;
        bytes32 randaoSeed; // prevrandao at creation (for optional sortition)
        bool executed;
    }

    MembershipSBT public immutable membership;
    ICoopExec public immutable coop;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => bytes32)) public commitment; // proposal => voter => hash
    mapping(uint256 => mapping(address => bool)) public revealed;

    // delegation (liquid democracy)
    mapping(address => address) public delegateOf;   // member => representative (self if unset)
    mapping(address => uint256) public delegatorCount;
    uint64 public lastVotingDeadline;                // no delegation changes while a vote is open

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

    constructor(address membership_, address coop_) {
        membership = MembershipSBT(membership_);
        coop = ICoopExec(coop_);
    }

    // --- delegation ---

    function _rep(address m) internal view returns (address) {
        address d = delegateOf[m];
        return d == address(0) ? m : d;
    }

    function delegate(address rep) external {
        if (!membership.isMember(msg.sender)) revert NotMember();
        if (!membership.isMember(rep) || rep == msg.sender) revert NotMember();
        if (block.timestamp <= lastVotingDeadline) revert DelegationLocked();
        // flat delegation: a rep must be an active voter (not itself delegated)
        if (delegateOf[rep] != address(0)) revert HasDelegated();
        address cur = delegateOf[msg.sender];
        if (cur != address(0)) delegatorCount[cur] -= 1;
        delegateOf[msg.sender] = rep;
        delegatorCount[rep] += 1;
        emit Delegated(msg.sender, rep);
    }

    function undelegate() external {
        if (block.timestamp <= lastVotingDeadline) revert DelegationLocked();
        address cur = delegateOf[msg.sender];
        if (cur != address(0)) {
            delegatorCount[cur] -= 1;
            delegateOf[msg.sender] = address(0);
            emit Undelegated(msg.sender);
        }
    }

    // --- proposals ---

    function propose(address target, uint256 value, bytes calldata data, Kind kind)
        external
        returns (uint256 id)
    {
        // AB 816: only worker-members may propose; investors are approval-only.
        if (membership.memberClass(msg.sender) != MembershipSBT.MemberClass.Worker) revert NotWorker();

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
            yes: 0,
            no: 0,
            randaoSeed: blockhash(block.number - 1) ^ bytes32(block.prevrandao),
            executed: false
        }));
        if (revealDeadline > lastVotingDeadline) lastVotingDeadline = revealDeadline;
        emit ProposalCreated(id, msg.sender, kind, target);
    }

    // --- commit-reveal voting (one member, one vote; weight = 1 + delegators) ---

    function commitVote(uint256 id, bytes32 hash) external {
        Proposal storage p = proposals[id];
        if (block.timestamp > p.commitDeadline) revert NotCommitPhase();
        _requireEligible(msg.sender, p.kind);
        if (delegateOf[msg.sender] != address(0)) revert HasDelegated(); // delegators don't vote directly
        if (commitment[id][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        commitment[id][msg.sender] = hash;
        emit VoteCommitted(id, msg.sender);
    }

    /// @notice Reveal a previously committed ballot. hash = keccak256(choice, salt, voter).
    function revealVote(uint256 id, Choice choice, bytes32 salt) external {
        Proposal storage p = proposals[id];
        if (block.timestamp <= p.commitDeadline || block.timestamp > p.revealDeadline) revert NotRevealPhase();
        if (revealed[id][msg.sender]) revert AlreadyRevealed();
        bytes32 h = commitment[id][msg.sender];
        if (h == bytes32(0) || h != keccak256(abi.encode(choice, salt, msg.sender))) revert BadReveal();

        revealed[id][msg.sender] = true;
        uint256 weight = 1 + delegatorCount[msg.sender]; // self + delegated votes
        if (choice == Choice.Yes) p.yes += weight;
        else if (choice == Choice.No) p.no += weight;
        emit VoteRevealed(id, msg.sender, choice, weight);
    }

    function commitVoteHash(Choice choice, bytes32 salt, address voter) external pure returns (bytes32) {
        return keccak256(abi.encode(choice, salt, voter));
    }

    // --- execution ---

    function execute(uint256 id) external returns (bytes memory) {
        Proposal storage p = proposals[id];
        if (p.executed || block.timestamp < p.executeAfter || !_passed(p)) revert NotExecutable();
        p.executed = true;
        emit ProposalExecuted(id);
        return coop.execute(p.target, p.value, p.data);
    }

    // --- views ---

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function getTally(uint256 id) external view returns (uint256 yes, uint256 no) {
        return (proposals[id].yes, proposals[id].no);
    }

    function passed(uint256 id) external view returns (bool) {
        return _passed(proposals[id]);
    }

    function _passed(Proposal storage p) internal view returns (bool) {
        uint256 total = p.yes + p.no;
        uint256 quorum = (membership.memberCount() * QUORUM_BPS + 9_999) / 10_000;
        if (total < quorum) return false;
        if (p.kind == Kind.Approval) return p.yes * 3 >= total * 2; // 2/3 supermajority
        return p.yes > p.no;                                        // simple majority
    }

    function _requireEligible(address voter, Kind kind) internal view {
        MembershipSBT.MemberClass c = membership.memberClass(voter);
        if (c == MembershipSBT.MemberClass.Worker) return;
        if (c == MembershipSBT.MemberClass.Investor) {
            if (kind != Kind.Approval) revert InvestorCannotVoteStandard();
            return;
        }
        revert NotMember();
    }
}
