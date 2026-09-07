#!/usr/bin/env bash
#
# Обновляет список бесплатных моделей OpenRouter в claude-code-router,
# пересобирает пул ключей провайдера из окружения и перезапускает контейнер.
#
# Порядок работы:
#   1. запрос каталога OpenRouter и вывод таблицы :free моделей;
#   2. сбор ключей из переменных окружения OPENROUTER_API_KEY* (если их нет —
#      пул не трогается);
#   3. бэкап текущего конфига CCR;
#   4. у OpenRouter-провайдера все ":free" модели заменяются свежим списком
#      (модели без ":free" сохраняются как есть — например upstage/solar-pro4),
#      весь список сортируется по убыванию контекста, а credentials
#      пересобираются из окружения;
#   5. конфиг сохраняется через management RPC;
#   6. docker compose restart.
#
# Конфиг живёт в docker-томе, поэтому правится через RPC работающего
# контейнера, а не файлом на диске. Если контейнер не поднят — скрипт
# поднимет его сам.
#
# Про пул ключей. CCR ротирует ключи внутри провайдера сортировкой
# (packages/core/src/gateway/upstream/executor.ts):
#     priority ASC -> utilization ASC -> weight DESC -> порядок в массиве
# utilization считается ТОЛЬКО из limits ключа. Без limits он всегда 0,
# сортировка вырождается в порядок массива, и весь трафик идёт в первый ключ,
# пока тот не отдаст 401/403/429/5xx (это failover, а не балансировка).
# Поэтому всем ключам ставятся ОДИНАКОВЫЕ priority/weight/limits — тогда
# сравнение по utilization отдаёт запрос наименее использованному ключу.
# Лимиты не блокируют трафик: когда все ключи исчерпаны, запрос всё равно
# уходит, а цепочка помечается заголовком x-ccr-provider-credential-saturated.
#
# Чего пул НЕ чинит: у OpenRouter лимиты :free моделей считаются на аккаунт
# целиком ("we govern capacity globally"), поэтому несколько ключей ОДНОГО
# аккаунта дневной кап не поднимут. Пул полезен для ключей разных аккаунтов,
# BYOK-ключей и как failover. Пер-модельные капы (в 429 видно
# limit_source=openrouter_shared_capacity) ключами не обходятся вообще.
#
# Значения ключей нигде не печатаются: в выводе только имена переменных.
#
# Переменные окружения:
#   OPENROUTER_API_KEY*  ключи пула (любой суффикс: _2, _WORK, _BYOK, ...)
#   CCR_POOL_ENV_PREFIX  префикс поиска ключей      (по умолчанию OPENROUTER_API_KEY)
#   CCR_POOL_LIMITS      limits JSON каждому ключу  (по умолчанию {"rpm":20,"rpd":50})
#   CCR_SKIP_POOL=1      не трогать credentials вообще
#   CCR_POOL_ALLOW_DUPLICATES=1  не схлопывать переменные с одинаковым значением
#                        (по умолчанию копии одного ключа сводятся в один
#                        credential — запаса лимитов они всё равно не дают)
#   CCR_URL              адрес management-сервера   (по умолчанию http://127.0.0.1:3458)
#   CCR_COMPOSE_SERVICE  имя сервиса в compose      (по умолчанию ccr)
#   CCR_BACKUP_DIR       куда класть бэкапы конфига (по умолчанию <проект>/.ccr-config-backups)
#   CCR_DRY_RUN=1        показать таблицу и план изменений, ничего не сохранять
#
set -Eeuo pipefail
umask 077

PROJECT_DIR="${CCR_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CCR_URL="${CCR_URL:-http://127.0.0.1:3458}"
COMPOSE_SERVICE="${CCR_COMPOSE_SERVICE:-ccr}"
BACKUP_DIR="${CCR_BACKUP_DIR:-$PROJECT_DIR/.ccr-config-backups}"
DRY_RUN="${CCR_DRY_RUN:-0}"
SKIP_POOL="${CCR_SKIP_POOL:-0}"
ALLOW_DUP="${CCR_POOL_ALLOW_DUPLICATES:-0}"
ENV_PREFIX="${CCR_POOL_ENV_PREFIX:-OPENROUTER_API_KEY}"
# Дефолт под бесплатный тариф OpenRouter: 20 запросов/мин, 50 запросов/сутки.
# С пополнением от $10 lifetime суточный лимит аккаунта — 1000.
POOL_LIMITS="${CCR_POOL_LIMITS:-}"
[[ -n "$POOL_LIMITS" ]] || POOL_LIMITS='{"rpm":20,"rpd":50}'

# Провайдер опознаётся по адресу, а не по имени: имя пользователь может
# переименовать в UI, baseUrl — нет.
OPENROUTER_MATCH='openrouter\.ai'
# Префикс id строк пула, которыми владеет скрипт. Всё остальное в credentials —
# добавлено руками, его не трогаем.
MANAGED_PREFIX='env-'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Предполётные проверки -------------------------------------------------

for cmd in curl jq docker column; do
  command -v "$cmd" >/dev/null 2>&1 || die "не найдена команда: $cmd"
done
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] \
  || die "нет docker-compose.yml в $PROJECT_DIR (задай CCR_PROJECT_DIR)"
