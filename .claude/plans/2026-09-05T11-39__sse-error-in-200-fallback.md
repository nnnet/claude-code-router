# Патч CCR: fallback при ошибке внутри HTTP 200 SSE

- Дата: 2026-09-05
- Ветка: `fix/sse-error-in-200-fallback` (от `main` @ `5ad5083b`)
- Режим: `--auto --tdd`

## Контекст

Claude Code падает с `API Error: API returned an empty or malformed response
(HTTP 200)`. Диагностика по живым логам CCR (25 уникальных запросов,
07:57–08:09 05.09): streaming **5/18 отказов (28%)**, unary **0/7**. Подпись
отказа одинаковая: `statusCode 200, ok=false, isStream=true, outputTokens=0,
contentType=text/event-stream, sizeBytes=179,
error="rate_limit_error: Provider returned error"`.

OpenRouter на Anthropic-совместимом эндпоинте уже закоммитил заголовки `200
text/event-stream` и не может выразить отказ статусом — кладёт ошибку в первый
SSE-фрейм. Claude Code видит 200 без `message_start` → жёсткая ошибка, ретрая нет.

## Почему CCR это пропускает

1. `packages/core/src/routing/failure-classifier.ts:11-18` — решение о fallback
   принимается **только по HTTP-статусу**; 200 = успех.
2. `packages/core/src/gateway/upstream/executor.ts:477` — единственная точка,
   где включается следующая модель цепочки; условие `shouldFallbackAfterStatus(
   response.status, fallbackMode)`. Тело ответа не читается.
3. `packages/core/src/gateway/request/pipeline.ts:854` — `response.writeHead(...)`
   выполняется **до** чтения тела: 200 уже отдан клиенту.
4. `pipeline.ts:913` — `createSseErrorDetector(...)` ошибку **уже детектирует**,
   но результат уходит только в `writeStreamLog`/request-log.

То есть детектор написан, машинерия fallback написана — они просто не соединены.

## Решение

Реализовать **peek-first-chunk** в `executor.ts` перед возвратом ответа:
прочитать первый смысловой SSE-фрейм (пропуская `ping`/keepalive), и если это
`event: error` без предшествующего `message_start` — считать попытку
провалившейся, подставив синтетический статус **529**, после чего управление
уходит в уже существующую ветку `executor.ts:477`. Прочитанные байты
возвращаются в поток, чтобы успешный случай не терял данные.

Тот же алгоритм Portkey обкатал в проде («Catch Overloaded Error on Stream»:
читает первый чанк до коммита клиенту, пропускает ping, при `overloaded_error`
отдаёт 529). Мы не изобретаем — копируем проверенное.

**529 как несущий статус** выбран сознательно: он уже проходит
`classifyStatus() → "server"` и поэтому работает и в `mode: "retry"`, и в
`mode: "model-chain"` без правки классификатора.

### Отвергнутые варианты

- **Правка `failure-classifier.ts`** — классификатор чистый и синхронный
  (статус → класс). Тащить в него тело ответа = ломать контракт ради одного
  случая. Синтетический 529 достигает того же, не трогая файл.
- **Детект в `pipeline.ts`** — там заголовки уже отправлены (строка 854),
  переиграть на другую модель физически нельзя. Только `executor.ts`.
