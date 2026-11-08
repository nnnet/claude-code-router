#!/usr/bin/env bash
# Актуализация списка бесплатных моделей OpenRouter для dsh.
#
# Вынесено из ~/.dsh/start-web.sh, чтобы список можно было обновить, не
# перезапуская веб-морду. Файл работает в двух режимах:
#   * `source ~/.dsh/refresh-free-models.sh` — определяет функцию
#     refresh_openrouter_free_models и ничего не делает (так его подключает
#     start-web.sh, вызывая функцию в своей последовательности старта);
#   * `bash ~/.dsh/refresh-free-models.sh` — сразу выполняет обновление.
#
# Использует standalone-инструмент ~/.local/bin/openrouter-free-models.sh
# (он самодостаточен: нужен только curl+jq, не требует docker/CCR).
#
# Переменные окружения:
#   DSH_REFRESH_FREE_MODELS=always|never|force  режим (по умолчанию always;
#                        always уважает возраст кэша, force идёт в сеть всегда)
#   DSH_MODELS_DIR       каталог кэша (по умолчанию ~/.dsh/models)
#   DSH_FREE_MODELS_MAX_AGE  возраст кэша в секундах (по умолчанию 86400)
#   DSH_NO_UPSTREAM_CHECK=1  запрет на поход в сеть (перебивается force)
#   DSH_SETTINGS_PATH    путь к кастомному конфигу dsh
#                        (по умолчанию ~/.dsh/settings.yaml)
#   DSH_FREE_MODELS_TABLE=0  не печатать таблицу моделей
#   DSH_CCR_PROVIDER_KEY  ключ провайдера claude-code-router в settings.yaml
#                        (по умолчанию claude-code-router)
#   DSH_CCR_MODEL_PREFIX  имя провайдера внутри CCR, оно же префикс модели
#                        (по умолчанию OpenRouter -> OpenRouter/<id модели>)
#   DSH_CCR_BASE_URL     адрес CCR, если провайдера в конфиге ещё нет
#                        (по умолчанию http://127.0.0.1:3458)

# Путь к standalone-инструменту (в PATH или по полному пути)
OPENROUTER_TOOL="${OPENROUTER_TOOL:-~/.local/bin/openrouter-free-models.sh}"
# Раскрываем тильду
OPENROUTER_TOOL="${OPENROUTER_TOOL/#\~/$HOME}"
# Проверка на доступность
if [ ! -x "$OPENROUTER_TOOL" ]; then
  echo "openrouter free: warn — инструмент не найден или неисполняемый: $OPENROUTER_TOOL" >&2
  # Fallback: пробуем найти в PATH
  if command -v openrouter-free-models.sh >/dev/null 2>&1; then
    OPENROUTER_TOOL="$(command -v openrouter-free-models.sh)"
  else
    echo "openrouter free: ошибка — не найден openrouter-free-models.sh" >&2
    return 1
  fi
fi

