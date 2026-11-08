#!/usr/bin/env bash
#
# Standalone tool: fetch OpenRouter catalog, extract :free models,
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
#   openrouter-free-models.sh [--format table|json|ids] [--limit N] [--sort total,active,ctx]
#                             [--with-endpoints] [--endpoints-concurrency N] [--cache-dir DIR]
#                             [--max-age SECONDS] [--max-age-endpoints SECONDS] [--refresh] [--offline]
#
# Exit codes: 0 = ok, 1 = bad args, 2 = no data (empty catalog or no :free models)
#
# Dependencies: curl, jq, column (for table format)
# Optional: parallel (for faster endpoint fetching with --with-endpoints)
#
# Environment:
#   OPENROUTER_CATALOG_URL        override catalog endpoint (default https://openrouter.ai/api/v1/models)
#   OPENROUTER_CACHE_DIR          cache directory (default $XDG_CACHE_HOME/openrouter or ~/.cache/openrouter)
#   OPENROUTER_CACHE_MAX_AGE      catalog cache TTL in seconds (default 86400 = 24h)
#   OPENROUTER_CACHE_MAX_AGE_EP   endpoints cache TTL in seconds (default 1800 = 30min)
#   OPENROUTER_OFFLINE=1          use only cached data, fail if stale/missing
#   OPENROUTER_REFRESH=1          force cache refresh
#   OPENROUTER_KEY_ENV            NAME of the variable holding the API key
#                                 (default OPENROUTER_API_KEY); empty variable =
#                                 per-user checks are skipped, nothing is sent
#   OPENROUTER_CACHE_MAX_AGE_USER per-user data cache TTL in seconds (default 120)
#
# The key value never enters the script: curl imports it from the environment
# by name (--variable %NAME, curl >= 8.3). Only quota counters are cached —
# /api/v1/key also returns "label", a fragment of the key itself.
#
# The script is self-contained and has no external dependencies beyond curl + jq.
# It does NOT require docker, docker-compose, or any CCR configuration.

set -Eeuo pipefail

# --- Configuration -----------------------------------------------------------

API_BASE="${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}"
CATALOG_URL="${OPENROUTER_CATALOG_URL:-$API_BASE/models}"
PAGE_BASE_URL="${OPENROUTER_PAGE_BASE_URL:-https://openrouter.ai}"
# The per-minute free cap is not in any API response, only in the docs source
LIMITS_DOC_URL="${OPENROUTER_LIMITS_DOC_URL:-$PAGE_BASE_URL/docs/api/reference/limits.md}"
KEY_ENV="${OPENROUTER_KEY_ENV:-OPENROUTER_API_KEY}"
MAX_AGE_USER="${OPENROUTER_CACHE_MAX_AGE_USER:-120}"
PAGE_USER_AGENT="${OPENROUTER_PAGE_UA:-Mozilla/5.0 (X11; Linux x86_64) openrouter-free-models.sh}"
CACHE_DIR="${OPENROUTER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openrouter}"
MAX_AGE="${OPENROUTER_CACHE_MAX_AGE:-86400}"
MAX_AGE_EP="${OPENROUTER_CACHE_MAX_AGE_EP:-1800}"
OFFLINE="${OPENROUTER_OFFLINE:-0}"
REFRESH="${OPENROUTER_REFRESH:-0}"
FORMAT="table"
LIMIT=0
SORT_SPEC="total,active,ctx"
WITH_ENDPOINTS=0
ENDPOINTS_CONCURRENCY=4

# --- Helpers -----------------------------------------------------------------

