# zed.sh — только список моделей local-router

Дата: 2026-09-09. Контекст: после запуска Zed из меню GNOME модели local-router
исчезли, а в UI (Settings → AI → LLM Providers → local-router) пропал API-ключ.
Причина пропажи ключа: я удалил поле `api_key` из `~/.config/zed/settings.json`,
считая его no-op. Ключ туда вводит пользователь — трогать его нельзя.

## Цель

`~/.config/zed/zed.sh` делает ровно три вещи и ничего больше:

1. получает список free-моделей через `~/.local/bin/openrouter-free-models.sh`
   (ключи для этого не нужны);
2. пишет этот список в `available_models` провайдера `local-router` в
   `settings.json` — **и не трогает ни одного другого поля/провайдера/секции**;
3. запускает Zed.

## Отвергнуто

- Удаление «мусорных» провайдеров из конфига — это данные пользователя.
- Починка `agent.default_model` — то же самое.
- Перенос ключа из `settings.json` в `~/.config/environment.d/` — ключ должен
  оставаться там, куда его положил пользователь.

## Разобранный вопрос (узел C1)

Гипотеза подтвердилась. Факты:

- `gnome-shell` работает как `org.gnome.Shell@wayland.service` и своё окружение
  снимает один раз — при старте сессии. Приложения из меню он порождает форком
  от себя, поэтому `systemctl --user import-environment`, сделанный по ходу
  сессии, до них не доезжает: в окружении `gnome-shell` ключа нет (проверено по
  `/proc/<pid>/environ`), у systemd-менеджера — есть.
- Ключ из `settings.json` Zed 1.18.1 **не читает**: в списке полей настроек
  провайдера в бинаре есть `api_url`, `custom_headers`, `display_name`,
  `max_tokens`… — поля `api_key` там нет.
- В keyring записи Zed нет вообще (проверено через secretstorage, значения не
  печатались) — то есть третьего источника ключа тоже не было.

Итого источник ровно один — переменная окружения, и до запусков из меню она не
доходила.

## Граф работ

```yaml
graph:
  - {id: A1, needs: [],   parallel: "",       status: "[x]", files: [settings.json]}
  - {id: A2, needs: [],   parallel: "",       status: "[x]", files: [zed.sh]}
  - {id: B1, needs: [A2], parallel: "",       status: "[x]", files: [zed.sh]}
  - {id: C1, needs: [B1], parallel: "",       status: "[x]", files: []}
  - {id: C2, needs: [C1], parallel: "",       status: "[x]", files: [zed.sh]}
  - {id: D1, needs: [C2], parallel: "",       status: "[x]", files: [~/.dsh/zed.sh]}
```

### A1 `restore-api-key` — вернуть ключ в settings.json
- выход: поле `api_key` у провайдера `local-router` на месте
- приёмка: `jq` показывает `['api_url','available_models','api_key']`
- заметки: сделано; значение взято из `~/.config/environment.d/zed-local-router.conf`,
  в вывод не попадало

### A2 `strip-extra-edits` — убрать из zed.sh всё, кроме правки списка моделей
- выход: python-блок пишет только `local_router["available_models"]`
- приёмка: в блоке нет удаления провайдеров и правки `agent.default_model`
- заметки: сделано; удалён purge прочих провайдеров и ремонт `default_model`,
  комментарий про «api_key не существует» заменён на правило «поля пользователя
  не трогаем»

### B1 `verify-config-untouched` — проверить, что запуск ничего лишнего не меняет
- выход: диф `settings.json` до/после запуска zed.sh
- приёмка: изменился только `available_models`; `api_key`, `api_url`,
  `agent.default_model` и прочие ключи побайтово те же
- заметки: прогон `ZED_BIN=/bin/true ZED_REFRESH_FREE_MODELS=never` — рекурсивный
  диф до/после пуст, изменений нет вообще; `api_key` и `api_url` на месте,
  `agent.default_model` не тронут (сейчас его ведёт сам Zed)

### C1 `diagnose-menu-launch` — почему из меню GNOME модели не видны
- выход: установленная причина (окружение scope, другой .desktop, кеш keyring)
- приёмка: воспроизведён запуск без переменной окружения и зафиксировано,
  видит ли Zed ключ из `settings.json`
- заметки: причина — окружение. У `gnome-shell` (unit `org.gnome.Shell@wayland`)
  переменной нет, у systemd-менеджера пользователя есть; приложения из меню
  форкаются от shell и ключа не получают. `api_key` из `settings.json` Zed 1.18.1
  не читает (нет такого поля в списке настроек провайдера в бинаре), в keyring
  записи Zed нет. Источник ключа ровно один — env

### C2 `fix-menu-launch` — сделать так, чтобы из меню работало так же
- выход: правка в zed.sh или в .desktop
- приёмка: Zed, запущенный из меню, показывает модели local-router
- заметки: добавлена `zed_launch()` — Zed порождается транзиентной user-службой
  (`systemd-run --user --collect --same-dir --property=KillMode=process`),
  окружение ей выдаёт менеджер сессии. `KillMode=process` обязателен: обёртка
  zed завершается после порождения zed-editor, при дефолтном control-group
  systemd убил бы редактор следом. Выключатель — `ZED_NO_SYSTEMD_RUN=1`,
  предохранитель — наличие `WAYLAND_DISPLAY`/`DISPLAY` у менеджера (иначе прямой
  запуск, чтобы не остаться без GUI-окружения). Пользователь проверил оба пути —
  из меню GNOME и `~/.config/zed/zed.sh`: модели видны и отвечают.
  Долговременный источник переменных — `~/.config/environment.d/*.conf`

### D1 `sync-mirror` — синхронизировать зеркало
- выход: `~/.dsh/zed.sh` совпадает с `~/.config/zed/zed.sh`
- приёмка: `diff -q` без расхождений
- заметки: сделано, `diff -q` молчит
