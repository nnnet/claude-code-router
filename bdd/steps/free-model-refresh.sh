#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULT_DIR="$ROOT/test-results/bdd/free-model-refresh"
LOG_FILE="$RESULT_DIR/$RUN_ID.log"
RECEIPT_FILE="$RESULT_DIR/$RUN_ID.receipt.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/free-model-refresh-bdd.XXXXXX")"
RUN_STARTED_MS="$(date +%s%3N)"
REFRESH="$ROOT/scripts/refresh-free-models-claude-code-router.sh"

mkdir -p "$RESULT_DIR"
printf 'test_id\tworker\tresult\tduration_ms\texit_code\n' > "$RECEIPT_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

finish_run() {
  local rc="$1" ended_ms duration result
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - RUN_STARTED_MS))
  result="PASS"
  (( rc == 0 )) || result="FAIL"
  printf 'terminal\tmain\t%s\t%s\t%s\n' "$result" "$duration" "$rc" >> "$RECEIPT_FILE"
  printf 'BDD refresh terminal result=%s duration_ms=%s exit_code=%s log=%s receipt=%s\n' \
    "$result" "$duration" "$rc" "$LOG_FILE" "$RECEIPT_FILE"
  rm -rf "$TMP_ROOT"
}
trap 'finish_run $?' EXIT

run_case() {
  local test_id="$1" name="$2" function_name="$3"
  local started_ms ended_ms duration rc result
  started_ms="$(date +%s%3N)"
  printf 'START %s %s worker=main\n' "$test_id" "$name"
  if "$function_name"; then rc=0; result="PASS"; else rc=$?; result="FAIL"; fi
  ended_ms="$(date +%s%3N)"
  duration=$((ended_ms - started_ms))
  printf '%s\tmain\t%s\t%s\t%s\n' "$test_id" "$result" "$duration" "$rc" >> "$RECEIPT_FILE"
  printf 'END %s result=%s duration_ms=%s exit_code=%s\n' "$test_id" "$result" "$duration" "$rc"
  (( rc == 0 ))
}

DOUBLES="$TMP_ROOT/doubles"
CALL_LOG="$TMP_ROOT/calls.tsv"
mkdir -p "$DOUBLES"
cat > "$DOUBLES/fake-discovery.sh" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
platform="${0##*/get-free-models-}"
platform="${platform%.sh}"
format="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) format="$2"; shift 2 ;;
    --sort) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\n' "$platform" "$format" >> "$BDD_DISCOVERY_CALL_LOG"
[[ "${BDD_FAIL_PLATFORM:-}" != "$platform" ]] || exit 42
case "$format" in
  table) printf 'Model ID\n%s/free-a\n%s/free-b\n' "$platform" "$platform" ;;
  json-ids) printf '["%s/free-a","%s/free-b"]\n' "$platform" "$platform" ;;
  sizes) printf '{"%s/free-a":{"ctx":1000},"%s/free-b":{"ctx":500}}\n' "$platform" "$platform" ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$DOUBLES/fake-discovery.sh"
for platform in openrouter orcarouter teamorouter kilo; do
  ln -s fake-discovery.sh "$DOUBLES/get-free-models-$platform.sh"
done

cat > "$TMP_ROOT/input.json" <<'JSON'
{
  "Providers": [
    {
      "id": "openrouter",
      "name": "OpenRouter",
      "api_base_url": "https://openrouter.ai/api/v1",
      "type": "openai_chat_completions",
      "models": ["keep/openrouter"],
      "credentials": [{"id":"manual-openrouter","api_key":"manual"}]
    },
    {
      "id": "custom",
      "name": "Custom",
      "api_base_url": "https://custom.example/v1",
      "type": "openai_chat_completions",
      "models": ["custom/model"]
    }
  ]
}
JSON

run_refresh() {
  local input="$1" output="$2"
  shift 2
  env \
    BDD_DISCOVERY_CALL_LOG="$CALL_LOG" \
    CCR_CONFIG_INPUT="$input" \
    CCR_CONFIG_OUTPUT="$output" \
    CCR_FREE_MODELS_SCRIPT_DIR="$DOUBLES" \
    CCR_BACKUP_DIR="$TMP_ROOT/backups" \
    "$REFRESH" "$@"
}

case_platform_selection() {
  : > "$CALL_LOG"
  CCR_SKIP_POOL=1 run_refresh "$TMP_ROOT/input.json" "$TMP_ROOT/subset.json" \
    --platforms ' orcarouter, kilo,orcarouter ' > "$TMP_ROOT/subset.out" 2> "$TMP_ROOT/subset.err" || return 1
  [[ "$(awk '$1=="orcarouter"{n++} END{print n+0}' "$CALL_LOG")" == 3 ]]
  [[ "$(awk '$1=="kilo"{n++} END{print n+0}' "$CALL_LOG")" == 3 ]]
  ! grep -Eq '^(openrouter|teamorouter)[[:space:]]' "$CALL_LOG"

  : > "$CALL_LOG"
  CCR_SKIP_POOL=1 run_refresh "$TMP_ROOT/input.json" "$TMP_ROOT/default.json" \
    > "$TMP_ROOT/default.out" 2> "$TMP_ROOT/default.err" || return 1
  [[ "$(wc -l < "$CALL_LOG")" == 12 ]]
  for platform in openrouter orcarouter teamorouter kilo; do
    [[ "$(awk -v p="$platform" '$1==p{n++} END{print n+0}' "$CALL_LOG")" == 3 ]]
  done
}

