#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULT_DIR="$ROOT/test-results/bdd/provider-free-model-scripts"
LOG_FILE="$RESULT_DIR/$RUN_ID.log"
RECEIPT_FILE="$RESULT_DIR/$RUN_ID.receipt.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/provider-free-models-bdd.XXXXXX")"
RUN_STARTED_MS="$(date +%s%3N)"

mkdir -p "$RESULT_DIR"
printf 'test_id\tworker\tresult\tduration_ms\texit_code\n' > "$RECEIPT_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

finish_run() {
  local rc="$1"
  local ended_ms duration result
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - RUN_STARTED_MS))
  result="PASS"
  (( rc == 0 )) || result="FAIL"
  printf 'terminal\tmain\t%s\t%s\t%s\n' "$result" "$duration" "$rc" >> "$RECEIPT_FILE"
  printf 'BDD terminal result=%s duration_ms=%s exit_code=%s log=%s receipt=%s\n' \
    "$result" "$duration" "$rc" "$LOG_FILE" "$RECEIPT_FILE"
  rm -rf "$TMP_ROOT"
}
trap 'finish_run $?' EXIT

run_case() {
  local test_id="$1" name="$2" function_name="$3"
  local started_ms ended_ms duration rc result
  started_ms="$(date +%s%3N)"
  printf 'START %s %s worker=main\n' "$test_id" "$name"
  if "$function_name"; then
    rc=0
    result="PASS"
  else
    rc=$?
    result="FAIL"
  fi
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - started_ms))
  printf '%s\tmain\t%s\t%s\t%s\n' "$test_id" "$result" "$duration" "$rc" >> "$RECEIPT_FILE"
  printf 'END %s result=%s duration_ms=%s exit_code=%s\n' "$test_id" "$result" "$duration" "$rc"
  (( rc == 0 ))
}

script_for() {
  case "$1" in
    openrouter) printf '%s/scripts/get-free-models-openrouter.sh' "$ROOT" ;;
    orcarouter) printf '%s/scripts/get-free-models-orcarouter.sh' "$ROOT" ;;
    teamorouter) printf '%s/scripts/get-free-models-teamorouter.sh' "$ROOT" ;;
    kilo) printf '%s/scripts/get-free-models-kilo.sh' "$ROOT" ;;
    *) return 1 ;;
  esac
}

prefix_for() {
  case "$1" in
    orcarouter) printf 'ORCAROUTER' ;;
    teamorouter) printf 'TEAMOROUTER' ;;
    kilo) printf 'KILO' ;;
    *) return 1 ;;
  esac
}

fixture_for() {
  printf '%s/bdd/fixtures/%s-models.json' "$ROOT" "$1"
}

run_provider() {
  local provider="$1" cache_dir="$2"
  shift 2
  local prefix script fixture
  prefix="$(prefix_for "$provider")"
  script="$(script_for "$provider")"
  fixture="$(fixture_for "$provider")"
  env \
    "${prefix}_CATALOG_URL=file://$fixture" \
    "${prefix}_CACHE_DIR=$cache_dir" \
    "${prefix}_API_KEY=" \
    "$script" "$@"
}

case_syntax() {
  bash -n \
    "$ROOT/scripts/free-models-provider-common.sh" \
    "$ROOT/scripts/get-free-models-openrouter.sh" \
    "$ROOT/scripts/get-free-models-orcarouter.sh" \
    "$ROOT/scripts/get-free-models-teamorouter.sh" \
    "$ROOT/scripts/get-free-models-kilo.sh" \
    "$ROOT/scripts/refresh-free-models-claude-code-router.sh" \
    "$ROOT/bdd/steps/provider-free-model-scripts.sh"
}

case_cli_surface() {
  local baseline="" provider output rc options
  for provider in openrouter orcarouter teamorouter kilo; do
    if output="$("$(script_for "$provider")" --help 2>&1)"; then
      return 1
    else
      rc=$?
    fi
    [[ "$rc" == 1 ]]
    options="$(grep -E '^  --[a-z]' <<< "$output" | awk '{print $1}' | sort)"
    [[ -n "$options" ]]
    if [[ -z "$baseline" ]]; then
      baseline="$options"
    else
      [[ "$options" == "$baseline" ]]
    fi
  done
}

case_free_selection() {
  local provider cache output actual expected
  for provider in orcarouter teamorouter kilo; do
    cache="$TMP_ROOT/free-$provider"
    output="$(run_provider "$provider" "$cache" --refresh --format ids 2>/dev/null)"
    actual="$(sort <<< "$output")"
    case "$provider" in
      orcarouter) expected=$'deepseek/deepseek-v4-flash-free\norcarouter/free' ;;
      teamorouter) expected=$'deepseek-v4-flash-free\nglm-5.3-flash-free' ;;
      kilo) expected=$'kilo-auto/free\nreflection/beam-free' ;;
    esac
    [[ "$actual" == "$expected" ]]
  done
}

