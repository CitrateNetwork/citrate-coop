# Program RFC-CIT-COOP-0001 · Gate G3/G4 · Sprint COOP-S1 WP-4 (rails A,B) + WP-7 (rail C)
# Three on-chain revenue rails converge on notifyRevenue -> patronage dividend.
# Reuses live contracts: ModelRegistry, ModelMarketplace, X402Facilitator/Paywall,
# WrappedSALT (EIP-3009), StablecoinTreasury, ComputePricingOracle.

Feature: Revenue routing — on-chain, x402, and fiat
  So that model revenue from every channel reaches the co-op treasury

  # --- Rail A: on-chain SALT (works today by setting the co-op as model owner) ---
  Scenario: Direct inference revenue lands in the co-op
    Given the co-op is registered as the model owner in ModelRegistry
    When a buyer calls requestInference and pays the inference price
    Then the full payment is sent to the co-op
    And the co-op wraps it to wSALT and credits the patronage dividend

  Scenario: Marketplace sale revenue lands in the co-op
    Given the co-op is the listing owner in ModelMarketplace
    When a buyer purchases access
    Then the co-op receives the sale price minus the 2.5% marketplace fee

  # --- Rail B: x402 micropayments ---
  Scenario: x402 micropayment routes to the co-op
    Given the model resource is configured with the co-op as the x402 provider
    When a payer settles an EIP-3009 authorization via X402Facilitator
    Then wSALT transfers the net value to the co-op and the fee to the facilitator treasury
    And the co-op credits the patronage dividend

  # --- Rail C: fiat (Stripe cards + Plaid ACH) ---
  Scenario: Fiat purchase credits the co-op after the hold period
    Given a buyer pays USD via Stripe or Plaid through the licensed custodian
    When the custodian signs a settlement attestation and the hold period elapses
    Then CooperativeFiatRamp converts USD to wSALT via the pricing oracle
    And calls notifyRevenue so the amount enters the patronage dividend

  Scenario: A chargeback does not claw back distributed dividends
    Given a fiat payment that is later reversed by chargeback
    When the reversal is processed
    Then the loss is absorbed by the ramp reserve
    And no member's already-distributed dividend is clawed back
