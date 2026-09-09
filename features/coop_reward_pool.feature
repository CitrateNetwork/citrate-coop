# Program RFC-CIT-COOP-0001 · Gate G3 · Sprint COOP-S1 WP-5
# Formal basis: specs/tla/coop/ContributionRewardPool.tla (Inv_TotalCap,
# Inv_CohortCap, Inv_ReserveConservation, Inv_VestBounded).
# The 50M SALT emission: 10M/yr x 5, by-year patronage, linear vest, reserve skim.

Feature: Contribution Reward Pool (50M SALT emission)
  So that contributors are rewarded over five years and the reserve is funded

  Scenario: Annual cohort allocated by that year's patronage
    Given members with in-year patronage in a known ratio for year Y
    When year Y's cohort is allocated
    Then each member's grant for year Y is proportional to their year-Y patronage

  Scenario: Reserve is skimmed from the cohort, not from revenue
    Given an annual cohort of 10,000,000 SALT and a reserve of 20%
    When the cohort opens
    Then 2,000,000 SALT is swept to the co-op reserve
    And 8,000,000 SALT remains distributable to members for that year

  Scenario: Total emission is capped at 50M
    Given five annual cohorts of 10,000,000 SALT
    When all cohorts have been allocated and the reserve skimmed
    Then total grants plus reserve never exceed 50,000,000 SALT

  Scenario: Grants vest linearly
    Given a member with a year-Y grant
    When time passes within the vesting window
    Then the member's claimable amount increases linearly and never exceeds the grant

  Scenario: Unvested grant is forfeitable on expulsion-for-cause
    Given a member with an unvested grant who is expelled for cause by governance
    When the expulsion executes
    Then the unvested portion returns to the pool
