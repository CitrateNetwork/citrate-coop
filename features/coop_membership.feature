# Program RFC-CIT-COOP-0001 · Gate G2 · Sprint COOP-S1 WP-1
# Formal basis: specs/tla/coop/MembershipVoting.tla (Inv_OneSeatPerIdentity,
# Inv_WorkerControl). Legal basis: CA Cooperative Corporation Law / AB 816.
# The MEMBERSHIP rail — soulbound, one vote per person, worker-controlled.

Feature: Cooperative membership (soulbound, one-per-identity)
  So that the co-op is democratically controlled by the people who do the work

  Scenario: A KYC-verified contributor is admitted as a worker-member
    Given a KYC-verified address with a bound identity
    When the registrar mints a MembershipSBT of class Worker
    Then the address holds exactly one soulbound membership token
    And the token records the member's KYC identity and bound agentIds

  Scenario: One membership token per KYC identity (no Sybil seats)
    Given an identity that already holds a MembershipSBT
    When a second address bound to the same identity requests a token
    Then the mint is rejected
    And the identity still holds exactly one membership token

  Scenario: The membership token is soulbound
    Given a member holding a MembershipSBT
    When the member attempts to transfer the token to another address
    Then the transfer reverts because the token is locked (ERC-5192)

  Scenario: Worker-members retain at least 51% of voting power
    Given a co-op whose members are all workers
    When admitting a community investor would drop workers below 51%
    Then the investor admission is rejected
    And worker-members continue to hold at least 51% of the votes

  Scenario: A revoked-KYC member cannot act
    Given a member whose KYC claim has been revoked
    When the member attempts any membership action
    Then the action is rejected fail-closed