- **Переезд на другой роутер** — разобрано отдельно: Bifrost решает только по
  HTTP-статусу (та же архитектура) + известный баг стриминга tool calls через
  OpenRouter; LiteLLM имеет mid-stream fallback, но не на `/v1/messages`
  (BerriAI/litellm#24004); Portkey имеет нужный тумблер, но прибитый к
  Anthropic-интеграции и типу `overloaded_error`, а у нас OpenRouter и
  `rate_limit_error`.

## Приёмка (общая)

1. Запрос, у которого upstream отдаёт `200 text/event-stream` + первый фрейм
   `event: error`, при `fallback.mode = "model-chain"` уходит на следующую
   модель цепочки; при `"retry"` — ретраится.
2. Нормальный стрим не теряет ни одного байта и не получает лишней задержки
   сверх первого фрейма.
3. `ping`-фреймы перед содержимым не считаются ошибкой.
4. Фича выключаема: `fallback.detectStreamErrors = false` → поведение
   побайтово как до патча.
5. `npm test` зелёный целиком (не только новые тесты).
6. Публичные контракты не ломаются: `RouterFallbackConfig` расширяется
   опциональным полем со значением по умолчанию.

## Граф работ

```yaml
graph:
  - {id: A1, needs: [],       parallel: "",        status: "[x]", files: [packages/core/test/unit/gateway/upstream-executor.test.mjs]}
  - {id: A2, needs: [],       parallel: "contract", status: "[x]", files: [packages/core/src/contracts/app.ts]}
  - {id: A3, needs: [],       parallel: "contract", status: "[x]", files: [packages/core/src/config/default-config.ts, packages/ui/src/pages/home/shared/routing.ts]}
  - {id: B1, needs: [A1, A2], parallel: "",        status: "[x]", files: [packages/core/src/gateway/upstream/executor.ts]}
  - {id: B2, needs: [B1],     parallel: "",        status: "[x]", files: []}
  - {id: C1, needs: [A2, A3], parallel: "ui",      status: "[x]", files: [packages/ui/src/pages/home/components/routing.tsx, packages/ui/src/pages/home/shared/i18n.tsx]}
  - {id: D1, needs: [B2],     parallel: "",        status: "[!]", files: []}
  - {id: D2, needs: [B2, C1], parallel: "",        status: "[x]", files: []}
```

Реализовано в коммите `dfb1be7e` на ветке `fix/sse-error-in-200-fallback`.
D1 ждёт пользователя: пересборка образа рестартует работающий контейнер —
решение о моменте за владельцем, команды ниже в заметках узла.

### A1 `executor-sse-peek-tests` — тесты (TDD red)

- выход: кейсы в `packages/core/test/unit/gateway/upstream-executor.test.mjs`
- приёмка: тесты написаны и **падают** до B1, проходят после. Покрыть:
  (a) первый фрейм `event: error` → fallback сработал;
  (b) нормальный стрим → байты не потеряны, порядок сохранён;
  (c) `ping` перед контентом → не ошибка;
  (d) `detectStreamErrors: false` → старое поведение;
  (e) пустое тело при 200 → трактуется как отказ.
- заметки: рядом лежит `sse-utf8-chunk-boundary.test.mjs` — прецедент тестов на
  границы SSE-чанков, взять его как образец стиля. Кейс (b) обязан проверять
  разрыв фрейма по границе чанка.

### A2 `fallback-config-field` — поле конфига

- выход: `detectStreamErrors?: boolean` в `RouterFallbackConfig`
  (`contracts/app.ts:741`)
- приёмка: `tsc` чист; поле опционально, дефолт задаётся в A3
- заметки: рядом `RouterFallbackMode` (:737) и
  `ROUTER_FALLBACK_MAX_RETRY_COUNT` (:739). Дефолт — `true`: чинит ошибку
  «из коробки», выключается осознанно.

### A3 `fallback-config-normalize` — нормализация и дефолт

- выход: `detectStreamErrors` проставляется в нормализаторе конфига
- приёмка: старый конфиг без поля читается без ошибок и получает `true`;
  сохранение через `saveConfig` не теряет поле
- заметки: найти точное место `normalizeRouterFallbackConfig` — в
  `routing.tsx:7` он импортируется из shared-слоя, проверить, есть ли парная
  нормализация на стороне core (`config-compiler.ts`). Если нормализаторов два
  (core + ui), править оба, иначе UI будет затирать поле.

### B1 `executor-peek-impl` — peek первого фрейма

- выход: в `executor.ts` перед возвратом `{attempt, failedAttempts, response}`
  — чтение первого смыслового SSE-фрейма и подстановка статуса 529 при ошибке
- приёмка: тесты A1 зелёные; при выключенном флаге путь кода не меняется
- заметки: точка входа — условие на строке 477. Переиспользовать
  `createSseErrorDetector` из `observability/request-log-store.ts:5829`
  (парсер `event:`/`data:`, `flushEvent()`, `detectSseEventError`,
  `isSseTerminalEvent`) — **не писать второй парсер**. Прочитанные байты
  вернуть в поток через `ReadableStream`, склеив peek-буфер с остатком.
  Ограничить peek по объёму и по таймауту, чтобы медленный upstream не завис.

### B2 `pipeline-passthrough` — сквозная проверка pipeline

- выход: подтверждение, что реассемблированный поток проходит `pipeline.ts`
  без потерь и без двойного логирования
- приёмка: интеграционный прогон; в request-log одна запись на попытку, не две
- заметки: `pipeline.ts:854` (`writeHead`) не трогать — к моменту его вызова
  решение уже принято в executor. Проверить ветку
  `if (!upstreamResponse.body)` — сейчас она отдаёт пустой 200 как есть;
  после патча пустое тело должно приходить уже как отказ (кейс A1-e).

### C1 `ui-toggle` — тумблер на веб-морде

- выход: переключатель «Detect in-stream errors» в блоке fallback
- приёмка: тумблер виден, меняет конфиг через `saveConfig`, переживает
  перезагрузку страницы; строки есть на en и zh
- заметки: `RouterFallbackControl` — `routing.tsx:201`, патч состояния через
  `updateFallbackPatch({ detectStreamErrors })` (:219). Рядом уже есть
  `<Select>` для `fallback.mode` (:255) — взять как образец. i18n-ключи в
  `shared/i18n.tsx`; в репозитории строки в двух локалях, добавить обе.

### D1 `docker-rebuild-verify` — пересборка и живая проверка

- выход: контейнер `claude-code-router-ccr-1` на новом образе
- приёмка: в request-logs при повторении отказа видно переключение модели, а
  не `outputTokens: 0`
- заметки: `docker-compose.yml` собирается из локального исходника
  (`build: context: .`, image `claude-code-router:local`), поэтому
  пересборка штатная. **Внимание:** в рабочем дереве `docker-compose.yml`
  уже был изменён до начала работ (`M docker-compose.yml`) — перед сборкой
  посмотреть `git diff docker-compose.yml`, чтобы не увезти чужую правку.
  Команды: `docker compose build ccr && docker compose up -d ccr`.
  Порты: 3458 (nginx) и 3456. Токен веб-морды генерируется заново при каждом
  старте контейнера (`docker/entrypoint.sh:16-32`) — после рестарта брать
  новый из `Location`-заголовка редиректа с `/`.

### D2 `review-and-report` — ревью и отчёт

- выход: ревью изменений, финальный отчёт
- приёмка: нет регрессий в вызывающих `shouldFallbackAfterStatus`; тесты не
  хуже базы; публичные контракты не сломаны
- заметки: **выполнено.** `tsc --noEmit` чист. Тесты: база на чистом дереве
  875/887 (5 падений), с патчем 882/893 (4 падения) — множество падений
  строго вложено в базовое, новых регрессий нет. Оставшиеся 4 падения
  (`RequestLogStore bounded heap regression`, `known bundled plugins…`,
  два `Claude Design plugin config…`) воспроизводятся без патча.
  Пятое (`profile service preserves user statusLine…`) флапает — упало на
  чистом дереве и прошло с патчем; зависит от окружения (`~/.claude`),
  не от кода. Architecture-набор 4/4.
  Ревью проводил сам, без subagent: правило сессии запрещает вызывать
  Agent-tool без явной просьбы пользователя.
  Контракт расширен только опциональным полем — обратная совместимость есть.

## Границы

Все изменения — внутри `/mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Proxy/claude-code-router`.
`~/.claude.json` не трогаем. Запуск `claude` остаётся одной командой из
каталога проекта, вся конфигурация — в `./.claude/settings.json`.