# --- актуализация списка бесплатных моделей OpenRouter ---------------------
# Лёгкий периодический refresh. При DSH_NO_UPSTREAM_CHECK=1 не ходим в сеть;
# любой сбой — warning, не фатал. Кэш в $MODELS_DIR/... свежий список :free
# моделей в JSON. Этот же список вливается в ~/.dsh/settings.yaml в секцию
# llm-pi-ai.providers.openrouter.models[] — именно её читает dsh-UI.
# Режим: DSH_REFRESH_FREE_MODELS=always|never|force.
#
# Возвращает 0, если кэш актуален (или успешно обновлён); 0 и в случае
# пропуска/skip с warning, чтобы под `set -e` это никогда не ломало старт.
refresh_openrouter_free_models() {
  local mode="${DSH_REFRESH_FREE_MODELS:-always}"
  local models_dir="${DSH_MODELS_DIR:-$HOME/.dsh/models}"
  local cache="$models_dir/openrouter-free.json"
  local sizes_cache="$models_dir/openrouter-sizes.json"
  local max_age="${DSH_FREE_MODELS_MAX_AGE:-86400}"

  # Построим аргументы для standalone-инструмента
  # Базовые аргументы инструмента. Порядок сортировки и --refresh заданы
  # явно и одинаково для всех трёх вызовов: раньше таблица и список id
  # сортировались по-разному (total,active,ctx), из-за чего на экране был
  # один порядок, а в settings.yaml — другой.
  local tool_args=(
    --cache-dir "$models_dir"
    --max-age "$max_age"
    --sort ctx,-total,active
    --refresh
  )

  case "$mode" in
    never)
      echo "openrouter free: пропуск (DSH_REFRESH_FREE_MODELS=never)"
      _dsh_print_cached_free_models "$cache" "$sizes_cache"
      return 0 ;;
    always) ;;
    force)
      : ;;  # --refresh уже в базовых аргументах
    *)
      echo "openrouter free: неизвестный режим '$mode', использую always" >&2
      mode=always ;;
  esac

  # DSH_NO_UPSTREAM_CHECK=1 запрещает поход в сеть — даже в always.
  # В force-режиме политика перебивает этот запрет, иначе force бесполезен.
  if [ "${DSH_NO_UPSTREAM_CHECK:-0}" = 1 ] && [ "$mode" != "force" ]; then
    echo "openrouter free: пропуск (DSH_NO_UPSTREAM_CHECK=1)"
    _dsh_print_cached_free_models "$cache" "$sizes_cache"
    return 0
  fi

  # --- 1. Таблица в консоль (всегда печатаем, если не отключено) ---
  #
  # --with-endpoints добавляет колонки Latency / Throughput / Uptime: без него
  # инструмент берёт только каталог, где метрик провайдеров нет, и колонки
  # остаются пустыми. Флаг идёт ТОЛЬКО сюда: форматы json-ids и sizes ниже
  # этих колонок не содержат, а каждая модель стоит отдельного запроса к
  # /endpoints — платить за данные, которые никто не прочитает, незачем.
  #
  # Метрики живут своим кэшем (--max-age-endpoints, 30 мин по умолчанию),
  # отдельно от суточного кэша каталога: latency устаревает быстрее состава.
  #
  # DSH_FREE_MODELS_ENDPOINTS=0 — аварийный выключатель, если опрос
  # провайдеров тормозит старт (без GNU parallel он идёт медленнее).
  if [ "${DSH_FREE_MODELS_TABLE:-1}" = 1 ]; then
    local table_args=("${tool_args[@]}")
    if [ "${DSH_FREE_MODELS_ENDPOINTS:-1}" = 1 ]; then
      table_args+=(
        --with-endpoints
        --endpoints-concurrency "${DSH_FREE_MODELS_ENDPOINTS_CONCURRENCY:-4}"
      )
    fi
    "$OPENROUTER_TOOL" "${table_args[@]}" --format table
    printf '\n'
  fi

  # --- 2. Получить отсортированные ID бесплатных моделей (JSON-массив) ---
  # Сортировка: total,active,ctx (убывание) — как в CCR-скрипте
  local free_ids
  free_ids="$("$OPENROUTER_TOOL" "${tool_args[@]}" --format json-ids)"
  local free_count
  free_count=$(jq 'length' <<< "$free_ids" 2>/dev/null || echo 0)

  if [ "$free_count" -eq 0 ]; then
    echo "openrouter free: warn — каталог пуст или нечитаем, кэш не тронут" >&2
    _dsh_print_cached_free_models "$cache" "$sizes_cache"
    return 0
  fi

  # --- 3. Получить карту размеров для всех моделей каталога ---
  local sizes_json
  sizes_json="$("$OPENROUTER_TOOL" "${tool_args[@]}" --format sizes 2>/dev/null)"

  # Сохраняем кэш (атомарно)
  mkdir -p -- "$models_dir"
  local tmp_cache
  tmp_cache=$(mktemp -- "$models_dir/.openrouter-free.XXXXXX.json")
  printf '%s\n' "$free_ids" > "$tmp_cache"
  mv -f -- "$tmp_cache" "$cache"
  tmp_cache=$(mktemp -- "$models_dir/.openrouter-sizes.XXXXXX.json")
  printf '%s\n' "$sizes_json" > "$tmp_cache"
  mv -f -- "$tmp_cache" "$sizes_cache"

  echo "openrouter free: получено $free_count моделей, кэш обновлён: $cache"

  # --- 4. Обновить settings.yaml (Python-скрипт без изменений) ---
  local settings_path="${DSH_SETTINGS_PATH:-$HOME/.dsh/settings.yaml}"
  local ccr_key="${DSH_CCR_PROVIDER_KEY:-claude-code-router}"
  local ccr_prefix="${DSH_CCR_MODEL_PREFIX:-OpenRouter}"

  if [ -f "$settings_path" ]; then
    cp -- "$settings_path" "$settings_path.bak"
  fi

  python3 - "$settings_path" "$free_ids" "$sizes_json" "$ccr_key" "$ccr_prefix" <<'PYEOF'
