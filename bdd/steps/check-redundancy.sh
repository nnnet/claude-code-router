#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULT_DIR="$ROOT/test-results/bdd/redundancy"
LOG_FILE="$RESULT_DIR/$RUN_ID.log"
RECEIPT_FILE="$RESULT_DIR/$RUN_ID.receipt"
STARTED_MS="$(date +%s%3N)"
mkdir -p "$RESULT_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

finish() {
  local rc="$1" ended duration result
  ended="$(date +%s%3N)"
  duration=$((ended - STARTED_MS))
  result="PASS"
  (( rc == 0 )) || result="FAIL"
  printf 'result=%s\nduration_ms=%s\nexit_code=%s\nlog=%s\n' "$result" "$duration" "$rc" "$LOG_FILE" > "$RECEIPT_FILE"
  printf 'Redundancy gate result=%s duration_ms=%s exit_code=%s log=%s receipt=%s\n' \
    "$result" "$duration" "$rc" "$LOG_FILE" "$RECEIPT_FILE"
}
trap 'finish $?' EXIT

if rg -n 'docker[ -]compose|compose (up|run)' "$ROOT/bdd"; then
  printf 'BDD must not start Compose\n' >&2
  exit 1
fi

duplicate_scenarios="$(awk '/^  Scenario: /{sub(/^  Scenario: /, ""); print}' "$ROOT"/bdd/features/*.feature | sort | uniq -d)"
[[ -z "$duplicate_scenarios" ]] || {
  printf 'Duplicate scenarios:\n%s\n' "$duplicate_scenarios" >&2
  exit 1
}

duplicate_requirements="$(grep -h -oE 'run_case "REQ-[^"]+' "$ROOT"/bdd/steps/*.sh | cut -d'"' -f2 | sort | uniq -d)"
[[ -z "$duplicate_requirements" ]] || {
  printf 'Duplicate requirement executions:\n%s\n' "$duplicate_requirements" >&2
  exit 1
}

[[ "$(grep -c '^bdd: bdd-provider-free-model-scripts bdd-free-model-refresh$' "$ROOT/Makefile")" == 1 ]]
printf 'No repeated Compose startup, scenarios, requirement executions, or aggregate suite calls found.\n'
