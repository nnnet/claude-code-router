## Why

Текущий refresh обновляет только OpenRouter и напрямую привязан к одному discovery-скрипту. После добавления OrcaRouter, TeamoRouter и Kilo Gateway нужен единый управляемый вход, который выбирает платформы, использует их публичный CLI-контракт без копирования catalog-логики и синхронизирует отдельные провайдеры CCR.

## What Changes

- Все provider discovery-команды получают единый шаблон имени `get-free-models-<платформа>.sh`.
- Refresh-команда переименовывается в `refresh-free-models-claude-code-router.sh` и принимает `--platforms` со списком платформ через запятую.
- Без `--platforms` команда обнаруживает все исполняемые `scripts/get-free-models-*.sh`.
- Каталоги, отбор бесплатных моделей, размеры и форматы refresh получает исключительно вызовами discovery-команд.
- Для выбранных платформ в конфиге CCR создаются либо обновляются отдельные провайдеры и управляемые credentials из переменных окружения.
- Пользовательские модели, credentials и провайдеры вне управляемой области сохраняются.
- Локальные симлинки заменяются новыми именами.

## Capabilities

### New Capabilities

- `free-model-refresh`: Выбор платформ и синхронизация бесплатных моделей/ключей в claude-code-router через provider discovery-команды.

### Modified Capabilities

- `provider-free-model-scripts`: Стандартизированные имена discovery-команд с префиксом `get-free-models-`.

## Impact

Изменяются Bash-команды в `scripts/`, OpenSpec/BDD-артефакты, Makefile и локальные симлинки в `~/.local/bin`. Конфиг работающего CCR обновляется через существующий management RPC с предварительным бэкапом и одним restart после успешного сохранения.
