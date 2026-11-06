#!/usr/bin/env bash
# Синхронизирует бесплатные модели с claude-code-router. Единственный источник
# model data — соседние get-free-models-<platform>.sh команды.
set -Eeuo pipefail
umask 077

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: refresh-free-models-claude-code-router.sh [options]

Options:
  --platforms LIST  Comma-separated platforms. Default: every executable
                    get-free-models-*.sh next to this command.
  --dry-run         Do not save the CCR config and do not restart the service.
  -h, --help        Show this help.

Environment:
  CCR_URL, CCR_COMPOSE_SERVICE, CCR_PROJECT_DIR, CCR_BACKUP_DIR
  CCR_DRY_RUN=1, CCR_SKIP_POOL=1, CCR_POOL_ALLOW_DUPLICATES=1
  CCR_POOL_ENV_PREFIX_<PLATFORM>, CCR_POOL_LIMITS_<PLATFORM>
EOF
}

PLATFORM_LIST=""
DRY_RUN="${CCR_DRY_RUN:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platforms)
      [[ $# -ge 2 ]] || die "--platforms требует список"
      PLATFORM_LIST="$2"
      shift 2
      ;;
    --platforms=*) PLATFORM_LIST="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный параметр: $1" ;;
  esac
done

CCR_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_SCRIPT_DIR="$(cd "$(dirname "$CCR_SELF")" && pwd)"
SCRIPT_DIR="${CCR_FREE_MODELS_SCRIPT_DIR:-$DEFAULT_SCRIPT_DIR}"
PROJECT_DIR="${CCR_PROJECT_DIR:-$(cd "$DEFAULT_SCRIPT_DIR/.." && pwd)}"
CCR_URL="${CCR_URL:-http://127.0.0.1:3458}"
COMPOSE_SERVICE="${CCR_COMPOSE_SERVICE:-ccr}"
BACKUP_DIR="${CCR_BACKUP_DIR:-$PROJECT_DIR/.ccr-config-backups}"
SKIP_POOL="${CCR_SKIP_POOL:-0}"
ALLOW_DUP="${CCR_POOL_ALLOW_DUPLICATES:-0}"
LOCAL_CONFIG_INPUT="${CCR_CONFIG_INPUT:-}"
LOCAL_CONFIG_OUTPUT="${CCR_CONFIG_OUTPUT:-}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ccr-free-model-refresh.XXXXXX")"
cleanup() {
  find "$TMP" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

platform_metadata() {
  case "$1" in
    openrouter)
      jq -nc '{platform:"openrouter",upper:"OPENROUTER",name:"OpenRouter",host:"openrouter.ai",base_url:"https://openrouter.ai/api/v1",key_prefix:"OPENROUTER_API_KEY",limits:{rpm:20,rpd:50}}' ;;
    orcarouter)
      jq -nc '{platform:"orcarouter",upper:"ORCAROUTER",name:"OrcaRouter",host:"orcarouter.ai",base_url:"https://api.orcarouter.ai/v1",key_prefix:"ORCAROUTER_API_KEY",limits:{}}' ;;
    teamorouter)
      jq -nc '{platform:"teamorouter",upper:"TEAMOROUTER",name:"TeamoRouter",host:"teamorouter.com",base_url:"https://api.teamorouter.com/v1",key_prefix:"TEAMOROUTER_API_KEY",limits:{rpd:50}}' ;;
    kilo)
      jq -nc '{platform:"kilo",upper:"KILO",name:"Kilo Gateway",host:"kilo.ai",base_url:"https://ai-gateway.kilo.ai/api/v1",key_prefix:"KILO_API_KEY",limits:{}}' ;;
    *) return 1 ;;
  esac
}

discover_platforms() {
  local path name
  shopt -s nullglob
  for path in "$SCRIPT_DIR"/get-free-models-*.sh; do
    [[ -x "$path" ]] || continue
    name="${path##*/get-free-models-}"
    printf '%s\n' "${name%.sh}"
  done
  shopt -u nullglob
}