cd "$PROJECT_DIR"

jq -e 'type == "object" and length > 0' <<< "$POOL_LIMITS" >/dev/null 2>&1 \
  || die "CCR_POOL_LIMITS должен быть непустым JSON-объектом, например '{\"rpm\":20,\"rpd\":50}'"
# Ключи limits, которые понимает конфиг (parseApiKeyLimits в packages/core/src/config/config.ts).
unknown_limits="$(jq -r '
  keys - ["ipd","iph","ipm","maxRequests","maxTokens","quotaWindowMs","rpd","rph","rpm","tpd","tph","tpm","windowMs"]
  | join(", ")' <<< "$POOL_LIMITS")"
[[ -z "$unknown_limits" ]] || die "CCR_POOL_LIMITS: неизвестные поля лимитов: $unknown_limits"

# --- Контейнер должен быть поднят: конфиг правится через его RPC -----------

wait_for_ccr() {
  local tries=${1:-60} i
  for ((i = 1; i <= tries; i++)); do
    # / отвечает 302 с токеном веб-морды — этого достаточно как признака жизни.
    curl -fsS -o /dev/null --max-time 3 "$CCR_URL/" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

service_state="$(docker compose ps --format '{{.State}}' "$COMPOSE_SERVICE" 2>/dev/null || true)"
if [[ "$service_state" != "running" ]]; then
  info "Сервис $COMPOSE_SERVICE не запущен — поднимаю"
  docker compose up -d "$COMPOSE_SERVICE"
fi
wait_for_ccr || die "$CCR_URL не отвечает — management-сервер недоступен"

# Токен веб-морды генерируется заново при каждом старте контейнера
# (docker/entrypoint.sh) и отдаётся в Location редиректа с /.
TOKEN="$(
  curl -fsS -i --max-time 5 "$CCR_URL/" 2>/dev/null \
    | grep -i '^location:' \
    | sed -n 's/.*ccr_web_token=\([A-Za-z0-9_-]*\).*/\1/p' \
    | tr -d '\r\n'
)"
[[ -n "$TOKEN" ]] || die "не удалось получить web-токен из редиректа $CCR_URL/"

ccr_rpc() {
  # $1 — метод, $2 — файл с конфигурацией (по умолчанию пустой массив)
  local method="$1" params_file="${2:-}" body="$TMP/rpc-req.json"
  if [[ -n "$params_file" ]]; then
    # Заменяем params на args. $p[0] вытаскивает чистый JSON-объект из slurp-массива,
    # а конструкция [$p[0]] оборачивает его в массив аргументов верхнего уровня.
    jq -nc --arg m "$method" --slurpfile p "$params_file" '{method: $m, args: [$p[0]]}' > "$body"
  else
    jq -nc --arg m "$method" '{method: $m, args: []}' > "$body"
  fi
  curl -fsS --max-time 60 -X POST "$CCR_URL/api/ccr/rpc" \
    -H "x-ccr-web-auth: $TOKEN" \
    -H 'content-type: application/json' \
    --data-binary @"$body"
}

# --- 1. Каталог OpenRouter -------------------------------------------------

info "Запрашиваю каталог моделей OpenRouter"
curl -fsS --max-time 30 https://openrouter.ai/api/v1/models -o "$TMP/models.json" \
  || die "не удалось получить каталог OpenRouter"

jq -r '
  [ .data[] | select(.id | endswith(":free")) ] |
  sort_by(-.context_length) |
  ["ID модели", "Контекст (к)", "Размер (B)"],
  (["-"*40, "-"*12, "-"*10]),
  (.[] | [
    .id,
    (.context_length / 1024 | round | tostring + "k"),
    (if .architecture.parameters != null then ((.architecture.parameters / 1000000000 | round | tostring) + "B") else "N/A" end)
  ]) | @tsv' "$TMP/models.json" | column -t -s $'\t'