import yaml, sys, json, os
path = sys.argv[1]
models_json = sys.argv[2]
models = json.loads(models_json)
# Карта "id -> {ctx, total, active}" по всему каталогу: тот же ключ сортировки,
# что и в jq, чтобы платные модели пользователя встали в общий порядок.
sizes = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

def size_key(mid):
    m = sizes.get(mid) or {}
    total, active, ctx = m.get("total"), m.get("active"), m.get("ctx")
    return (
        -(total if total is not None else -1),
        -(active if active is not None else -1),
        -(ctx if ctx is not None else -1),
        mid,
    )

with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

# Удаляем старое хранилище, если оно было — больше не используется.
data.pop("free_models", None)

# Гарантируем путь llm-pi-ai.providers.openrouter.
llm = data.setdefault("llm-pi-ai", {})
provs = llm.setdefault("providers", {})
or_p = provs.setdefault("openrouter", {})
or_p.setdefault("displayName", "OpenRouter")
or_p.setdefault("api", "openai-completions")
or_p.setdefault("baseURL", "https://openrouter.ai/api/v1")
or_p.setdefault("apiKeyEnv", "OPENROUTER_API_KEY")

existing = or_p.get("models") or []
if not isinstance(existing, list):
    existing = []

# Нормализуем уже записанные модели: оставляем только dict-форму, держим порядок.
existing_clean = []
seen_ids = set()
for m in existing:
    if isinstance(m, str):
        mid = m
        entry = {"id": mid, "name": mid}
    elif isinstance(m, dict) and m.get("id"):
        mid = m["id"]
        entry = m
    else:
        continue
    if mid in seen_ids:
        continue
    seen_ids.add(mid)
    existing_clean.append(entry)

# Сохраняем все не-:free записи как есть (пользовательские платные модели).
kept = [m for m in existing_clean if not (m.get("id", "").endswith(":free"))]

# Добавляем свежие :free модели и пересортировываем весь список по убыванию
# размера модели — иначе платные записи навсегда осели бы в начале.
fresh_set = list(models)
kept_ids = {m["id"] for m in kept}
merged = kept + [{"id": mid, "name": mid} for mid in fresh_set if mid not in kept_ids]
merged.sort(key=lambda m: size_key(m.get("id", "")))
or_p["models"] = merged
provs["openrouter"] = or_p
llm["providers"] = provs
data["llm-pi-ai"] = llm

# Провайдер claude-code-router (displayName "CCR").
ccr_key = sys.argv[4] if len(sys.argv) > 4 else "claude-code-router"
ccr_prefix = sys.argv[5] if len(sys.argv) > 5 else "OpenRouter"
ccr_pfx = ccr_prefix + "/"

def strip_ccr(mid):
    return mid[len(ccr_pfx):] if mid.startswith(ccr_pfx) else mid

ccr_p = provs.get(ccr_key)
if not isinstance(ccr_p, dict):
    ccr_p = {
        "displayName": "CCR",
        "api": "anthropic-messages",
        "baseURL": os.environ.get("DSH_CCR_BASE_URL", "http://127.0.0.1:3458"),
    }

ccr_existing = ccr_p.get("models") or []
if not isinstance(ccr_existing, list):
    ccr_existing = []

ccr_clean, ccr_seen = [], set()
for m in ccr_existing:
    if isinstance(m, str):
        mid, entry = m, {"id": m}
    elif isinstance(m, dict) and m.get("id"):
        mid, entry = m["id"], m
    else:
        continue
    if mid in ccr_seen:
        continue
    ccr_seen.add(mid)
    ccr_clean.append(entry)

ccr_kept = [m for m in ccr_clean if not m["id"].endswith(":free")]
ccr_kept_ids = {m["id"] for m in ccr_kept}
ccr_merged = ccr_kept + [
    {"id": ccr_pfx + mid} for mid in fresh_set if ccr_pfx + mid not in ccr_kept_ids
]
ccr_merged.sort(key=lambda m: size_key(strip_ccr(m.get("id", ""))))
ccr_p["models"] = ccr_merged
provs[ccr_key] = ccr_p

