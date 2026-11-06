#!/usr/bin/env bash
#
# Shared engine for the provider-specific get-free-models-*.sh commands.
# Fetch a provider catalog, extract explicitly free models,
# parse their sizes (params/active/ctx) from description + id,
# optionally fetch per-provider endpoint metrics (latency, throughput, uptime),
# sort by size (total params desc, active params desc, ctx desc),
# and output in requested format.
#
# Every format also reports access for the requesting user: expiration date,
# whether the model is open to this account, free-request quota left today,
# per-minute cap and (with --with-endpoints) how many providers are up.
#
# Usage:
#   free-models-provider-common.sh PROVIDER [--format table|json|ids] [--limit N] [--sort total,active,ctx]
#                             [--with-endpoints] [--endpoints-concurrency N] [--cache-dir DIR]
#                             [--max-age SECONDS] [--max-age-endpoints SECONDS] [--refresh] [--offline]
#
# Exit codes: 0 = ok, 1 = bad args, 2 = no data (empty catalog or no :free models)
#
# Dependencies: curl, jq, column (for table format)
# Optional: parallel (for faster endpoint fetching with --with-endpoints)
#
# Environment:
# Provider-specific variables use ORCAROUTER_, TEAMOROUTER_, or KILO_ prefixes.
# Run a provider wrapper with --help for the complete list.
#
# The key value never enters the script: curl imports it from the environment
# by name (--variable %NAME, curl >= 8.3). Only quota counters are cached —
# /api/v1/key also returns "label", a fragment of the key itself.
#
# The script is self-contained and has no external dependencies beyond curl + jq.
# It does NOT require docker, docker-compose, or any CCR configuration.

set -Eeuo pipefail

[[ $# -ge 1 ]] || {
  printf 'provider-free-models: internal PROVIDER argument is required\n' >&2
  exit 1
}
PROVIDER="$1"
shift

# --- Configuration -----------------------------------------------------------

case "$PROVIDER" in
  orcarouter)
    TOOL_NAME="get-free-models-orcarouter"
    ENV_PREFIX="ORCAROUTER"
    API_BASE="${ORCAROUTER_API_BASE:-https://api.orcarouter.ai/v1}"
    CATALOG_URL="${ORCAROUTER_CATALOG_URL:-$API_BASE/models}"
    KEY_ENV="${ORCAROUTER_KEY_ENV:-ORCAROUTER_API_KEY}"
    CACHE_DIR="${ORCAROUTER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/orcarouter}"
    MAX_AGE="${ORCAROUTER_CACHE_MAX_AGE:-86400}"
    MAX_AGE_EP="${ORCAROUTER_CACHE_MAX_AGE_EP:-1800}"
    OFFLINE="${ORCAROUTER_OFFLINE:-0}"
    REFRESH="${ORCAROUTER_REFRESH:-0}"
    RATE_SUMMARY="free quota counters are not published by the catalog API"
    ;;
  teamorouter)
    TOOL_NAME="get-free-models-teamorouter"
    ENV_PREFIX="TEAMOROUTER"
    API_BASE="${TEAMOROUTER_API_BASE:-https://api.teamorouter.com/v1}"
    CATALOG_URL="${TEAMOROUTER_CATALOG_URL:-$API_BASE/models}"
    KEY_ENV="${TEAMOROUTER_KEY_ENV:-TEAMOROUTER_API_KEY}"
    CACHE_DIR="${TEAMOROUTER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/teamorouter}"
    MAX_AGE="${TEAMOROUTER_CACHE_MAX_AGE:-86400}"
    MAX_AGE_EP="${TEAMOROUTER_CACHE_MAX_AGE_EP:-1800}"
    OFFLINE="${TEAMOROUTER_OFFLINE:-0}"
    REFRESH="${TEAMOROUTER_REFRESH:-0}"
    RATE_SUMMARY="documented free allowance is 50 requests/day; live counters are unavailable"
    ;;
  kilo)
    TOOL_NAME="get-free-models-kilo"
    ENV_PREFIX="KILO"
    API_BASE="${KILO_API_BASE:-https://ai-gateway.kilo.ai/api/v1}"
    CATALOG_URL="${KILO_CATALOG_URL:-$API_BASE/models}"
    KEY_ENV="${KILO_KEY_ENV:-KILO_API_KEY}"
    CACHE_DIR="${KILO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kilo}"
    MAX_AGE="${KILO_CACHE_MAX_AGE:-86400}"
    MAX_AGE_EP="${KILO_CACHE_MAX_AGE_EP:-1800}"
    OFFLINE="${KILO_OFFLINE:-0}"
    REFRESH="${KILO_REFRESH:-0}"
    RATE_SUMMARY="free limit is 200 requests/hour per IP; live counters are unavailable"
    ;;
  *)
    printf 'provider-free-models: unsupported provider: %s\n' "$PROVIDER" >&2
    exit 1
    ;;