# Порядок из таблицы сохраняется в конфиге: сначала самый большой контекст.
jq '[ .data[] | select(.id | endswith(":free")) ] | sort_by(-.context_length) | map(.id)' \
  "$TMP/models.json" > "$TMP/free.json"

# Карта "id модели -> контекст" по всему каталогу. Нужна, чтобы в общий порядок
# встали и платные модели, которые скрипт сохраняет как есть.
jq 'reduce .data[] as $m ({}; .[$m.id] = ($m.context_length // 0))' \
  "$TMP/models.json" > "$TMP/context.json"

free_count="$(jq 'length' "$TMP/free.json")"
# Пустой ответ означает сбой на стороне OpenRouter, а не «моделей больше нет».
# Затирать этим рабочий конфиг нельзя.
(( free_count > 0 )) || die "OpenRouter вернул ноль бесплатных моделей — конфиг не тронут"
printf '\n'
info "Бесплатных моделей в выдаче: $free_count"

# --- 2. Ключи из окружения --------------------------------------------------

# Пустой пул = credentials в конфиге остаются как есть.
echo '[]' > "$TMP/managed.json"

if [[ "$SKIP_POOL" == "1" ]]; then
  info "CCR_SKIP_POOL=1 — пул ключей не трогаю"
else
  # Собираем только ИМЕНА переменных; значения читает jq через $ENV, чтобы
  # секреты не попадали ни в argv (виден в ps), ни в вывод скрипта.
  mapfile -t key_names < <(compgen -v | grep -E "^${ENV_PREFIX}" | LC_ALL=C sort -V || true)

  if (( ${#key_names[@]} == 0 )); then
    warn "в окружении нет переменных с префиксом $ENV_PREFIX — пул ключей не трогаю"
  else
    printf '%s\n' "${key_names[@]}" > "$TMP/names.txt"
    jq -R -s -c 'split("\n") | map(select(length > 0))' "$TMP/names.txt" > "$TMP/names.json"

    # Пустые значения отбрасываются. Переменные с ОДИНАКОВЫМ значением по
    # умолчанию схлопываются в один credential: копии одного ключа делят общий
    # лимит, ротировать между ними нечего. CCR_POOL_ALLOW_DUPLICATES=1 оставляет
    # их отдельными записями — например чтобы посмотреть ротацию в UI.
    jq -c --argjson limits "$POOL_LIMITS" --arg prefix "$MANAGED_PREFIX" \
          --arg allow_dup "$ALLOW_DUP" '
      [ .[] | {
          name: .,
          secret: ($ENV[.] // "" | sub("^\\s+"; "") | sub("\\s+$"; "")),
          id: ($prefix + (ascii_downcase | gsub("[^a-z0-9]+"; "-")))
        } ] as $rows
      | ($rows | map(select(.secret != ""))) as $filled
      | ($filled
         | reduce .[] as $row ([]; if any(.[]; .secret == $row.secret) then . else . + [$row] end)
        ) as $unique
      | {
          empty: ($rows | map(select(.secret == "") | .name)),
          duplicates: (($filled | map(.name)) - ($unique | map(.name))),
          pool: ((if $allow_dup == "1" then $filled else $unique end)
                 | map({
                     api_key: .secret,
                     enabled: true,
                     id: .id,
                     limits: $limits,
                     name: .name,
                     priority: 1,
                     weight: 1
                   }))
        }
    ' "$TMP/names.json" > "$TMP/collected.json"
    jq -c '.pool' "$TMP/collected.json" > "$TMP/managed.json"

    # Отчёт о выброшенном: молчаливая потеря переменной выглядит как баг сбора.
    empty_names="$(jq -r '.empty | join(", ")' "$TMP/collected.json")"
    dup_names="$(jq -r '.duplicates | join(", ")' "$TMP/collected.json")"
    [[ -z "$empty_names" ]] || warn "пустые переменные пропущены: $empty_names"
    if [[ -n "$dup_names" ]]; then
      if [[ "$ALLOW_DUP" == "1" ]]; then
        warn "CCR_POOL_ALLOW_DUPLICATES=1 — копии уже добавленного ключа оставлены: $dup_names"
        warn "  запаса лимитов это не даёт: у копий одного ключа счётчик общий"
      else
        warn "значение совпало с ключом выше, в пул не попали: $dup_names"
        warn "  копии одного ключа делят общий лимит — нужен ключ ДРУГОГО аккаунта"
        warn "  оставить копии отдельными записями: CCR_POOL_ALLOW_DUPLICATES=1"
      fi
    fi

    managed_count="$(jq 'length' "$TMP/managed.json")"
    if (( managed_count == 0 )); then
      warn "все переменные $ENV_PREFIX* пустые — пул ключей не трогаю"
      echo '[]' > "$TMP/managed.json"
    else
      info "Ключей из окружения: $managed_count (переменных найдено ${#key_names[@]})"
      jq -r '.[] | "  • " + .name + "  (id: " + .id + ")"' "$TMP/managed.json"
      info "Лимиты каждому: $(jq -c . <<< "$POOL_LIMITS")  (priority 1, weight 1 — ротация по загрузке)"
      (( managed_count > 1 )) || warn "ключ всего один — ротировать нечего, пул сведётся к одиночному ключу"
    fi
  fi
fi
managed_count="$(jq 'length' "$TMP/managed.json")"
printf '\n'

# --- 3. Текущий конфиг + бэкап ---------------------------------------------

ccr_rpc getConfig > "$TMP/rpc-config.json" || die "getConfig не выполнился"
jq -e '.value' "$TMP/rpc-config.json" > "$TMP/config.json" \
  || die "management-сервер вернул ответ без конфига: $(head -c 400 "$TMP/rpc-config.json")"

matched="$(jq --arg re "$OPENROUTER_MATCH" '
  [ .Providers[]
    | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
  ] | length' "$TMP/config.json")"
(( matched > 0 )) || die "в конфиге нет провайдера с baseUrl на openrouter.ai"

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
cp "$TMP/config.json" "$backup"
info "Бэкап конфига: $backup"

# --- 4. Замена :free моделей и пересборка пула ------------------------------

jq --arg re "$OPENROUTER_MATCH" --arg prefix "$MANAGED_PREFIX" \
   --slurpfile free "$TMP/free.json" --slurpfile managed "$TMP/managed.json" \
   --slurpfile ctx "$TMP/context.json" '
  ($free[0]) as $fresh
  | ($managed[0]) as $pool
  | ($ctx[0]) as $context
  | .Providers |= map(
      if ((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
      then
        # Весь список — по убыванию контекста; при равном контексте по id, чтобы
        # порядок не плясал между запусками. Моделей, которых нет в каталоге
        # OpenRouter, контекст неизвестен — они уходят в конец.
        .models = ((((.models // []) | map(select(endswith(":free") | not))) + $fresh)
                   | sort_by([-($context[.] // -1), .]))
        # Пул пересобирается только из строк, которыми владеет скрипт (id "env-*");
        # добавленные руками credentials сохраняются.
        | (if ($pool | length) > 0
           then .credentials = (((.credentials // []) | map(select((.id // "") | startswith($prefix) | not))) + $pool)
           else . end)
      else . end
    )
' "$TMP/config.json" > "$TMP/config.new.json"

jq -e 'type == "object" and (.Providers | type) == "array"' "$TMP/config.new.json" >/dev/null \
  || die "после правки получился некорректный конфиг — сохранение отменено"

# Что именно изменится. Сортировка и сравнение — строго в LC_ALL=C: sort по
# локали и comm по байтам расходятся на ":" и "-" в id моделей, из-за чего одна
# и та же модель попадает разом в добавленные и удалённые.
jq -r --arg re "$OPENROUTER_MATCH" '
  [ .Providers[]
    | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
    | .models[] | select(endswith(":free")) ] | .[]' "$TMP/config.json" \
  | LC_ALL=C sort -u > "$TMP/old-free.txt"
jq -r '.[]' "$TMP/free.json" | LC_ALL=C sort -u > "$TMP/new-free.txt"

added="$(LC_ALL=C comm -13 "$TMP/old-free.txt" "$TMP/new-free.txt" || true)"
removed="$(LC_ALL=C comm -23 "$TMP/old-free.txt" "$TMP/new-free.txt" || true)"
[[ -n "$added"   ]] && { printf '\n\033[1;32mДобавляются:\033[0m\n'; sed 's/^/  + /' <<< "$added"; }
[[ -n "$removed" ]] && { printf '\n\033[1;31mУбираются (больше не бесплатны или сняты):\033[0m\n'; sed 's/^/  - /' <<< "$removed"; }
[[ -z "$added$removed" ]] && info "Список бесплатных моделей не изменился"
printf '\n'

count_pool() {
  jq --arg re "$OPENROUTER_MATCH" '
    [ .Providers[]
      | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
      | (.credentials // []) | length ] | add // 0' "$1"
}
info "Ключей в пуле OpenRouter: было $(count_pool "$TMP/config.json"), станет $(count_pool "$TMP/config.new.json")"

# Ручные строки без limits перетягивают на себя весь трафик: их utilization
# всегда 0, а сортировка идёт по возрастанию utilization.
kept_no_limits="$(jq -r --arg re "$OPENROUTER_MATCH" --arg prefix "$MANAGED_PREFIX" '
  [ .Providers[]
    | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
    | (.credentials // [])[]
    | select(((.id // "") | startswith($prefix)) | not)
    | select((.limits // {}) == {})
    | .name // .id // "без имени" ] | join(", ")' "$TMP/config.new.json")"
[[ -z "$kept_no_limits" ]] \
  || warn "в пуле есть ручные ключи без limits ($kept_no_limits) — их utilization всегда 0, ротация будет отдавать запросы им"

if [[ "$DRY_RUN" == "1" ]]; then
  info "CCR_DRY_RUN=1 — конфиг не сохранён, контейнер не перезапущен"
  exit 0
fi

# --- 5. Сохранение ----------------------------------------------------------

info "Сохраняю конфиг"
cp "$TMP/config.new.json" "$TMP/save-params.json"
ccr_rpc saveConfig "$TMP/save-params.json" > "$TMP/rpc-save.json" \
  || die "saveConfig не выполнился, конфиг остался прежним (бэкап: $backup)"
jq -e '.ok == true' "$TMP/rpc-save.json" >/dev/null \
  || die "saveConfig вернул ошибку: $(head -c 400 "$TMP/rpc-save.json") (бэкап: $backup)"

ccr_rpc getConfig > "$TMP/rpc-verify.json" || die "проверочный getConfig не выполнился (бэкап: $backup)"
jq -e '.value' "$TMP/rpc-verify.json" > "$TMP/config.saved.json" \
  || die "проверочный getConfig вернул ответ без конфига (бэкап: $backup)"

saved_count="$(jq --arg re "$OPENROUTER_MATCH" '
  [ .Providers[]
    | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
    | .models[] | select(endswith(":free")) ] | length' "$TMP/config.saved.json")"
(( saved_count == free_count )) \
  || die "сохранено $saved_count из $free_count моделей — проверь конфиг (бэкап: $backup)"
info "В конфиге $saved_count бесплатных моделей"

if (( managed_count > 0 )); then
  # Сверяем id, лимиты и непустоту ключей — сами значения ключей не читаем.
  saved_ok="$(jq --slurpfile managed "$TMP/managed.json" --arg re "$OPENROUTER_MATCH" --arg prefix "$MANAGED_PREFIX" '
    ($managed[0] | map(.id)) as $ids
    | ($managed[0][0].limits) as $limits
    | [ .Providers[]
        | select((((.api_base_url // "") + " " + ((.capabilities // []) | map(.baseUrl // "") | join(" ")))) | test($re))
        | (.credentials // [])
        | map(select((.id // "") | startswith($prefix)))
        | ((map(.id) == $ids)
           and all(.[]; ((.api_key // .apiKey // "") | length) > 0)
           and all(.[]; (.limits == $limits) and .enabled != false)) ]
      | all' "$TMP/config.saved.json")"
  [[ "$saved_ok" == "true" ]] \
    || die "сохранённый пул не совпал с ожидаемым (id/лимиты/пустой ключ) — проверь конфиг (бэкап: $backup)"
  info "В пуле $managed_count ключей из окружения, лимиты у всех одинаковые"
fi

# --- 6. Перезапуск ----------------------------------------------------------
# Счётчики лимитов живут в памяти процесса, рестарт их обнуляет: после
# перезапуска все ключи стартуют с utilization 0.

info "Перезапускаю $COMPOSE_SERVICE"
docker compose restart "$COMPOSE_SERVICE"

wait_for_ccr || die "после рестарта $CCR_URL не отвечает (бэкап конфига: $backup)"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' "$COMPOSE_SERVICE"

printf '\n'
info "Готово. Веб-морда: $CCR_URL (токен сменился после рестарта, открой $CCR_URL/ в браузере)"