# agent-default-model: только если провайдер = openrouter и текущая модель
# либо :free, либо не указана. Не-`:free` выбор пользователя — святое.
adm = data.get("agent-default-model")
if isinstance(adm, dict) and adm.get("provider") == "openrouter":
    cur = adm.get("model", "") or ""
    if fresh_set and (not cur or cur.endswith(":free")):
        adm["model"] = fresh_set[0]
        data["agent-default-model"] = adm

with open(path, "w", encoding="utf-8") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF

  # Краткий diff для лога
  local added=0
  if [ -f "$settings_path.bak" ]; then
    added=$({ diff <(python3 -c 'import yaml; d=yaml.safe_load(open("'"$settings_path.bak"'")); print("\n".join(m.get("id","") if isinstance(m,dict) else m for m in d.get("llm-pi-ai",{}).get("providers",{}).get("openrouter",{}).get("models",[])))' 2>/dev/null) \
           <(python3 -c 'import yaml; d=yaml.safe_load(open("'"$settings_path"'")); print("\n".join(m.get("id","") if isinstance(m,dict) else m for m in d.get("llm-pi-ai",{}).get("providers",{}).get("openrouter",{}).get("models",[])))' 2>/dev/null) \
           || true; } | { grep -c '^>' || true; })
  fi
  local ccr_count
  ccr_count=$(python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])) or {}; print(len(((d.get("llm-pi-ai") or {}).get("providers") or {}).get(sys.argv[2], {}).get("models") or []))' \
    "$settings_path" "$ccr_key" 2>/dev/null || echo 0)
  echo "openrouter free: записано $free_count моделей в $cache; +${added} новых в $settings_path (llm-pi-ai.providers.openrouter.models)"
  echo "openrouter free: провайдер $ccr_key — $ccr_count моделей с префиксом $ccr_prefix/"
}

# --- Печать таблицы из кэша (для путей never/skip) -------------------------
_dsh_print_cached_free_models() {
  local cache="$1" sizes_cache="$2" ids sizes=''
  [ -f "$cache" ] || return 0
  ids=$(cat -- "$cache") || return 0
  if [ -f "$sizes_cache" ]; then sizes=$(cat -- "$sizes_cache"); fi
  _dsh_print_free_models_table "$ids" "$sizes"
}

# Печать таблицы моделей. $1 — JSON-массив id, $2 — JSON-карта размеров.
_dsh_print_free_models_table() {
  local ids="$1" sizes="$2"
  [ "${DSH_FREE_MODELS_TABLE:-1}" = 1 ] || return 0
  [ -n "$ids" ] || return 0
  [ -n "$sizes" ] || sizes='{}'
  command -v jq >/dev/null 2>&1 || return 0
  command -v column >/dev/null 2>&1 || return 0
  jq -r --argjson s "$sizes" '
    ["ID модели", "Контекст (к)", "Параметры", "Активных", "Обучение"],
    (["-"*40, "-"*12, "-"*10, "-"*10, "-"*10]),
    (.[] | . as $id | ($s[$id] // {}) as $m | [
      $id,
      (($m.ctx // 0) / 1024 | round | tostring + "k"),
      ($m.total  | if . == null then "—"
        elif . >= 1000000000000 then ((. / 100000000000 | round) / 10 | tostring) + "T"
        elif . >= 1000000000    then ((. / 100000000    | round) / 10 | tostring) + "B"
        elif . >= 1000000       then ((. / 100000       | round) / 10 | tostring) + "M"
        else tostring end),
      ($m.active | if . == null then "—"
        elif . >= 1000000000000 then ((. / 100000000000 | round) / 10 | tostring) + "T"
        elif . >= 1000000000    then ((. / 100000000    | round) / 10 | tostring) + "B"
        elif . >= 1000000       then ((. / 100000       | round) / 10 | tostring) + "M"
        else tostring end),
      ($m.tokens | if . == null then "—"
        elif . >= 1000000000000 then ((. / 100000000000 | round) / 10 | tostring) + "T"
        elif . >= 1000000000    then ((. / 100000000    | round) / 10 | tostring) + "T"
        elif . >= 1000000       then ((. / 100000       | round) / 10 | tostring) + "M"
        else tostring end)
    ]) | @tsv' <<<"$ids" | column -t -s $'\t'
}

# Прямой запуск (не source) — выполняем обновление сразу.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -Eeuo pipefail
  refresh_openrouter_free_models "$@"
fi