case_strict_delegation() {
  : > "$CALL_LOG"
  CCR_SKIP_POOL=1 run_refresh "$TMP_ROOT/input.json" "$TMP_ROOT/delegated.json" \
    --platforms orcarouter > "$TMP_ROOT/delegated.out" 2> "$TMP_ROOT/delegated.err" || return 1
  [[ "$(awk '$2=="table"{n++} END{print n+0}' "$CALL_LOG")" == 1 ]]
  [[ "$(awk '$2=="json-ids"{n++} END{print n+0}' "$CALL_LOG")" == 1 ]]
  [[ "$(awk '$2=="sizes"{n++} END{print n+0}' "$CALL_LOG")" == 1 ]]
  ! rg -n 'CATALOG_URL|/models|is_free|pricing\.prompt|pricing\.completion' "$REFRESH"
}

case_provider_reconciliation() {
  : > "$CALL_LOG"
  CCR_SKIP_POOL=1 run_refresh "$TMP_ROOT/input.json" "$TMP_ROOT/reconciled.json" \
    --platforms orcarouter,teamorouter,kilo > "$TMP_ROOT/reconciled.out" 2> "$TMP_ROOT/reconciled.err" \
    || { cat "$TMP_ROOT/reconciled.out" "$TMP_ROOT/reconciled.err"; return 1; }
  jq -e '
    . as $config
    | ($config.Providers | length) == 5
    and ([$config.Providers[] | select(.id == "openrouter") | .models][0] == ["keep/openrouter"])
    and ([$config.Providers[] | select(.id == "custom") | .models][0] == ["custom/model"])
    and all(["orcarouter","teamorouter","kilo"][];
      . as $p
      | [$config.Providers[] | select(.id == $p) | .models][0] == [($p + "/free-a"),($p + "/free-b")])
  ' "$TMP_ROOT/reconciled.json" >/dev/null
}

case_credentials() {
  jq '.Providers += [{
    id:"orcarouter",name:"OrcaRouter",api_base_url:"https://api.orcarouter.ai/v1",
    type:"openai_chat_completions",models:["old/free"],credentials:[
      {id:"manual-orca",name:"manual",api_key:"manual-secret"},
      {id:"env-free-models-orcarouter-old",name:"old",api_key:"old-secret"}
    ]
  }]' "$TMP_ROOT/input.json" > "$TMP_ROOT/credentials-input.json"
  local secret='bdd-new-secret-must-not-leak-62179'
  : > "$CALL_LOG"
  BDD_ORCA_KEY="$secret" CCR_POOL_ENV_PREFIX_ORCAROUTER=BDD_ORCA_KEY \
    run_refresh "$TMP_ROOT/credentials-input.json" "$TMP_ROOT/credentials-output.json" \
    --platforms orcarouter > "$TMP_ROOT/credentials.out" 2> "$TMP_ROOT/credentials.err" || return 1
  jq -e '
    [.Providers[] | select(.id == "orcarouter") | .credentials][0] as $c
    | any($c[]; .id == "manual-orca")
      and ([$c[] | select(.id | startswith("env-free-models-orcarouter-"))] | length) == 1
      and all($c[]; .id != "env-free-models-orcarouter-old")
  ' "$TMP_ROOT/credentials-output.json" >/dev/null
  ! grep -Fq "$secret" "$TMP_ROOT/credentials.out" "$TMP_ROOT/credentials.err"
}

case_fail_fast() {
  : > "$CALL_LOG"
  BDD_FAIL_PLATFORM=teamorouter CCR_SKIP_POOL=1 \
    run_refresh "$TMP_ROOT/input.json" "$TMP_ROOT/must-not-exist.json" \
    --platforms orcarouter,teamorouter,kilo > "$TMP_ROOT/failure.out" 2> "$TMP_ROOT/failure.err" && return 1
  [[ ! -e "$TMP_ROOT/must-not-exist.json" ]]
  ! awk '$1=="kilo"{found=1} END{exit found ? 0 : 1}' "$CALL_LOG"
}

case_local_symlinks() {
  local name target expected
  for name in \
    get-free-models-openrouter.sh \
    get-free-models-orcarouter.sh \
    get-free-models-teamorouter.sh \
    get-free-models-kilo.sh \
    refresh-free-models-claude-code-router.sh; do
    [[ -L "$HOME/.local/bin/$name" ]]
    target="$(readlink -f "$HOME/.local/bin/$name")"
    expected="$(readlink -f "$ROOT/scripts/$name")"
    [[ "$target" == "$expected" ]]
    [[ -x "$target" ]]
  done
  [[ ! -e "$HOME/.local/bin/openrouter-free-models.sh" ]]
  [[ ! -e "$HOME/.local/bin/refresh-free-models.sh" ]]
}

run_case "REQ-FMR-001" "Выбор платформ" case_platform_selection
run_case "REQ-FMR-002" "Строгое делегирование" case_strict_delegation
run_case "REQ-FMR-003" "Reconciliation провайдеров" case_provider_reconciliation
run_case "REQ-FMR-004" "Безопасные credentials" case_credentials
run_case "REQ-FMR-005" "Fail-fast до применения" case_fail_fast
run_case "REQ-FMR-006" "Локальные симлинки" case_local_symlinks
