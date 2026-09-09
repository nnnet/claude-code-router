# Zed: оставить в списке провайдеров только CCR + LMStudio

- **Дата:** 2026-09-08
- **Режим:** `ak-fix --auto`
- **Контекст:** в UI Zed 1.18.1 нет провайдера CCR (`anthropic_compatible` /
  `local-router`), зато список забит ненужными провайдерами.

## Рамка задачи (intent frame)

- **Outcome:** в model picker Zed присутствуют только модели CCR
  (`OpenRouter/*` через `http://127.0.0.1:3458`) и LMStudio.
- **Constraints:**
  - `/home/uadmin/.local/bin/openrouter-free-models.sh` **не переписывать** —
    использовать как есть (symlink на `scripts/openrouter-free-models.sh`
    этого репозитория).
  - Контракт вызова инструмента (`--format table|json-ids|sizes`, `--sort`)
    не менять.
  - Не ломать браузер по умолчанию.
- **Non-goals:** не трогать логику самого CCR, не менять роутинг в контейнере,
  не чинить upstream-ошибки OpenRouter (403/400 на отдельных моделях).
- **Acceptance criteria:**
  1. `curl` к CCR тем же способом, каким ходит Zed (`POST /v1/messages`,
     `x-api-key`, `anthropic-version`) отвечает 200.
  2. `settings.json` после прогона `zed.sh` содержит валидный
     `anthropic_compatible.local-router` с рабочим ключом и **не** содержит
     мёртвого блока `openrouter`.
  3. Zed стартует, `Anthropic Compatible (local-router)` присутствует в
     model picker; OpenAI/OpenRouter-каталоги отсутствуют.
  4. LMStudio остаётся доступным.

## Диагноз (Step 2) — три независимых дефекта

### RC1 — CCR не аутентифицируется, поэтому скрыт из picker'а

`~/.config/zed/settings.json:136-138` задаёт

```json
"custom_headers": { "X-Auth-Token": "ccr-profile-0v" }
```

Доказательства (живые пробы к `http://127.0.0.1:3458/v1/messages`):

| Заголовок | HTTP | Тело |
|---|---|---|
| `X-Auth-Token: ccr-profile-0v` | 401 | `API key is missing.` |
| `x-api-key: ccr-profile-0v` | 401 | `Invalid API key.` |
| `Authorization: Bearer ccr-profile-0v` | 401 | `Invalid API key.` |
| `x-api-key: <реальный токен, 44 симв.>` | **200** | нормальный ответ |

Два дефекта в одной строке:

1. **Неверный канал аутентификации.** CCR вообще не читает `X-Auth-Token`
   (отвечает «API key is missing»), а принимает `x-api-key` /
   `Authorization: Bearer`. Именно `x-api-key` шлёт Zed'овский
   `anthropic_compatible`.
2. **Токен обрезан.** Реальный токен лежит в
   `/home/uadmin/.dsh/.credentials.yaml` под ключом
   `CLAUDE_CODE_ROUTER_API_KEY`, длина 44 символа, начинается на
   `ccr-profile-0vEC…`. В конфиге записаны первые 14 символов
   (`ccr-profile-0v`).

Дополнительно: Zed показывает провайдера в picker'е только когда тот
**аутентифицирован**. Ключ берётся из OS keychain, из настройки `api_key`
(поле присутствует в serde-FIELDS бинарника) либо из переменной окружения
`<PROVIDER_ID в UPPER_SNAKE>_API_KEY`. `custom_headers` ключом не считается,
поэтому провайдер остаётся неаутентифицированным и невидимым.

Каталог моделей при этом корректен: `GET /v1/models` у CCR отдаёт ровно те
16 id вида `OpenRouter/<vendor>/<model>`, что записаны в `available_models`.
Из них 11 отвечают 200; 2 (`google/*`) падают в 400 из-за коллизии имени
вендора с именем провайдера внутри CCR, 2 (`thinkingmachines/*`) — 403 от
upstream. Это дефекты CCR/upstream, вне рамок задачи (non-goal).

### RC2 — блок `openrouter` в настройках мёртв

`settings.json:48` и `zed.sh:259` (`or_cfg = lm.setdefault("openrouter", {})`)
пишут ключ `openrouter`. Zed 1.18.1 принимает только `open_router` (с
подчёркиванием). Список допустимых ключей извлечён из serde-FIELDS бинарника
`zed-editor`:

```
anthropic anthropic_compatible bedrock google llama.cpp mistral
ollama open_router openai openai_compatible vercel_ai_gateway zed.dev
```

Неизвестные ключи Zed молча игнорирует → весь блок из 16 моделей был
no-op'ом. По требованию «только CCR + LMStudio» блок не чинится, а удаляется.

Там же видно, что **`lmstudio` в этом списке отсутствует** — у LMStudio нет
секции настроек, провайдер сам обнаруживает сервер на `:1234`. Проверено:
`GET http://localhost:1234/v1/models` → 200, 10+ моделей. Значит требование
«LMStudio остаётся» выполняется бездействием.

### RC3 — источник «мусорных провайдеров»

`~/.bashrc:169-170` глобально экспортирует:

```sh
export OPENAI_API_KEY=…
export OPENROUTER_API_KEY=…
```

Zed выводит имя переменной окружения из id провайдера (UPPER_SNAKE +
`_API_KEY`) и по её наличию **автоматически аутентифицирует** провайдера —
в бинарнике есть константы `API_KEY_ENV_VAR` для open_router, open_ai,
google, mistral, deepseek, x_ai, lmstudio, ollama, opencode, anthropic,
vercel_ai_gateway, llama_cpp, codestral. `zed.sh` делает `exec "$ZED_BIN"`,
наследуя это окружение → в picker вываливаются полные каталоги OpenAI и
OpenRouter. Это и есть «мусор».

