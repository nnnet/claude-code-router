#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULT_DIR="$ROOT/test-results/smoke/provider-free-models-live"
LOG_FILE="$RESULT_DIR/$RUN_ID.log"
RECEIPT_FILE="$RESULT_DIR/$RUN_ID.receipt.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/provider-free-models-live.XXXXXX")"
RUN_STARTED_MS="$(date +%s%3N)"

mkdir -p "$RESULT_DIR"
printf 'test_id\tworker\tresult\tduration_ms\texit_code\tmodel_count\n' > "$RECEIPT_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

finish_run() {
  local rc="$1" ended_ms duration result
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - RUN_STARTED_MS))
  result="PASS"
  (( rc == 0 )) || result="FAIL"
  printf 'terminal\tmain\t%s\t%s\t%s\t-\n' "$result" "$duration" "$rc" >> "$RECEIPT_FILE"
  printf 'Live smoke terminal result=%s duration_ms=%s exit_code=%s log=%s receipt=%s\n' \
    "$result" "$duration" "$rc" "$LOG_FILE" "$RECEIPT_FILE"
  rm -rf "$TMP_ROOT"
}
trap 'finish_run $?' EXIT

run_provider_smoke() {
  local provider="$1" prefix="$2" key_env="$3" script="$4"
  local started_ms ended_ms duration rc result count json_file ids_file err_file cache_dir
  started_ms="$(date +%s%3N)"
  json_file="$TMP_ROOT/$provider.json"
  ids_file="$TMP_ROOT/$provider.ids"
  err_file="$TMP_ROOT/$provider.err"
  cache_dir="$TMP_ROOT/cache-$provider"

  [[ -n "${!key_env-}" ]] || {
    printf '%s: %s is not exported\n' "$provider" "$key_env" >&2
    return 1
  }

  printf 'START LIVE-%s worker=main\n' "$provider"
  if env "${prefix}_CACHE_DIR=$cache_dir" "$script" --refresh --format json > "$json_file" 2> "$err_file" \
    && jq -e 'type == "array" and length > 0 and all(.[]; .id and .size and .access)' "$json_file" >/dev/null \
    && env "${prefix}_CACHE_DIR=$cache_dir" "$script" --offline --format ids > "$ids_file" 2>> "$err_file" \
    && [[ "$(wc -l < "$ids_file")" == "$(jq 'length' "$json_file")" ]]; then
    rc=0
    result="PASS"
  else
    rc=$?
    result="FAIL"
    printf '%s live smoke diagnostics:\n' "$provider" >&2
    sed -n '1,120p' "$err_file" >&2
  fi
  count="$(jq -r 'length // 0' "$json_file" 2>/dev/null || true)"
  [[ -n "$count" ]] || count=0
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - started_ms))
  printf 'LIVE-%s\tmain\t%s\t%s\t%s\t%s\n' "$provider" "$result" "$duration" "$rc" "$count" >> "$RECEIPT_FILE"
  printf 'END LIVE-%s result=%s duration_ms=%s exit_code=%s model_count=%s\n' \
    "$provider" "$result" "$duration" "$rc" "$count"
  (( rc == 0 ))
}

run_provider_smoke orcarouter ORCAROUTER ORCAROUTER_API_KEY "$ROOT/scripts/get-free-models-orcarouter.sh"
run_provider_smoke teamorouter TEAMOROUTER TEAMOROUTER_API_KEY "$ROOT/scripts/get-free-models-teamorouter.sh"
run_provider_smoke kilo KILO KILO_API_KEY "$ROOT/scripts/get-free-models-kilo.sh"