esac
FORMAT="table"
LIMIT=0
SORT_SPEC="total,active,ctx"
WITH_ENDPOINTS=0
ENDPOINTS_CONCURRENCY=4

# --- Helpers -----------------------------------------------------------------

die() {
  printf '%s: %s\n' "$TOOL_NAME" "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat >&2 <<EOF
Usage: ${TOOL_NAME}.sh [options]

Options:
  --format FORMAT              Output format: table (default), json, ids, json-ids, sizes
  --limit N                    Limit output to first N models
  --sort SPEC                  Sort specification: comma-separated keys from {total,active,ctx,id}
                               Prefix with + for ascending, - for descending (default).
                               Numeric keys default to descending, id defaults to ascending.
                               Example: --sort +ctx,-total,active
  --with-endpoints             Fetch per-provider endpoint metrics (latency, throughput, uptime)
  --endpoints-concurrency N    Max parallel endpoint requests (default: 4)
  --cache-dir DIR              Cache directory (default: \$XDG_CACHE_HOME/${PROVIDER})
  --max-age SECONDS            Catalog cache TTL in seconds (default: 86400)
  --max-age-endpoints SECONDS  Endpoints cache TTL in seconds (default: 1800)
  --refresh                    Force cache refresh (both catalog and endpoints)
  --offline                    Use only cached data, fail if unavailable
  -h, --help                   Show this help

Environment variables:
  ${ENV_PREFIX}_CATALOG_URL       Override catalog endpoint
  ${ENV_PREFIX}_CACHE_DIR         Cache directory
  ${ENV_PREFIX}_CACHE_MAX_AGE     Catalog cache TTL in seconds
  ${ENV_PREFIX}_CACHE_MAX_AGE_EP  Endpoint cache TTL in seconds
  ${ENV_PREFIX}_OFFLINE=1         Offline mode
  ${ENV_PREFIX}_REFRESH=1         Force refresh
  ${ENV_PREFIX}_KEY_ENV           Name of the API key variable (default ${KEY_ENV})

Access fields (every format): expiration date and days left, whether the model
is open to this account when the provider exposes that fact, documented rate
limits when available, and providers up when a public metric exists.
table: units in the second header row, bare numbers in cells, account line
below; json: "access" object per model; sizes: "access" on :free entries;
ids/json-ids: stdout unchanged, access summary goes to stderr.
Account line ("Access (VAR): free requests today ...") in every format: below
the table; on stderr for the rest; also as "_account" in sizes and
"access.account" of each model in json.
json/sizes pair every number with its unit: "ctx": 262144, "ctx_unit": "tokens".

Exit codes:
  0  Success
  1  Invalid arguments
  2  No data (empty catalog or no :free models)
EOF
  exit 1
}

