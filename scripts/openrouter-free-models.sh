#!/usr/bin/env bash
#
# Standalone tool: fetch OpenRouter catalog, extract :free models,
# parse their sizes (params/active/ctx) from description + id,
# optionally fetch per-provider endpoint metrics (latency, throughput, uptime),
# sort by size (total params desc, active params desc, ctx desc),
# and output in requested format.
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
#
# The script is self-contained and has no external dependencies beyond curl + jq.
# It does NOT require docker, docker-compose, or any CCR configuration.

set -Eeuo pipefail

# --- Configuration -----------------------------------------------------------

CATALOG_URL="${OPENROUTER_CATALOG_URL:-https://openrouter.ai/api/v1/models}"
PAGE_BASE_URL="${OPENROUTER_PAGE_BASE_URL:-https://openrouter.ai}"
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

# Empty metrics record — used when a model page yields nothing parseable
def null_metrics:
  { latency_ms: null, throughput_tps: null, uptime_pct: null, endpoint_count: 0 };
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

# Emit exactly one {model_id: metrics} object per model.
fetch_metrics_for_model() {
  local model_id="$1"
  local page_file metrics
  page_file=$(fetch_model_page "$model_id")
  metrics=$(parse_page_metrics "$page_file")
  jq -c -n --arg mid "$model_id" --argjson m "$metrics" '{($mid): $m}'
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

# --- Output ------------------------------------------------------------------

case "$FORMAT" in
  ids)
    jq -r '.[]' <<< "$free_ids"
    ;;
  json-ids)
    printf '%s\n' "$free_ids"
    ;;
  json)
    # Full model objects for the free models, optionally with endpoint metrics
    if [[ $WITH_ENDPOINTS -eq 1 ]]; then
      run_jq --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson eps "$endpoints_json" '
        ($sizes) as $s
        | ($eps) as $e
        | [$ids[] as $id
           | .data[] | select(.id == $id)
           | . + {size: $s[$id]}
           | . + {endpoints: ($e[$id] // null_metrics)}
          ]
      ' "$CACHE_FILE"
    else
      run_jq --argjson ids "$free_ids" --argjson sizes "$sizes_json" '
        ($sizes) as $s
        | [$ids[] as $id | .data[] | select(.id == $id) | . + {size: $s[$id]}]
      ' "$CACHE_FILE"
    fi
    ;;
  sizes)
    printf '%s\n' "$sizes_json"
    ;;
  table)
    # Pretty table with column
    if [[ $WITH_ENDPOINTS -eq 1 ]]; then
      run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" --argjson eps "$endpoints_json" '
        ($sizes) as $s
        | ($eps) as $e
        | ["ID модели", "Контекст (к)", "Параметры", "Активных", "Latency", "Throughput", "Uptime"],
          (["-"*40, "-"*12, "-"*10, "-"*10, "-"*10, "-"*12, "-"*8]),
          ($ids[] as $id
           | ($s[$id] // {}) as $m
           | ($e[$id] // null_metrics) as $ep
           | [
               $id,
               (($m.ctx // 0) / 1024 | round | unit("k")),
               ($m.total  | human),
               ($m.active | human),
               (if $ep.latency_ms == null then "—" else ($ep.latency_ms | round | unit("ms")) end),
               (if $ep.throughput_tps == null then "—" else ($ep.throughput_tps | unit("t/s")) end),
               (if $ep.uptime_pct == null then "—" else ($ep.uptime_pct | unit("%")) end)
             ])
        | @tsv
      ' "$CACHE_FILE" | render_table 2,3,4,5,6,7
    else
      run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" '
        ($sizes) as $s
        | ["ID модели", "Контекст (к)", "Параметры", "Активных", "Обучение"],
          (["-"*40, "-"*12, "-"*10, "-"*10, "-"*10]),
          ($ids[] as $id | ($s[$id] // {}) as $m | [
            $id,
            (($m.ctx // 0) / 1024 | round | unit("k")),
            ($m.total  | human),
            ($m.active | human),
            ($m.tokens | human)
          ])
        | @tsv
      ' "$CACHE_FILE" | render_table 2,3,4,5
    fi
    ;;
esac

exit 0