die() {
  printf 'openrouter-free-models: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF' >&2
Usage: openrouter-free-models.sh [options]

Options:
  --format FORMAT              Output format: table (default), json, ids, json-ids, sizes
  --limit N                    Limit output to first N models
  --sort SPEC                  Sort specification: comma-separated keys from {total,active,ctx,id}
                               Prefix with + for ascending, - for descending (default).
                               Numeric keys default to descending, id defaults to ascending.
                               Example: --sort +ctx,-total,active
  --with-endpoints             Fetch per-provider endpoint metrics (latency, throughput, uptime)
  --endpoints-concurrency N    Max parallel endpoint requests (default: 4)
  --cache-dir DIR              Cache directory (default: $XDG_CACHE_HOME/openrouter)
  --max-age SECONDS            Catalog cache TTL in seconds (default: 86400)
  --max-age-endpoints SECONDS  Endpoints cache TTL in seconds (default: 1800)
  --refresh                    Force cache refresh (both catalog and endpoints)
  --offline                    Use only cached data, fail if unavailable
  -h, --help                   Show this help

Environment variables:
  OPENROUTER_CATALOG_URL         Override catalog endpoint
  OPENROUTER_CACHE_DIR           Cache directory
  OPENROUTER_CACHE_MAX_AGE       Catalog cache TTL in seconds
  OPENROUTER_CACHE_MAX_AGE_EP    Endpoints cache TTL in seconds
  OPENROUTER_OFFLINE=1           Offline mode
  OPENROUTER_REFRESH=1           Force refresh
  OPENROUTER_KEY_ENV             Name of the API key variable (default OPENROUTER_API_KEY)
  OPENROUTER_CACHE_MAX_AGE_USER  Per-user data cache TTL in seconds (default 120)

Access fields (every format): expiration date and days left, whether the model
is open to this account (/api/v1/models/user), free requests used/left today
(/api/v1/key), per-minute cap (docs), providers up (--with-endpoints).
table: units in the column headers, bare numbers in cells, account line
below; json: "access" object per model; sizes: "access" on :free entries;
ids/json-ids: stdout unchanged, access summary goes to stderr.
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
[[ "$KEY_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid OPENROUTER_KEY_ENV: $KEY_ENV"

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
  if ! curl -fsS --max-time 30 "$CATALOG_URL" -o "$tmp_file"; then
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
  | { ctx:    (.context_length // 0),
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
  ($m.id | endswith(":free")) as $free
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

# One line about the account, shared by the table footer and the stderr summary
def account_line($u):
  if $u.checked then
    "Access (" + $u.key_env + "): free requests today "
    + (if $u.day == null then "—"
       else ($u.day.used | tostring) + " of " + ($u.day.limit | tostring)
            + ", remaining " + ($u.day.remaining | tostring) end)
    + (if $u.rpm == null then "" else "; max " + ($u.rpm | tostring) + " requests/min" end)
  else
    "Access: " + $u.reason
    + (if $u.rpm == null then ""
       else "; free models: " + ($u.rpm | tostring) + " requests/min"
            + (if $u.rpd_low == null then ""
               else ", " + ($u.rpd_low | tostring) + " requests/day (under "
                    + ($u.credits_threshold | tostring) + " credits purchased) or "
                    + ($u.rpd_high | tostring) end) end)
  end;
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
#
# Source of truth is the model's public page on openrouter.ai, NOT the JSON API.
# /api/v1/models/{id}/endpoints returns null for latency_last_30m and
# throughput_last_30m on every model (free and paid alike) — only uptime is
# populated there. The real numbers are embedded in the page's Next.js flight
# payload as escaped JSON:
#
#   \"stats\":{\"endpoint_id\":...,\"p50_latency\":1408,\"p50_throughput\":13,...}
#   \"hourly\":[{\"timestamp\":\"...\",\"uptime\":100,\"availability\":99.8},...]
#
# Note: provider attribution is deliberately NOT attempted. The page carries a
# global provider directory (~110 provider_name entries) that is not adjacent to
# the per-endpoint stats blocks, so pairing metrics to a provider by proximity
# would be fabrication. Metrics are aggregated across the model's endpoints:
# best-case latency (min) and best-case throughput (max).

# Download a model page into the cache, honoring TTL/refresh/offline.
# Prints the cache path on success; prints nothing when no page is available.
fetch_model_page() {
  local model_id="$1"
  local safe_id="${model_id//[\/:]/_}"
  local page_file="$EP_CACHE_DIR/${safe_id}.html"
  local page_meta="$EP_CACHE_DIR/${safe_id}.meta"

  local should_fetch=0
  if [[ "$OFFLINE" == "1" ]]; then
    should_fetch=0
  elif [[ "$REFRESH" == "1" ]]; then
    should_fetch=1
  elif [[ ! -s "$page_file" || ! -f "$page_meta" ]]; then
    should_fetch=1
  else
    local now age
    now=$(date +%s)
    age=$(( now - $(cat "$page_meta" 2>/dev/null || echo 0) ))
    (( age > MAX_AGE_EP )) && should_fetch=1
  fi

  if [[ $should_fetch -eq 1 ]]; then
    local url="${PAGE_BASE_URL}/${model_id}"
    local tmp_file attempt
    tmp_file=$(mktemp "$EP_CACHE_DIR/${safe_id}.XXXXXX.tmp")
    # Retry: under concurrency a single request occasionally returns a
    # truncated page, which would otherwise leave this model showing "—"
    # until the cache expires. --compressed keeps ~840KB down to ~70KB.
    for attempt in 1 2 3; do
      if curl -fsSL --compressed --max-time 25 -A "$PAGE_USER_AGENT" "$url" -o "$tmp_file" 2>/dev/null \
         && [[ -s "$tmp_file" ]] \
         && grep -q '\\"stats\\":{\\"endpoint_id' "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$page_file"
        date +%s > "$page_meta"
        break
      fi
      sleep $(( attempt ))
    done
    # Keep any previous good copy rather than caching a failure
    rm -f "$tmp_file"
  fi

  [[ -s "$page_file" ]] && printf '%s' "$page_file"
  return 0
}

# Parse latency/throughput/uptime out of a cached page into a JSON object.
# Always emits a valid object; unparseable input yields nulls.
parse_page_metrics() {
  local page_file="$1"
  local stats_json uptime_json

  if [[ -z "$page_file" || ! -s "$page_file" ]]; then
    printf '{"latency_ms":null,"throughput_tps":null,"uptime_pct":null,"endpoint_count":0}'
    return 0
  fi

  # Per-endpoint stats blocks -> best latency (min) and best throughput (max)
  stats_json=$(grep -oE '\\"stats\\":\{\\"endpoint_id[^}]*\}' "$page_file" 2>/dev/null \
    | sed 's/\\"/"/g; s/^"stats"://' \
    | jq -s -c '{
        latency_ms: ([.[].p50_latency | numbers] | min),
        throughput_tps: ([.[].p50_throughput | numbers] | max),
        endpoint_count: length
      }' 2>/dev/null) || stats_json=""
  [[ -n "$stats_json" ]] || stats_json='{"latency_ms":null,"throughput_tps":null,"endpoint_count":0}'

  # Hourly uptime series -> mean of the non-null samples, rounded to 0.1%
  uptime_json=$(grep -oE '\\"hourly\\":\[\{\\"timestamp[^]]*\]' "$page_file" 2>/dev/null \
    | head -1 \
    | sed 's/\\"/"/g; s/^"hourly"://' \
    | jq -c '{uptime_pct: ([.[].uptime | numbers] | if length > 0 then (add / length * 10 | round / 10) else null end)}' 2>/dev/null) || uptime_json=""
  [[ -n "$uptime_json" ]] || uptime_json='{"uptime_pct":null}'

  jq -c -n --argjson s "$stats_json" --argjson u "$uptime_json" '$s + $u'
}

# True when the file exists and is younger than TTL seconds (per its .meta stamp)
cache_fresh() {
  local file="$1" meta="$2" ttl="$3"
  [[ -s "$file" && -f "$meta" ]] || return 1
  (( $(date +%s) - $(cat "$meta" 2>/dev/null || echo 0) <= ttl ))
}

# Provider status from the JSON API: the page carries no status, the API does
# (status 0 = serving). Prints {providers_up, providers_total}, nulls if unknown.
fetch_endpoint_status() {
  local model_id="$1"
  local safe_id="${model_id//[\/:]/_}"
  local api_file="$EP_CACHE_DIR/${safe_id}.api.json"
  local api_meta="$EP_CACHE_DIR/${safe_id}.api.meta"

  if [[ "$OFFLINE" != "1" ]] && { [[ "$REFRESH" == "1" ]] || ! cache_fresh "$api_file" "$api_meta" "$MAX_AGE_EP"; }; then
    local tmp_file
    tmp_file=$(mktemp "$EP_CACHE_DIR/${safe_id}.XXXXXX.api.tmp")
    if curl -fsS --max-time 20 "$API_BASE/models/$model_id/endpoints" -o "$tmp_file" 2>/dev/null \
       && jq -e '.data.endpoints | type == "array"' "$tmp_file" >/dev/null 2>&1; then
      mv -f "$tmp_file" "$api_file"
      date +%s > "$api_meta"
    fi
    rm -f "$tmp_file"
  fi

  jq -c '{providers_total: (.data.endpoints | length),
          providers_up: ([.data.endpoints[] | select(.status == 0)] | length)}' \
    "$api_file" 2>/dev/null || printf '{"providers_up":null,"providers_total":null}'
}

# Emit exactly one {model_id: metrics} object per model.
fetch_metrics_for_model() {
  local model_id="$1"
  local page_file metrics status
  page_file=$(fetch_model_page "$model_id")
  metrics=$(parse_page_metrics "$page_file")
  status=$(fetch_endpoint_status "$model_id")
  jq -c -n --arg mid "$model_id" --argjson m "$metrics" --argjson s "$status" '{($mid): ($m + $s)}'
}

fetch_all_endpoints() {
  local ids_json="$1"
  local output_file="$2"

  local ids_file tmp_output
  ids_file=$(mktemp "${TMPDIR:-/tmp}/model_ids.XXXXXX.txt")
  tmp_output=$(mktemp "${TMPDIR:-/tmp}/ep_results.XXXXXX.json")
  jq -r '.[]' <<< "$ids_json" > "$ids_file"

  # Bounded concurrency without depending on GNU parallel: keep at most
  # ENDPOINTS_CONCURRENCY background jobs, each writing one object to its own
  # file so no two writers ever interleave into a shared stream.
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ep_parts.XXXXXX")
  local n=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    fetch_metrics_for_model "$id" > "$work_dir/$(printf '%04d' "$n").json" &
    while (( $(jobs -rp | wc -l) >= ENDPOINTS_CONCURRENCY )); do
      wait -n 2>/dev/null || break
    done
  done < "$ids_file"
  wait

  cat "$work_dir"/*.json > "$tmp_output" 2>/dev/null || true
  if [[ -s "$tmp_output" ]]; then
    jq -s 'add' "$tmp_output" > "$output_file"
  else
    echo '{}' > "$output_file"
  fi

  rm -rf "$work_dir"
  rm -f "$ids_file" "$tmp_output"
}

# --- Per-user access ---------------------------------------------------------

# Free-model caps from the docs source: {rpm, rpd_low, rpd_high, credits_threshold}.
# The API reports the daily counter of a key, never the per-minute cap.
fetch_doc_limits() {
  local file="$CACHE_DIR/limits.json" meta="$CACHE_DIR/limits.meta" parsed
  if [[ "$OFFLINE" != "1" ]] && { [[ "$REFRESH" == "1" ]] || ! cache_fresh "$file" "$meta" "$MAX_AGE"; }; then
    parsed=$(curl -fsSL --max-time 20 "$LIMITS_DOC_URL" 2>/dev/null \
      | grep -oE 'FREE_MODEL_[A-Z_]+ = [0-9]+' \
      | jq -R -s -c '
          [split("\n")[] | select(length > 0) | split(" = ") | {(.[0]): (.[1] | tonumber)}] | add // {}
          | {rpm: .FREE_MODEL_RATE_LIMIT_RPM, rpd_low: .FREE_MODEL_NO_CREDITS_RPD,
             rpd_high: .FREE_MODEL_HAS_CREDITS_RPD, credits_threshold: .FREE_MODEL_CREDITS_THRESHOLD}' \
      2>/dev/null) || parsed=""
    if jq -e '.rpm | numbers' <<<"$parsed" >/dev/null 2>&1; then
      printf '%s\n' "$parsed" > "$file"
      date +%s > "$meta"
    fi
  fi
  cat "$file" 2>/dev/null \
    || printf '{"rpm":null,"rpd_low":null,"rpd_high":null,"credits_threshold":null}\n'
}

# GET with the key that curl itself imports from the variable named KEY_ENV.
# Body goes to $2; prints the HTTP status ("000" when the network failed).
api_get_with_key() {
  curl -sS --max-time 20 -o "$2" -w '%{http_code}' \
    --variable "%$KEY_ENV" --expand-header "Authorization: Bearer {{$KEY_ENV}}" \
    "$1" 2>/dev/null || true
}

# Per-user object: {checked, reason, unknown, open: {id: true}, day: {used, limit, remaining}}
fetch_user_access() {
  local file="$CACHE_DIR/user-$KEY_ENV.json" meta="$CACHE_DIR/user-$KEY_ENV.meta"
  local none='{"checked":false,"open":{},"day":null}'

  # Presence test only: the value is not stored or passed on from here
  if [[ -z "${!KEY_ENV-}" ]]; then
    jq -c --arg r "variable $KEY_ENV is empty, quota and closed models not checked" \
      '. + {reason: $r, unknown: "no-key"}' <<<"$none"
    return 0
  fi

  if [[ "$OFFLINE" == "1" ]]; then
    if [[ -s "$file" ]]; then cat "$file"
    else jq -c '. + {reason: "offline, no access data in cache"}' <<<"$none"; fi
    return 0
  fi
  if [[ "$REFRESH" != "1" ]] && cache_fresh "$file" "$meta" "$MAX_AGE_USER"; then
    cat "$file"
    return 0
  fi

  local models_tmp key_tmp code_m code_k result=""
  models_tmp=$(mktemp "${TMPDIR:-/tmp}/or_user_models.XXXXXX.json")
  key_tmp=$(mktemp "${TMPDIR:-/tmp}/or_user_key.XXXXXX.json")
  code_m=$(api_get_with_key "$API_BASE/models/user?output_modalities=all" "$models_tmp")
  code_k=$(api_get_with_key "$API_BASE/key" "$key_tmp")
  if [[ "$code_m" == 200 && "$code_k" == 200 ]]; then
    # Only the counters survive: the key response also carries "label"
    result=$(jq -n -c --slurpfile m "$models_tmp" --slurpfile k "$key_tmp" '
      {checked: true,
       open: ([$m[0].data[].id | {(.): true}] | add // {}),
       day: ($k[0].data.free_model_daily_requests
             | if . == null then null else {used, limit, remaining} end)}' 2>/dev/null) || result=""
  fi
  rm -f "$models_tmp" "$key_tmp"

  if [[ -n "$result" ]]; then
    printf '%s\n' "$result" > "$file"
    date +%s > "$meta"
    printf '%s\n' "$result"
  elif [[ "$code_m" == 000 || "$code_k" == 000 ]] && [[ -s "$file" ]]; then
    printf 'warn: using stale access cache (fetch failed)\n' >&2
    cat "$file"
  else
    local reason="API error: /models/user HTTP $code_m, /key HTTP $code_k"
    case "$code_m$code_k" in
      *401*|*403*) reason="key from $KEY_ENV rejected: /models/user HTTP $code_m, /key HTTP $code_k" ;;
      000*|*000)   reason="network unavailable, no access data" ;;
    esac
    jq -c --arg r "$reason" '. + {reason: $r}' <<<"$none"
  fi
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
free_ids=$(run_jq --argjson sizes "$sizes_json" --argjson keys "$SORT_KEYS_JSON" '
  ($sizes) as $s
  | ($keys) as $k
  | [.data[] | select(.id | endswith(":free")) | .id]
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
(( free_count > 0 )) || die "No :free models found in catalog" 2

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

user_json=$(jq -c -n --argjson u "$(fetch_user_access)" --argjson l "$(fetch_doc_limits)" \
  --arg k "$KEY_ENV" '{reason: null, unknown: "unknown"} + $u + $l + {key_env: $k}')
access_json=$(run_jq -c --argjson u "$user_json" --argjson eps "$endpoints_json" \
  --argjson now "$(date +%s)" '.data | access_map($u; $eps; $now)' "$CACHE_FILE")

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
           --argjson a "$access_json" --argjson we "$WITH_ENDPOINTS" '
      ($sizes) as $s
      | ($eps) as $e
      | [$ids[] as $id
         | .data[] | select(.id == $id)
         | catalog_with_units
         | . + {size: ($s[$id] | with_units(size_units))}
         | if $we == 1 then . + {endpoints: (($e[$id] // null_metrics) | with_units(endpoint_units))} else . end
         | . + {access: ($a[$id] | access_with_units)}
        ]
    ' "$CACHE_FILE"
    ;;
  sizes)
    # Callers read ctx/total/active/tokens by name; units and access are added
    # keys. zed.sh passes this map to python as one argv string, capped at
    # 128 KB: hence compact output, and access only on :free entries.
    run_jq -n -c --argjson s "$sizes_json" --argjson a "$access_json" '
      $s | with_entries(
        .value |= with_units(size_units)
        | if .key | endswith(":free") then .value += {access: ($a[.key] | access_with_units)} else . end)
    ' /dev/null
    ;;
  table)
    # Each column holds one fixed unit, named in the header, so cells are bare numbers
    if [[ $WITH_ENDPOINTS -eq 1 ]]; then
      run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson eps "$endpoints_json" \
                --argjson a "$access_json" '
        ($sizes) as $s
        | ($eps) as $e
        | ["Model ID", "Context (Ki tokens)", "Params (B)", "Active (B)", "Latency (ms)",
           "Throughput (tokens/s)", "Uptime (%)", "Providers (up/total)",
           "Expires (YYYY-MM-DD)", "Left (days)", "Access"] as $h
        | $h,
          ([$h[] | "-" * ([length, 10] | max)] | .[0] = "-" * 40),
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
        | ["Model ID", "Context (Ki tokens)", "Params (B)", "Active (B)", "Training (T tokens)",
           "Expires (YYYY-MM-DD)", "Left (days)", "Access"] as $h
        | $h,
          ([$h[] | "-" * ([length, 10] | max)] | .[0] = "-" * 40),
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