# --- Parse arguments ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      [[ $# -ge 2 ]] || die "--format requires a value"
      FORMAT="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || die "--limit requires a value"
      LIMIT="$2"
      shift 2
      ;;
    --sort)
      [[ $# -ge 2 ]] || die "--sort requires a value"
      SORT_SPEC="$2"
      shift 2
      ;;
    --with-endpoints)
      WITH_ENDPOINTS=1
      shift
      ;;
    --endpoints-concurrency)
      [[ $# -ge 2 ]] || die "--endpoints-concurrency requires a value"
      ENDPOINTS_CONCURRENCY="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a value"
      CACHE_DIR="$2"
      shift 2
      ;;
    --max-age)
      [[ $# -ge 2 ]] || die "--max-age requires a value"
      MAX_AGE="$2"
      shift 2
      ;;
    --max-age-endpoints)
      [[ $# -ge 2 ]] || die "--max-age-endpoints requires a value"
      MAX_AGE_EP="$2"
      shift 2
      ;;
    --refresh)
      REFRESH=1
      shift
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Validate format
case "$FORMAT" in
  table|json|ids|json-ids|sizes) ;;
  *) die "Invalid --format: $FORMAT (must be table, json, ids, json-ids, or sizes)" ;;
esac

# Validate concurrency
if ! [[ "$ENDPOINTS_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
  die "Invalid --endpoints-concurrency: $ENDPOINTS_CONCURRENCY (must be positive integer)"
fi

# The name is spliced into a curl template, so it must be a plain identifier
[[ "$KEY_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid ${ENV_PREFIX}_KEY_ENV: $KEY_ENV"

# --- Cache management --------------------------------------------------------

mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/models.json"
CACHE_META="$CACHE_DIR/models.meta"
EP_CACHE_DIR="$CACHE_DIR/endpoints"
mkdir -p "$EP_CACHE_DIR"

should_refresh() {
  [[ "$REFRESH" == "1" ]] && return 0
  [[ "$OFFLINE" == "1" ]] && return 1
  [[ -f "$CACHE_FILE" ]] || return 0
  [[ -f "$CACHE_META" ]] || return 0
  local now age
  now=$(date +%s)
  age=$((now - $(cat "$CACHE_META" 2>/dev/null || echo 0)))
  (( age > MAX_AGE ))
}

fetch_catalog() {
  local tmp_file
  tmp_file=$(mktemp "$CACHE_DIR/models.XXXXXX.json")
  local curl_args=(-fsSL --max-time 60)
  if [[ -n "${!KEY_ENV-}" ]]; then
    curl_args+=(--variable "%$KEY_ENV" --expand-header "Authorization: Bearer {{$KEY_ENV}}")
  fi
  if ! curl "${curl_args[@]}" "$CATALOG_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! jq -e '.data | type == "array" and length > 0' "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    return 1
  fi
  mv "$tmp_file" "$CACHE_FILE"
  date +%s > "$CACHE_META"
  return 0
}

# Load catalog (with cache logic)
if should_refresh; then
  if ! fetch_catalog; then
    if [[ "$OFFLINE" == "1" ]]; then
      die "Offline mode: cache miss or fetch failed" 2
    fi
    [[ -f "$CACHE_FILE" ]] || die "Failed to fetch catalog and no cache available" 2
    printf 'warn: using stale catalog cache (fetch failed)\n' >&2
  fi
elif [[ ! -f "$CACHE_FILE" ]]; then
  if [[ "$OFFLINE" == "1" ]]; then
    die "Offline mode: no catalog cache available" 2
  fi
  if ! fetch_catalog; then
    die "Failed to fetch catalog and no cache available" 2
  fi
fi

# --- jq library for size parsing ---------------------------------------------

read -r -d '' JQ_LIB <<'JQEOF' || true
# Scale suffix: "5.1B" -> 5.1 * 1e9
def _scale($u): {"K":1000,"M":1000000,"B":1000000000,"T":1000000000000}[$u | ascii_upcase] // 1;

# Extract number from match with named groups n (value) and u (suffix)
def _qty: (.captures | map({(.name): .string}) | add) as $c
  | ($c.n | tonumber) * _scale($c.u);

# First match from list of patterns; null if none
def _first($text; $pats): [ $pats[] as $p | $text | match($p; "ig") | _qty ] | first;

# Provider catalogs use different explicit markers for free access.
def _zero($v): (($v // null) | tostring | tonumber?) == 0;
def is_free($provider):
  if $provider == "orcarouter" then
    .id == "orcarouter/free"
    or (.id | endswith("-free"))
    or (((.name // "") | ascii_downcase) | contains("(free)"))
    or (_zero(.pricing.prompt) and _zero(.pricing.completion))
    or ((_zero(.pricing.request)) and ((.id | ascii_downcase) | contains("free")))
  elif $provider == "teamorouter" then
    .id | endswith("-free")
  elif $provider == "kilo" then
    .isFree == true
  else false end;

def _active($text): _first($text; [
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])\\s*(?:of\\s+)?active(?:ly)?[\\s-]*(?:param|expert)",
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])\\s*active\\b",
  "activat(?:ing|es|ed)\\s+(?:just\\s+|only\\s+)?(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])",
  "active\\s+parameters?\\s*(?:of|:)?\\s*(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])"
]);

# Total params - order matters: "out of 550B total" first to avoid MoE confusion
def _total($text): _first($text; [
  "out\\s+of\\s+(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])\\s*total",
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])\\s*total",
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])[\\s-]*parameter",
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])[\\s-]*(?:dense|sparse|MoE|mixture)",
  "(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[BM])\\s*param"
]);

