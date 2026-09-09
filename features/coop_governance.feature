# Program RFC-CIT-COOP-0001 · Gate G3 · Sprint COOP-S1 WP-6
# Formal basis: specs/tla/coop/MembershipVoting.tla (Inv_VoteConservation,
# Inv_RevealNeedsCommit). Randomness pattern: the chain's IPFSIncentivesV3
# commit-reveal (block.prevrandao, REVEAL_DELAY). Legal: AB 816 one-member-one-vote.

Feature: One-member-one-vote governance with delegation
  So that the people govern the model democratically and can delegate

  Scenario: Each member casts exactly one vote
    Given three worker-members
    When all three vote on a proposal
    Then the tally counts exactly three votes regardless of any SALT balance

  Scenario: Commit-reveal secret ballot
    Given a member who committed a sealed ballot bound to block.prevrandao
    When the member reveals the vote after the reveal delay
    Then the revealed vote is counted
    And a member who never committed cannot reveal a vote

  Scenario: Delegation reassigns the caster without inflating votes
    Given a member who delegates their vote to a representative
    When the representative votes
    Then the representative casts their own vote plus the delegated vote
    And the total attributable votes still equals the member count

  Scenario: Delegation is revocable and never moves the token
    Given a member who delegated their vote
    When the member undelegates
    Then the member regains direct voting and still holds the same soulbound token

  Scenario: Community investors have approval-only rights
    Given a community-investor member
    When the investor attempts to propose a non-approval action
    Then the proposal is rejected
    And the investor may only vote to approve a merger, sale, reorg, or dissolution

  Scenario: Governance executes as the model owner
    Given a passed proposal to set the model inference price
    When the timelock elapses and the proposal executes
    Then the co-op calls ModelRegistry.setInferencePrice as the model owner
