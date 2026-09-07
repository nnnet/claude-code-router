#!/usr/bin/env bash
#
# Standalone tool: fetch OpenRouter catalog, extract :free models,
# parse their sizes (params/active/ctx) from description + id,
# sort by size (total params desc, active params desc, ctx desc),
# and output in requested format.
#
# Usage:
#   openrouter-free-models.sh [--format table|json|ids] [--limit N] [--sort total,active,ctx] [--cache-dir DIR] [--max-age SECONDS] [--refresh] [--offline]
#
# Exit codes: 0 = ok, 1 = bad args, 2 = no data (empty catalog or no :free models)
#
# Dependencies: curl, jq, column (for table format)
#
# Environment:
#   OPENROUTER_CATALOG_URL   override catalog endpoint (default https://openrouter.ai/api/v1/models)
#   OPENROUTER_CACHE_DIR     cache directory (default $XDG_CACHE_HOME/openrouter or ~/.cache/openrouter)
#   OPENROUTER_CACHE_MAX_AGE cache TTL in seconds (default 86400 = 24h)
#   OPENROUTER_OFFLINE=1     use only cached data, fail if stale/missing
#   OPENROUTER_REFRESH=1     force cache refresh
#
# The script is self-contained and has no external dependencies beyond curl + jq.
# It does NOT require docker, docker-compose, or any CCR configuration.

set -Eeuo pipefail

# --- Configuration -----------------------------------------------------------

CATALOG_URL="${OPENROUTER_CATALOG_URL:-https://openrouter.ai/api/v1/models}"
CACHE_DIR="${OPENROUTER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openrouter}"
MAX_AGE="${OPENROUTER_CACHE_MAX_AGE:-86400}"
OFFLINE="${OPENROUTER_OFFLINE:-0}"
REFRESH="${OPENROUTER_REFRESH:-0}"
FORMAT="table"
LIMIT=0
SORT_SPEC="total,active,ctx"  # default: total desc, active desc, ctx desc

# --- Helpers -----------------------------------------------------------------

die() {
  printf 'openrouter-free-models: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF' >&2
Usage: openrouter-free-models.sh [options]

Options:
  --format FORMAT     Output format: table (default), json, ids, json-ids, sizes
  --limit N           Limit output to first N models
  --sort SPEC         Sort specification: comma-separated keys from {total,active,ctx,id}
                      Prefix with + for ascending, - for descending (default).
                      Numeric keys default to descending, id defaults to ascending.
                      Example: --sort +ctx,-total,active
  --cache-dir DIR     Cache directory (default: $XDG_CACHE_HOME/openrouter)
  --max-age SECONDS   Cache TTL in seconds (default: 86400)
  --refresh           Force cache refresh
  --offline           Use only cached data, fail if unavailable
  -h, --help          Show this help

Environment variables:
  OPENROUTER_CATALOG_URL   Override catalog endpoint
  OPENROUTER_CACHE_DIR     Cache directory
  OPENROUTER_CACHE_MAX_AGE Cache TTL in seconds
  OPENROUTER_OFFLINE=1     Offline mode
  OPENROUTER_REFRESH=1     Force refresh

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

# --- Cache management --------------------------------------------------------

mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/models.json"
CACHE_META="$CACHE_DIR/models.meta"

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
  # Validate it's a proper catalog
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
    # Fall back to stale cache if available
    [[ -f "$CACHE_FILE" ]] || die "Failed to fetch catalog and no cache available" 2
    printf 'warn: using stale cache (fetch failed)\n' >&2
  fi
elif [[ ! -f "$CACHE_FILE" ]]; then
  if [[ "$OFFLINE" == "1" ]]; then
    die "Offline mode: no cache available" 2
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

# Human readable: 1.2B, 550M, etc.
def human: if . == null then "—"
  elif . >= 1000000000000 then ((. / 100000000000 | round) / 10 | tostring) + "T"
  elif . >= 1000000000    then ((. / 100000000    | round) / 10 | tostring) + "B"
  elif . >= 1000000       then ((. / 100000       | round) / 10 | tostring) + "M"
  else tostring end;
JQEOF

# Helper to run jq with library + program from temp file
# Usage: run_jq [jq_options...] "program" "input_file"
run_jq() {
  local jq_opts=()
  local program=""
  local input_file=""

  # Parse: options come first, then program, then input_file
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

# --- Build dynamic sort key from --sort spec ---------------------------------

# Parse SORT_SPEC into jq sort key array
# Format: [{"field": "total", "dir": -1}, {"field": "active", "dir": 1}, ...]
# dir: -1 = descending (default for numeric), 1 = ascending
# id defaults to ascending (1), numeric defaults to descending (-1)
build_sort_keys() {
  local spec="$1"
  local keys_json="["
  local first=1
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    local field="$part"
    local dir=-1  # default descending for numeric
    case "$part" in
      +*) field="${part#+}"; dir=1 ;;
      -*) field="${part#-}"; dir=-1 ;;
    esac
    case "$field" in
      total|active|ctx) ;;
      id) dir=1 ;;  # id defaults to ascending
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

# --- Output ------------------------------------------------------------------

case "$FORMAT" in
  ids)
    jq -r '.[]' <<< "$free_ids"
    ;;
  json-ids)
    printf '%s\n' "$free_ids"
    ;;
  json)
    # Full model objects for the free models
    run_jq --argjson ids "$free_ids" --argjson sizes "$sizes_json" '
      ($sizes) as $s
      | [$ids[] as $id | .data[] | select(.id == $id) | . + {size: $s[$id]}]
    ' "$CACHE_FILE"
    ;;
  sizes)
    # Size map for all models in catalog (for sorting combined lists)
    printf '%s\n' "$sizes_json"
    ;;
  table)
    # Pretty table with column
    run_jq -r --argjson ids "$free_ids" --argjson sizes "$sizes_json" '
      ($sizes) as $s
      | ["ID модели", "Контекст (к)", "Параметры", "Активных", "Обучение"],
        (["-"*40, "-"*12, "-"*10, "-"*10, "-"*10]),
        ($ids[] as $id | ($s[$id] // {}) as $m | [
          $id,
          (($m.ctx // 0) / 1024 | round | tostring + "k"),
          ($m.total  | human),
          ($m.active | human),
          ($m.tokens | human)
        ])
      | @tsv
    ' "$CACHE_FILE" | column -t -s $'\t'
    ;;
esac

exit 0