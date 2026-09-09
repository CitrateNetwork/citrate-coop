#!/usr/bin/env bash
# Run TLC over every coop TLA+ module (RFC-CIT-COOP-0001, COOP-S1 WP-0).
# Mirrors nat/scripts/run-tlc.sh. Requires tla2tools.jar (set TLA_TOOLS or place
# it at ./scripts/tla2tools.jar) and a JRE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPECS="$ROOT/specs/tla/coop"
JAR="${TLA_TOOLS:-$ROOT/scripts/tla2tools.jar}"

if [[ ! -f "$JAR" ]]; then
  echo "tla2tools.jar not found at $JAR"
  echo "Download: https://github.com/tlaplus/tlaplus/releases (latest tla2tools.jar)"
  echo "Then: TLA_TOOLS=/path/to/tla2tools.jar $0"
  exit 1
fi

MODULES=(CoopLifecycle PatronageDividend MembershipVoting ContributionRewardPool)
fail=0
for m in "${MODULES[@]}"; do
  echo "=== TLC: $m ==="
  # -deadlock disables deadlock checking: these are SAFETY specs with intentional
  # terminal states (e.g. Dissolved) and a MaxSteps horizon — both are not deadlocks
  # in our sense. We assert invariants over the reachable state space, not liveness.
  if java -cp "$JAR" tlc2.TLC -deadlock -config "$SPECS/$m.cfg" "$SPECS/$m.tla" -workers auto; then
    echo "--- $m OK"
  else
    echo "!!! $m FAILED"
    fail=1
  fi
done

exit $fail