# Training tokens - exclude context window mentions
def _tokens($text): [ $text
  | match("(?<n>[0-9]+(?:\\.[0-9]+)?)\\s*(?<u>[TBM])\\s*tokens?\\b"; "ig")
  | select((($text[([(.offset - 90), 0] | max):(.offset + .length + 30)])
            | test("context|window"; "i")) | not)
  | _qty ] | first;

# Size from id: "qwen3-235b-a22b" -> 235B/22B, "gemma-4-31b-it" -> 31B
def _id_size($id): ($id | ascii_downcase) as $s
  | ([$s | capture("(?<t>[0-9]+(?:\\.[0-9]+)?)b-a(?<a>[0-9]+(?:\\.[0-9]+)?)b")] | first) as $moe
  | ([$s | capture("[-/](?<t>[0-9]+(?:\\.[0-9]+)?)b(?:[^a-z0-9]|$)")] | first) as $dense
  | if $moe != null then
      {total: (($moe.t | tonumber) * 1000000000), active: (($moe.a | tonumber) * 1000000000)}
    elif $dense != null then
      {total: (($dense.t | tonumber) * 1000000000), active: null}
    else {total: null, active: null} end;

# Apply to catalog record
def model_size: ((.description // "") | gsub("\\s+"; " ")) as $d
  | _id_size(.id) as $from_id
  | { ctx:    (.context_length // .top_provider.context_length // 0),
      total:  (_total($d)  // $from_id.total),
      active: (_active($d) // $from_id.active),
      tokens: _tokens($d) };

# Map: id -> sizes for entire catalog (input is .data array)
def size_map: reduce .[] as $m ({}; .[$m.id] = ($m | model_size));

# Thousands separator: 1024 -> "1 024", 46981 -> "46 981" (decimals untouched)
def group3:
  tostring
  | split(".") as $p
  | ($p[0] | gsub("(?<=\\d)(?=(?:\\d{3})+$)"; " "))
    + (if ($p | length) > 1 then "." + $p[1] else "" end);

# Number + unit, space-separated: 1024,"k" -> "1 024 k"; null -> "—"
def unit($u): if . == null then "—" else (group3) + " " + $u end;

# Human readable: 1.2 B, 550 M, etc.
def human: if . == null then "—"
  elif . >= 1000000000000 then ((. / 100000000000 | round) / 10 | unit("T"))
  elif . >= 1000000000    then ((. / 100000000    | round) / 10 | unit("B"))
  elif . >= 1000000       then ((. / 100000       | round) / 10 | unit("M"))
  else unit("") | rtrimstr(" ") end;

# Table cell in a fixed unit named in the column header: value / $div,
# one decimal (two below 1 so small models do not collapse to 0); null -> "—"
def in_unit($div): if . == null then "—"
  else (. / $div) as $v
  | (if $v < 1 then ($v * 100 | round) / 100 else ($v * 10 | round) / 10 end) | group3 end;

# Units of every numeric field the script emits, one place for all formats.
# Machine formats get a "<key>_unit" pair next to each such key.
def size_units: {ctx: "tokens", total: "parameters", active: "parameters", tokens: "tokens"};
def endpoint_units: {latency_ms: "ms", throughput_tps: "tokens/s", uptime_pct: "%",
                     endpoint_count: "endpoints", providers_up: "providers", providers_total: "providers"};
def access_units: {expires: "date YYYY-MM-DD", days_left: "days", requests_minute: "requests/min"};
# Catalog fields with a documented unit; prices without one stay unannotated
def catalog_units: {context_length: "tokens", created: "unix seconds", expiration_date: "date YYYY-MM-DD"};
def top_provider_units: {context_length: "tokens", max_completion_tokens: "tokens"};
def pricing_units: {prompt: "USD/token", completion: "USD/token", internal_reasoning: "USD/token",
                    input_cache_read: "USD/token", input_cache_write: "USD/token",
                    request: "USD/request", image: "USD/image", web_search: "USD/search"};

def with_units($units):
  if type != "object" then .
  else reduce ($units | to_entries[]) as $e (.;
    if has($e.key) then .[$e.key + "_unit"] = $e.value else . end) end;

def access_with_units:
  with_units(access_units)
  | if .requests_day == null then . else .requests_day += {unit: "requests/day"} end
  | if .providers == null then . else .providers += {unit: "providers"} end;

def catalog_with_units:
  with_units(catalog_units)
  | .top_provider |= with_units(top_provider_units)
  | .pricing |= with_units(pricing_units);

# Empty metrics record — used when a model page yields nothing parseable
def null_metrics:
  { latency_ms: null, throughput_tps: null, uptime_pct: null, endpoint_count: 0,
    providers_up: null, providers_total: null };

# Whole days from $now to the start of date $d ("2026-10-31"); negative = past
def days_until($d; $now):
  if $d == null then null
  else (($d[0:10] + "T00:00:00Z" | fromdateiso8601) - $now) / 86400 | floor end;

# Access record for catalog model $m. $u is the per-user object built by the
# script (see fetch_user_access), $ep the endpoint metrics or null.
# The verdict names the first reason the model cannot be used right now.
def access($m; $u; $ep; $now):
  ($u.free[$m.id] // false) as $free
  | ($m.expiration_date // null) as $exp
  | days_until($exp; $now) as $days
  | (if $u.checked then ($u.open[$m.id] // false) else null end) as $open
  | (if $free and $u.checked then $u.day else null end) as $day
  | (if $ep == null or ($ep.providers_total // 0) == 0 then null
     else {up: $ep.providers_up, total: $ep.providers_total} end) as $prov
  | { expires: $exp,
      days_left: $days,
      open: $open,
      requests_day: $day,
      requests_minute: (if $free then $u.rpm else null end),
      providers: $prov,
      verdict: (
        if $days != null and $days < 0 then "expired"
        elif $open == false then "closed"
        elif $day != null and ($day.remaining // 1) <= 0 then "quota"
        elif $prov != null and $prov.up == 0 then "down"
        elif $prov != null and $prov.up < $prov.total then "partial"
        elif $open == true then "open"
        else $u.unknown end) };

# Map: id -> access for every model in the catalog (input is .data array)
def access_map($u; $eps; $now):
  reduce .[] as $m ({}; .[$m.id] = access($m; $u; $eps[$m.id]; $now));

# Table header: names, then units on their own row so columns stay as narrow
# as their data, then a rule as wide as the wider of the two
def header_rows($names; $units):
  $names, $units,
  ([range($names | length) as $i | "-" * ([($names[$i] | length), ($units[$i] | length)] | max)]
   | .[0] = "-" * 40);

# One line about the account, shared by the table footer and the stderr summary
def account_line($u):
  if $u.checked then
    "Access (" + $u.key_env + "): catalog access checked"
    + (if $u.rate_summary == null or $u.rate_summary == "" then ""
       else "; " + $u.rate_summary end)
  else
    "Access: " + $u.reason
    + (if $u.rate_summary == null or $u.rate_summary == "" then ""
       else "; " + $u.rate_summary end)
  end;

# The same account facts as a machine-readable object, numbers paired with units
def account_obj($u):
  { key_env: $u.key_env,
    checked: $u.checked,
    reason: $u.reason,
    requests_day: (if $u.day == null then null else $u.day + {unit: "requests/day"} end),
    requests_minute: $u.rpm,
    requests_minute_unit: "requests/min",
    summary: account_line($u) };
JQEOF

# Helper to run jq with library + program from temp file
# Usage: run_jq [jq_options...] "program" "input_file"
run_jq() {
  local jq_opts=()
  local program=""
  local input_file=""

  while [[ $# -gt 2 ]]; do
    jq_opts+=("$1")
    shift
  done
  program="$1"
  input_file="$2"

  local tmp_jq
  tmp_jq=$(mktemp "${TMPDIR:-/tmp}/jq_prog.XXXXXX.jq")
  printf '%s\n%s\n' "$JQ_LIB" "$program" > "$tmp_jq"
  jq "${jq_opts[@]}" -f "$tmp_jq" "$input_file"
  local rc=$?
  rm -f "$tmp_jq"
  return $rc
}

# Render a tab-separated stream as an aligned table, right-aligning the numeric
# columns given as a comma-separated list (column 1 — the model id — stays left).
#
# -c is required, not cosmetic: column pads only up to the output width, which
# defaults to the terminal (80). This table is ~124 columns wide, so without an
# explicit width the last column silently loses its padding and stays flush left
# while every other column right-aligns.
#
# -R needs util-linux >= 2.30; older builds fall back to plain -t rather than
# erroring out and losing the table entirely.
TABLE_WIDTH=1000
render_table() {
  local right_cols="$1"
  if column -t -s $'\t' -R "$right_cols" -c "$TABLE_WIDTH" </dev/null >/dev/null 2>&1; then
    column -t -s $'\t' -R "$right_cols" -c "$TABLE_WIDTH"
  else
    column -t -s $'\t'
  fi
}

# --- Endpoint metrics --------------------------------------------------------

# The three providers do not expose an OpenRouter-equivalent public endpoint
# health API. Preserve the schema and report measurements as unknown.
fetch_all_endpoints() {
  local ids_json="$1"
  local output_file="$2"
  jq 'map({key: ., value: {
        latency_ms: null,
        throughput_tps: null,
        uptime_pct: null,
        endpoint_count: 0,
        providers_up: null,
        providers_total: null
      }}) | from_entries' <<< "$ids_json" > "$output_file"
}

# --- Per-user access ---------------------------------------------------------

# The catalog request already used the key when present. No provider here
# exposes OpenRouter-compatible /models/user and /key quota counters.
fetch_user_access() {
  local ids_json="$1"
  local free_map
  free_map=$(jq -c 'map({key: ., value: true}) | from_entries' <<< "$ids_json")

  if [[ -z "${!KEY_ENV-}" ]]; then
    jq -c -n --arg key_env "$KEY_ENV" --arg rate "$RATE_SUMMARY" --argjson free "$free_map" '{
      checked: false,
      reason: ("variable " + $key_env + " is empty, account-specific access not checked"),
      unknown: "no-key",
      open: {},
      free: $free,
      day: null,
      rpm: null,
      rate_summary: $rate,
      key_env: $key_env
    }'
    return 0
  fi

  jq -c -n --arg key_env "$KEY_ENV" --arg rate "$RATE_SUMMARY" --argjson free "$free_map" '{
    checked: true,
    reason: null,
    unknown: "unknown",
    open: $free,
    free: $free,
    day: null,
    rpm: null,
    rate_summary: $rate,
    key_env: $key_env
  }'
}

# --- Build dynamic sort key from --sort spec ---------------------------------

build_sort_keys() {
  local spec="$1"
  local keys_json="["
  local first=1
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    local field="$part"
    local dir=-1
    case "$part" in
      +*) field="${part#+}"; dir=1 ;;
      -*) field="${part#-}"; dir=-1 ;;
    esac
    case "$field" in
      total|active|ctx) ;;
      id) dir=1 ;;
      *) die "Invalid sort field: $field (must be total, active, ctx, or id)" ;;
    esac
    [[ $first -eq 1 ]] || keys_json+=","
    keys_json+="{\"field\":\"$field\",\"dir\":$dir}"
    first=0
  done
  keys_json+="]"
  printf '%s' "$keys_json"
}

SORT_KEYS_JSON=$(build_sort_keys "$SORT_SPEC")

# --- Extract and sort free models --------------------------------------------

# Build size map for entire catalog (from .data array)
sizes_json=$(run_jq '.data | size_map' "$CACHE_FILE")

# Get sorted free model IDs
free_ids=$(run_jq --arg provider "$PROVIDER" --argjson sizes "$sizes_json" --argjson keys "$SORT_KEYS_JSON" '
  ($sizes) as $s
  | ($keys) as $k
  | [.data[] | select(is_free($provider)) | .id]
  | sort_by(
      ($s[.] // {}) as $m
      | [ $k[] as $key
          | (if $key.field == "total" then $m.total
             elif $key.field == "active" then $m.active
             elif $key.field == "ctx" then $m.ctx
             else null end) as $v
          | if $key.field == "id" then (if $key.dir == -1 then [1, .] else [0, .] end)
            elif $v == null then [1, 0]
            else [0, $v * $key.dir] end
        ]
    )
' "$CACHE_FILE")

free_count=$(jq 'length' <<< "$free_ids")
(( free_count > 0 )) || die "No free models found in catalog" 2

# Apply limit
if (( LIMIT > 0 && LIMIT < free_count )); then
  free_ids=$(jq --argjson lim "$LIMIT" '.[:$lim]' <<< "$free_ids")
fi

# --- Fetch endpoints if requested --------------------------------------------

endpoints_json='{}'
if [[ $WITH_ENDPOINTS -eq 1 ]]; then
  if [[ $free_count -gt 0 ]]; then
    ep_output=$(mktemp "${TMPDIR:-/tmp}/ep_output.XXXXXX.json")
    fetch_all_endpoints "$free_ids" "$ep_output"
    endpoints_json=$(cat "$ep_output")
    rm -f "$ep_output"
  fi
fi

# --- Access for the requesting user ------------------------------------------

user_json=$(fetch_user_access "$free_ids")
access_json=$(run_jq -c --argjson u "$user_json" --argjson eps "$endpoints_json" \
  --argjson now "$(date +%s)" '.data | access_map($u; $eps; $now)' "$CACHE_FILE")

# Machine formats keep stdout parseable, so the account line goes to stderr
print_account_line() {
  run_jq -r -n --argjson u "$user_json" 'account_line($u)' /dev/null >&2
}

# ids/json-ids are parsed as plain lists by callers, so access goes to stderr
print_access_summary() {
  run_jq -r -n --argjson ids "$free_ids" --argjson a "$access_json" --argjson u "$user_json" '
    account_line($u),
    ($ids[] as $id | $a[$id] as $x
     | select(($x.verdict | IN("open", $u.unknown) | not) or $x.expires != null)
     | "  " + $id + ": " + $x.verdict
       + (if $x.expires == null then ""
          else ", expires " + $x.expires[0:10] + " (" + ($x.days_left | tostring) + " days)" end))' /dev/null >&2
}

# --- Output ------------------------------------------------------------------

case "$FORMAT" in
  ids)
    jq -r '.[]' <<< "$free_ids"
    print_access_summary
    ;;
  json-ids)
    printf '%s\n' "$free_ids"
    print_access_summary
    ;;
  json)
    # Full model objects for the free models, every number paired with its unit
    run_jq --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson eps "$endpoints_json" \
           --argjson a "$access_json" --argjson we "$WITH_ENDPOINTS" --argjson u "$user_json" '
      ($sizes) as $s
      | ($eps) as $e
      | [$ids[] as $id
         | .data[] | select(.id == $id)
         | catalog_with_units
         | . + {size: ($s[$id] | with_units(size_units))}
         | if $we == 1 then . + {endpoints: (($e[$id] // null_metrics) | with_units(endpoint_units))} else . end
         | . + {access: ($a[$id] | access_with_units | .account = account_obj($u))}
        ]
    ' "$CACHE_FILE"
    print_account_line
    ;;
  sizes)
    # Callers read ctx/total/active/tokens by name; units and access are added
    # keys. Keep compact output and attach access only to selected free entries.
    # _account cannot clash with a model id: ids always contain "/"
    run_jq -n -c --argjson ids "$free_ids" --argjson s "$sizes_json" --argjson a "$access_json" --argjson u "$user_json" '
      ($ids | map({key: ., value: true}) | from_entries) as $free
      | ($s | with_entries(
        .value |= with_units(size_units)
        | if $free[.key] then .value += {access: ($a[.key] | access_with_units)} else . end))
      + {_account: account_obj($u)}
    ' /dev/null
    print_account_line
    ;;
  table)
    # Each column holds one fixed unit, named in the second header row, so cells are bare numbers
    if [[ $WITH_ENDPOINTS -eq 1 ]]; then
      run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson eps "$endpoints_json" \
                --argjson a "$access_json" '
        ($sizes) as $s
        | ($eps) as $e
        | ["Model ID", "Context", "Params", "Active", "Latency", "Throughput", "Uptime",
           "Providers", "Expires", "Left", "Access"] as $h
        | ["", "Ki tokens", "B", "B", "ms", "tokens/s", "%", "up/total", "YYYY-MM-DD", "days", ""] as $u
        | header_rows($h; $u),
          ($ids[] as $id
           | ($s[$id] // {}) as $m
           | ($e[$id] // null_metrics) as $ep
           | $a[$id] as $x
           | [
               $id,
               ($m.ctx | in_unit(1024)),
               ($m.total  | in_unit(1000000000)),
               ($m.active | in_unit(1000000000)),
               (if $ep.latency_ms == null then "—" else ($ep.latency_ms | round | group3) end),
               (if $ep.throughput_tps == null then "—" else ($ep.throughput_tps | group3) end),
               (if $ep.uptime_pct == null then "—" else ($ep.uptime_pct | group3) end),
               (if $x.providers == null then "—"
                else ($x.providers.up | tostring) + "/" + ($x.providers.total | tostring) end),
               ($x.expires // "—" | .[0:10]),
               (if $x.days_left == null then "—" else ($x.days_left | tostring) end),
               $x.verdict
             ])
        | @tsv
      ' "$CACHE_FILE" | render_table 2,3,4,5,6,7,8,10
    else
      run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson a "$access_json" '
        ($sizes) as $s
        | ["Model ID", "Context", "Params", "Active", "Training", "Expires", "Left", "Access"] as $h
        | ["", "Ki tokens", "B", "B", "T tokens", "YYYY-MM-DD", "days", ""] as $u
        | header_rows($h; $u),
          ($ids[] as $id | ($s[$id] // {}) as $m | $a[$id] as $x | [
            $id,
            ($m.ctx | in_unit(1024)),
            ($m.total  | in_unit(1000000000)),
            ($m.active | in_unit(1000000000)),
            ($m.tokens | in_unit(1000000000000)),
            ($x.expires // "—" | .[0:10]),
            (if $x.days_left == null then "—" else ($x.days_left | tostring) end),
            $x.verdict
          ])
        | @tsv
      ' "$CACHE_FILE" | render_table 2,3,4,5,7
    fi
    run_jq -r -n --argjson u "$user_json" '"", account_line($u)' /dev/null
    ;;
esac

exit 0