Ollama лежит (`:11434` недоступен), поэтому её в списке нет.

### Что починить нельзя (ограничение Zed 1.18.1)

Настройки для скрытия встроенных провайдеров **не существует**. В бинарнике
нет ни одного вхождения `disabled_providers`, `hidden_providers`,
`enabled_providers`, `exclude_providers`, `provider_allowlist` (0 совпадений
на каждый). Провайдеры, не требующие ключа, убрать из списка нечем.
Достижимый максимум — снять авто-аутентификацию по env, что убирает
OpenAI/OpenRouter/остальные ключевые провайдеры. Это фиксируется в отчёте,
а не обходится хаком (HARD-GATE-NO-SIDE-EFFECTS).

### Blast radius

- `~/.config/zed/settings.json` — перегенерируется при каждом запуске `zed.sh`
- `~/.config/zed/zed.sh` — генератор (python-heredoc)
- `~/.dsh/zed.sh` — **вторая независимая копия, побайтово идентичная**
  (разные inode). Расхождение = мина, держать в синхроне.
- `~/.local/share/applications/dev.zed.Zed.desktop` — реальный лаунчер Zed
- `~/.local/share/applications/zen.desktop` — **это Zen Browser, не Zed**

## Граф работ

```yaml
graph:
  - {id: A1, needs: [],       parallel: "",       status: "[x]", files: []}
  - {id: A2, needs: [A1],     parallel: "",       status: "[x]", files: []}
  - {id: B1, needs: [A2],     parallel: "",       status: "[x]", files: [~/.config/zed/zed.sh, ~/.dsh/zed.sh]}
  - {id: B2, needs: [B1],     parallel: "",       status: "[x]", files: [~/.config/zed/settings.json]}
  - {id: C1, needs: [B2],     parallel: "verify", status: "[x]", files: []}
  - {id: C2, needs: [B2],     parallel: "verify", status: "[~]", files: []}
  - {id: D1, needs: [C1, C2], parallel: "",       status: "[x]", files: [~/.local/share/applications/dev.zed.Zed.desktop]}
  - {id: D2, needs: [C1, C2], parallel: "",       status: "[!]", files: [~/.local/share/applications/zen.desktop]}
```

### A1 `scout` — карта затронутого
- выход: список файлов, копий, лаунчеров и источников токена
- приёмка: найдены обе копии `zed.sh`, канонический источник токена, оба
  `.desktop`
- заметки: найдено `~/.dsh/.credentials.yaml:9 CLAUDE_CODE_ROUTER_API_KEY`;
  две копии `zed.sh` с одинаковым содержимым, но разными inode.

### A2 `diagnose` — точная первопричина
- выход: RC1/RC2/RC3 с доказательствами file:line + живые пробы
- приёмка: все 6 пунктов HARD-GATE-EXACT-ROOT-CAUSE закрыты
- заметки: см. раздел «Диагноз» выше. Дополнительно установлено, что скрыть
  встроенные провайдеры в 1.18.1 нечем.

### B1 `fix-zed-sh` — генератор конфига и окружение
- выход: исправленный `zed.sh` (обе копии)
- приёмка: `bash -n` проходит; прогон генерирует корректный `settings.json`
- заметки:
  - брать токен из `~/.dsh/.credentials.yaml:CLAUDE_CODE_ROUTER_API_KEY`
    (fallback — `$ANTHROPIC_AUTH_TOKEN`), не хардкодить обрезок;
  - писать `api_key` вместо `custom_headers`, плюс экспортировать
    `LOCAL_ROUTER_API_KEY` перед `exec`;
  - убрать генерацию блока `openrouter`;
  - `unset` всех `*_API_KEY` нежелательных провайдеров перед `exec`.

### B2 `fix-settings` — привести текущий конфиг в целевой вид
- выход: `settings.json` без блока `openrouter`, с рабочим `local-router`
- приёмка: `jq` парсит; `.language_models | keys == ["anthropic_compatible"]`
- заметки: файл всё равно перегенерируется `zed.sh`, но должен быть
  корректен и без запуска скрипта.

### C1 `verify-api` — проба тем же способом, что ходит Zed
- выход: HTTP 200 от `POST /v1/messages` с `x-api-key`
- приёмка: код 200 и непустой `content[0].text`
- заметки: позитивный контроль до и после фикса.

### C2 `verify-ui` — фактический список провайдеров в Zed
- выход: подтверждение, что CCR виден, а OpenAI/OpenRouter — нет
- приёмка: запуск через `zed.sh`, проверка окружения процесса и логов
- заметки: —

### D1 `fix-zed-desktop` — лаунчер Zed через `zed.sh`
- выход: `dev.zed.Zed.desktop` с `Exec=/home/uadmin/.config/zed/zed.sh %U`
- приёмка: `desktop-file-validate` без ошибок; запуск из меню работает
- заметки: это настоящий ярлык Zed.

### D2 `zen-desktop` — требует решения пользователя
- выход: решение по `/home/uadmin/.local/share/applications/zen.desktop`
- приёмка: явный выбор пользователя
- заметки: **блокировано.** Файл — ярлык браузера Zen Browser
  (`Name=Zen Browser`, `Exec=…/.tarball-installations/zen/zen %u`), он же
  держит ассоциации `x-scheme-handler/http` и `https`. Подмена `Exec` на
  `zed.sh` сломает браузер по умолчанию и открытие ссылок из всех
  приложений. Спросить пользователя после тестов (как он и просил —
  «после тестов»).