case_formats() {
  local provider cache out err first_id
  for provider in orcarouter teamorouter kilo; do
    cache="$TMP_ROOT/formats-$provider"

    out="$TMP_ROOT/$provider.json"
    err="$TMP_ROOT/$provider.json.err"
    run_provider "$provider" "$cache" --refresh --format json > "$out" 2> "$err"
    jq -e 'type == "array" and length == 2 and all(.[];
      has("size") and has("access") and .size.ctx_unit == "tokens" and
      .access.account.key_env != null)' "$out" >/dev/null

    run_provider "$provider" "$cache" --format json-ids > "$out" 2> "$err"
    jq -e 'type == "array" and length == 2 and all(.[]; type == "string")' "$out" >/dev/null

    run_provider "$provider" "$cache" --format sizes > "$out" 2> "$err"
    jq -e 'type == "object" and has("_account") and
      ([to_entries[] | select(.value.access? != null)] | length) == 2' "$out" >/dev/null

    run_provider "$provider" "$cache" --format table > "$out" 2> "$err"
    grep -q 'Model ID' "$out"
    grep -q 'Access' "$out"

    run_provider "$provider" "$cache" --format ids > "$out" 2> "$err"
    [[ "$(wc -l < "$out")" == 2 ]]

    run_provider "$provider" "$cache" --format json-ids --sort +id --limit 1 > "$out" 2> "$err"
    first_id="$(jq -r '.[0]' "$out")"
    case "$provider" in
      orcarouter) [[ "$first_id" == "deepseek/deepseek-v4-flash-free" ]] ;;
      teamorouter) [[ "$first_id" == "deepseek-v4-flash-free" ]] ;;
      kilo) [[ "$first_id" == "kilo-auto/free" ]] ;;
    esac
  done
}

case_offline_cache() {
  local provider prefix script cache online offline rc
  for provider in orcarouter teamorouter kilo; do
    prefix="$(prefix_for "$provider")"
    script="$(script_for "$provider")"
    cache="$TMP_ROOT/offline-$provider"
    online="$(run_provider "$provider" "$cache" --refresh --format json-ids 2>/dev/null)"
    offline="$(env \
      "${prefix}_CATALOG_URL=file://$TMP_ROOT/does-not-exist.json" \
      "${prefix}_CACHE_DIR=$cache" \
      "${prefix}_API_KEY=" \
      "$script" --offline --format json-ids 2>/dev/null)"
    [[ "$online" == "$offline" ]]

    if env \
      "${prefix}_CATALOG_URL=file://$TMP_ROOT/does-not-exist.json" \
      "${prefix}_CACHE_DIR=$TMP_ROOT/empty-$provider" \
      "${prefix}_API_KEY=" \
      "$script" --offline --format json-ids >/dev/null 2>&1; then
      return 1
    else
      rc=$?
    fi
    [[ "$rc" == 2 ]]
  done
}

case_key_security() {
  local provider prefix script fixture cache out err secret
  secret='bdd-secret-must-not-appear-93741'
  for provider in orcarouter teamorouter kilo; do
    prefix="$(prefix_for "$provider")"
    script="$(script_for "$provider")"
    fixture="$(fixture_for "$provider")"
    cache="$TMP_ROOT/secret-$provider"
    out="$TMP_ROOT/secret-$provider.out"
    err="$TMP_ROOT/secret-$provider.err"
    env \
      "${prefix}_CATALOG_URL=file://$fixture" \
      "${prefix}_CACHE_DIR=$cache" \
      "${prefix}_API_KEY=$secret" \
      "$script" --refresh --format json > "$out" 2> "$err"
    if grep -R -F -q "$secret" "$out" "$err" "$cache"; then
      return 1
    fi
  done
}

case_unknown_metrics() {
  local provider cache out err
  for provider in orcarouter teamorouter kilo; do
    cache="$TMP_ROOT/metrics-$provider"
    out="$TMP_ROOT/metrics-$provider.json"
    err="$TMP_ROOT/metrics-$provider.err"
    run_provider "$provider" "$cache" --refresh --with-endpoints --format json > "$out" 2> "$err"
    jq -e 'all(.[];
      .endpoints.latency_ms == null and
      .endpoints.throughput_tps == null and
      .endpoints.uptime_pct == null and
      .endpoints.endpoint_count == 0)' "$out" >/dev/null
  done
}

run_case "SMOKE-SYNTAX" "Bash syntax" case_syntax
run_case "REQ-PFM-001" "Одинаковая поверхность CLI" case_cli_surface
run_case "REQ-PFM-002" "Нормализация разных каталогов" case_free_selection
run_case "REQ-PFM-003" "Машиночитаемые форматы" case_formats
run_case "REQ-PFM-004" "Повторный offline-вызов" case_offline_cache
run_case "REQ-PFM-005" "Ключ не раскрывается" case_key_security
run_case "REQ-PFM-006" "Неизвестные endpoint-метрики" case_unknown_metrics