declare -a PLATFORMS=()
declare -A PLATFORM_SEEN=()
if [[ -z "$PLATFORM_LIST" ]]; then
  mapfile -t requested_platforms < <(discover_platforms | LC_ALL=C sort)
else
  PLATFORM_LIST="$(printf '%s' "$PLATFORM_LIST" | tr -d '[:space:]')"
  IFS=',' read -r -a requested_platforms <<< "$PLATFORM_LIST"
fi
for platform in "${requested_platforms[@]-}"; do
  [[ -n "$platform" ]] || die "список платформ содержит пустое имя"
  [[ "$platform" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "некорректное имя платформы: $platform"
  [[ -z "${PLATFORM_SEEN[$platform]-}" ]] || continue
  tool="$SCRIPT_DIR/get-free-models-$platform.sh"
  [[ -x "$tool" ]] || die "не найдена исполняемая discovery-команда: $tool"
  platform_metadata "$platform" >/dev/null || die "для платформы '$platform' нет CCR metadata"
  PLATFORM_SEEN[$platform]=1
  PLATFORMS+=("$platform")
done
(( ${#PLATFORMS[@]} > 0 )) || die "не найдено ни одной get-free-models-*.sh команды"

for cmd in jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "не найдена команда: $cmd"
done
if [[ -z "$LOCAL_CONFIG_INPUT" ]]; then
  command -v docker >/dev/null 2>&1 || die "не найдена команда: docker"
  [[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "нет docker-compose.yml в $PROJECT_DIR"
fi

wait_for_ccr() {
  local tries="${1:-60}" i
  for ((i = 1; i <= tries; i++)); do
    curl -fsS -o /dev/null --max-time 3 "$CCR_URL/" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

TOKEN=""
ccr_rpc() {
  local method="$1" params_file="${2:-}" body="$TMP/rpc-request.json"
  if [[ -n "$params_file" ]]; then
    jq -nc --arg method "$method" --slurpfile params "$params_file" '{method:$method,args:[$params[0]]}' > "$body"
  else
    jq -nc --arg method "$method" '{method:$method,args:[]}' > "$body"
  fi
  curl -fsS --max-time 60 -X POST "$CCR_URL/api/ccr/rpc" \
    -H "x-ccr-web-auth: $TOKEN" -H 'content-type: application/json' --data-binary @"$body"
}

if [[ -n "$LOCAL_CONFIG_INPUT" ]]; then
  [[ -f "$LOCAL_CONFIG_INPUT" ]] || die "не найден CCR_CONFIG_INPUT: $LOCAL_CONFIG_INPUT"
  cp "$LOCAL_CONFIG_INPUT" "$TMP/config.json"
else
  cd "$PROJECT_DIR"
  service_state="$(docker compose ps --format '{{.State}}' "$COMPOSE_SERVICE" 2>/dev/null || true)"
  if [[ "$service_state" != "running" ]]; then
    info "Сервис $COMPOSE_SERVICE не запущен — поднимаю один раз"
    docker compose up -d "$COMPOSE_SERVICE"
  fi
  wait_for_ccr || die "$CCR_URL не отвечает"
  location="$(curl -fsS -i --max-time 5 "$CCR_URL/" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')"
  TOKEN="$(printf '%s' "$location" | sed -n 's/.*ccr_web_token=\([^&]*\).*/\1/p')"
  [[ -n "$TOKEN" ]] || die "не удалось получить web-токен из $CCR_URL/"
  ccr_rpc getConfig > "$TMP/rpc-config.json" || die "getConfig не выполнился"
  jq -e '.value' "$TMP/rpc-config.json" > "$TMP/config.json" || die "getConfig вернул ответ без value"
fi
jq -e 'type == "object" and (.Providers | type) == "array"' "$TMP/config.json" >/dev/null \
  || die "исходный конфиг не содержит массив Providers"

printf '%s\n' "${PLATFORMS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))' > "$TMP/platforms.json"
info "Платформы: $(jq -r 'join(", ")' "$TMP/platforms.json")"

collect_credentials() {
  local platform="$1" metadata_file="$2" output_file="$3"
  local upper key_prefix prefix_override limits_override limits managed_prefix key_count
  local -a key_names=()
  upper="$(jq -r '.upper' "$metadata_file")"
  key_prefix="$(jq -r '.key_prefix' "$metadata_file")"
  prefix_override="CCR_POOL_ENV_PREFIX_${upper}"
  limits_override="CCR_POOL_LIMITS_${upper}"
  key_prefix="${!prefix_override:-$key_prefix}"
  limits="${!limits_override:-$(jq -c '.limits' "$metadata_file")}"
  jq -e 'type == "object"' <<< "$limits" >/dev/null 2>&1 || die "$limits_override должен быть JSON-объектом"
  managed_prefix="env-free-models-${platform}-"
  if [[ "$SKIP_POOL" == "1" ]]; then
    echo '[]' > "$output_file"
    return 0
  fi
  mapfile -t key_names < <(compgen -v | grep -E "^${key_prefix}([A-Za-z0-9_]*)$" | LC_ALL=C sort -V || true)
  if (( ${#key_names[@]} == 0 )); then
    warn "$platform: нет переменных $key_prefix* — credentials сохраняются"
    echo '[]' > "$output_file"
    return 0
  fi
  printf '%s\n' "${key_names[@]}" | jq -R -s 'split("\n") | map(select(length > 0))' > "$TMP/key-names-$platform.json"
  jq --arg prefix "$managed_prefix" --arg allow_dup "$ALLOW_DUP" --argjson limits "$limits" '
    [ .[] | {name:.,secret:($ENV[.] // "" | sub("^\\s+"; "") | sub("\\s+$"; "")),
               id:($prefix + (ascii_downcase | gsub("[^a-z0-9]+"; "-")))} ]
    | map(select(.secret != ""))
    | (if $allow_dup == "1" then .
       else reduce .[] as $row ([]; if any(.[]; .secret == $row.secret) then . else . + [$row] end) end)
    | map({api_key:.secret,enabled:true,id,limits:$limits,name,priority:1,weight:1})
  ' "$TMP/key-names-$platform.json" > "$output_file"
  key_count="$(jq 'length' "$output_file")"
  if (( key_count == 0 )); then
    warn "$platform: найденные переменные пусты — credentials сохраняются"
  else
    info "$platform: ключей из окружения $key_count (${key_names[*]})"
  fi
}

cp "$TMP/config.json" "$TMP/config.next.json"
for platform in "${PLATFORMS[@]}"; do
  tool="$SCRIPT_DIR/get-free-models-$platform.sh"
  metadata="$TMP/meta-$platform.json"
  ids="$TMP/ids-$platform.json"
  sizes="$TMP/sizes-$platform.json"
  credentials="$TMP/credentials-$platform.json"
  platform_metadata "$platform" > "$metadata"
  printf '\n'
  info "$platform: каталог через ${tool##*/}"
  "$tool" --format table
  "$tool" --format json-ids --sort total,active,ctx > "$ids"
  "$tool" --format sizes > "$sizes" 2> "$TMP/sizes-$platform.stderr"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' "$ids" >/dev/null \
    || die "$platform: json-ids не содержит непустой массив"
  jq -e 'type == "object"' "$sizes" >/dev/null || die "$platform: sizes не является JSON-объектом"
  collect_credentials "$platform" "$metadata" "$credentials"
  jq --slurpfile meta "$metadata" --slurpfile ids "$ids" --slurpfile pool "$credentials" '
    ($meta[0]) as $m | ($ids[0]) as $models | ($pool[0]) as $credentials
    | ("env-free-models-" + $m.platform + "-") as $managed_prefix
    | def matches($provider):
        (((($provider.api_base_url // "") + " " + (($provider.capabilities // []) | map(.baseUrl // "") | join(" "))) | contains($m.host)));
    def capabilities:
        [{baseUrl:$m.base_url,endpoint:($m.base_url + "/chat/completions"),source:"configured",type:"openai_chat_completions"}];
    def reconcile($provider):
        $provider
        | .api_base_url = $m.base_url
        | .id = (.id // $m.platform)
        | .name = (.name // $m.name)
        | .type = (.type // "openai_chat_completions")
        | .capabilities = (if ((.capabilities // []) | length) > 0 then .capabilities else capabilities end)
        | .models = $models
        | if ($credentials | length) > 0 then
            .credentials = (((.credentials // []) | map(select(
              ((.id // "") | startswith($managed_prefix) | not)
              and (if $m.platform == "openrouter" then ((.id // "") | startswith("env-openrouter-") | not) else true end)
            ))) + $credentials)
            | .api_key = $credentials[0].api_key
          else . end;
    (.Providers | map(matches(.)) | index(true)) as $index
    | if $index == null then
        .Providers += [reconcile({api_base_url:$m.base_url,id:$m.platform,models:[],name:$m.name,type:"openai_chat_completions"})]
      else .Providers[$index] = reconcile(.Providers[$index]) end
  ' "$TMP/config.next.json" > "$TMP/config.updated.json"
  mv "$TMP/config.updated.json" "$TMP/config.next.json"
  info "$platform: моделей $(jq 'length' "$ids")"
done

jq -e 'type == "object" and (.Providers | type) == "array" and all(.Providers[]; (.models | type) == "array")' \
  "$TMP/config.next.json" >/dev/null || die "после агрегации получился некорректный конфиг"
for platform in "${PLATFORMS[@]}"; do
  host="$(jq -r '.host' "$TMP/meta-$platform.json")"
  expected="$(jq -c . "$TMP/ids-$platform.json")"
  actual="$(jq -c --arg host "$host" '[.Providers[] | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" "))) | contains($host))) | .models][0]' "$TMP/config.next.json")"
  [[ "$actual" == "$expected" ]] || die "$platform: итоговый список моделей не совпал с discovery-выводом"
done

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
cp "$TMP/config.json" "$backup"
info "Бэкап конфига: $backup"
if [[ -n "$LOCAL_CONFIG_INPUT" ]]; then
  [[ -n "$LOCAL_CONFIG_OUTPUT" ]] || die "в local config mode требуется CCR_CONFIG_OUTPUT"
  cp "$TMP/config.next.json" "$LOCAL_CONFIG_OUTPUT"
  info "Локальный результат: $LOCAL_CONFIG_OUTPUT"
  exit 0
fi
if [[ "$DRY_RUN" == "1" ]]; then
  info "Dry-run: конфиг не сохранён, сервис не перезапущен"
  exit 0
fi

info "Сохраняю агрегированный конфиг одним RPC"
ccr_rpc saveConfig "$TMP/config.next.json" > "$TMP/rpc-save.json" || die "saveConfig не выполнился (бэкап: $backup)"
jq -e '.ok == true' "$TMP/rpc-save.json" >/dev/null || die "saveConfig вернул ошибку (бэкап: $backup)"
ccr_rpc getConfig > "$TMP/rpc-verify.json" || die "проверочный getConfig не выполнился"
jq -e '.value' "$TMP/rpc-verify.json" > "$TMP/config.saved.json" || die "проверочный getConfig не вернул value"
for platform in "${PLATFORMS[@]}"; do
  host="$(jq -r '.host' "$TMP/meta-$platform.json")"
  expected="$(jq -c . "$TMP/ids-$platform.json")"
  actual="$(jq -c --arg host "$host" '[.Providers[] | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" "))) | contains($host))) | .models][0]' "$TMP/config.saved.json")"
  [[ "$actual" == "$expected" ]] || die "$platform: сохранённый список моделей не прошёл проверку"
done
info "Перезапускаю $COMPOSE_SERVICE один раз"
docker compose restart "$COMPOSE_SERVICE"
wait_for_ccr || die "после restart $CCR_URL не отвечает (бэкап: $backup)"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' "$COMPOSE_SERVICE"
printf '\n'
info "Готово. Веб-интерфейс: $CCR_URL/"
