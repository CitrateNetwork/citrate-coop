# Program RFC-CIT-COOP-0001 · Gate G2 · Sprint COOP-S1 WP-2
# Formal basis: specs/tla/coop/PatronageDividend.tla (conservation) and
# CoopLifecycle.tla (contribution-window guards).
# The PATRONAGE rail — work contributed (compute x data-quality), relative to pool.

Feature: Patronage accrual from verified training contributions
  So that ownership tracks the work each member added, not capital

  Scenario: Patronage unit equals compute times data quality
    Given a committed federated round with an on-chain merged_hash
    When the settler records a contribution with metered compute and a data-quality score
    Then the member's patronage units increase by compute multiplied by data quality
    And a zero data-quality score yields zero patronage units

  Scenario: Patronage is anchored to a verified round
    Given a round whose merged_hash has not been committed on-chain
    When the settler attempts to record a contribution for that round
    Then the contribution is rejected because the round is not committed

  Scenario: A contribution is counted at most once
    Given a member already recorded for a round
    When the settler records the same member for the same round again
    Then the second record is rejected as a double count

  Scenario: Patronage closes at wind-down
    Given a co-op in the WindingDown state
    When the settler attempts to record a new contribution
    Then the contribution is rejected because the patronage window is closed

  Scenario: More patronage never grants more votes
    Given a member with a large patronage balance
    When governance counts that member's vote
    Then the member casts exactly one vote regardless of patronage
