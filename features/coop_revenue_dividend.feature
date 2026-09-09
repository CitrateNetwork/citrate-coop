# Program RFC-CIT-COOP-0001 · Gate G2/G3 · Sprint COOP-S1 WP-3
# Formal basis: specs/tla/coop/PatronageDividend.tla (Inv_Conservation,
# Inv_NoRetroactive, Inv_ClaimedBounded).
# The patronage dividend — residual revenue distributed by patronage units.

Feature: Patronage dividend distribution
  So that members earn an ongoing residual from the model they trained

  Scenario: Revenue is distributed pro-rata by patronage
    Given two members holding patronage units in a known ratio
    When the co-op is notified of model revenue
    Then each member's claimable dividend grows in proportion to their units

  Scenario: No retroactive dividend for late contributors
    Given revenue was distributed before a new member held any patronage
    When that member later accrues patronage and claims
    Then the member receives nothing from the earlier distribution

  Scenario: Conservation of revenue
    Given a sequence of revenue notifications and patronage mints
    When all members have claimed
    Then the sum of all claimed dividends equals the total revenue notified minus rounding dust
    And rounding dust remains in the contract, never overpaid

  Scenario: Claims are KYC-gated at claim time
    Given a member whose KYC was revoked after accruing a dividend
    When the member calls claim
    Then the claim reverts fail-closed

  Scenario: Claim is recorded for patronage-dividend reporting
    Given a member with a positive claimable dividend
    When the member claims
    Then a DividendClaimed record is emitted for Subchapter T / 1099-PATR reporting
