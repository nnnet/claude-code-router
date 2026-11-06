# free-model-refresh Specification

## Purpose
Определяет выбор router-платформ и атомарную синхронизацию их бесплатных моделей и credentials с claude-code-router, при которой сведения о моделях поступают только через provider discovery-команды.

## Requirements

### Requirement: REQ-FMR-001 Выбор платформ
Команда `refresh-free-models-claude-code-router.sh` SHALL принимать `--platforms` со списком имён через запятую, удалять пробелы и дубликаты и отклонять неизвестные имена. Если параметр отсутствует, команда SHALL выбрать все платформы, для которых рядом с ней существует исполняемый файл `get-free-models-*.sh`.

#### Scenario: Явный subset платформ
- **WHEN** пользователь передаёт `--platforms orcarouter,kilo`
- **THEN** refresh обрабатывает только OrcaRouter и Kilo и не вызывает остальные discovery-команды

#### Scenario: Все платформы по умолчанию
- **WHEN** пользователь не передаёт `--platforms`
- **THEN** refresh обрабатывает каждую платформу из исполняемых `get-free-models-*.sh` ровно один раз

### Requirement: REQ-FMR-002 Единственный источник сведений о моделях
Refresh SHALL получать таблицу, идентификаторы бесплатных моделей и сведения о размерах исключительно запуском выбранной `get-free-models-<platform>.sh`. Refresh MUST NOT содержать catalog URL, HTTP-загрузку provider-каталогов или правила определения бесплатности.

#### Scenario: Делегирование discovery-командам
- **WHEN** вместо discovery-команд предоставлены детерминированные test doubles
- **THEN** итоговый план конфигурации полностью строится из их `table`, `json-ids` и `sizes`, и каждая форма вызывается один раз на платформу

### Requirement: REQ-FMR-003 Синхронизация провайдеров CCR
Refresh SHALL создать отсутствующий либо обновить существующий CCR-провайдер каждой выбранной платформы по известному base URL. Список моделей SHALL совпадать с `json-ids` discovery-команды. Провайдеры и модели невыбранных платформ MUST сохраняться без изменений.

#### Scenario: Создание новых провайдеров
- **WHEN** исходный конфиг содержит только OpenRouter, а выбраны OrcaRouter, TeamoRouter и Kilo
- **THEN** новый конфиг содержит три отдельных новых провайдера с моделями из соответствующих discovery-команд и сохраняет OpenRouter без изменений

### Requirement: REQ-FMR-004 Безопасная синхронизация credentials
Для выбранной платформы refresh SHALL читать непустые ключи из переменных с её API-key prefix и заменять только credentials с id `env-free-models-<platform>-*`. Значения ключей MUST NOT выводиться. При отсутствии ключей существующие credentials SHALL сохраняться.

#### Scenario: Управляемые и ручные credentials
- **WHEN** у провайдера есть ручной credential и в окружении есть новый platform key
- **THEN** ручной credential сохраняется, управляемые credentials заменяются и секрет отсутствует в stdout/stderr

### Requirement: REQ-FMR-005 Атомарное применение
Refresh SHALL до записи создать бэкап, построить и проверить полный JSON, выполнить не более одного save RPC и одного restart за запуск. При ошибке любого discovery-вызова конфиг MUST NOT изменяться.

#### Scenario: Ошибка одной платформы
- **WHEN** discovery-команда одной из выбранных платформ завершается ошибкой
- **THEN** refresh завершается ненулевым кодом без save RPC и restart

### Requirement: REQ-FMR-006 Стабильные пользовательские команды
Локальный `PATH` SHALL содержать симлинки `get-free-models-<platform>.sh` для каждой discovery-команды и `refresh-free-models-claude-code-router.sh` для агрегатора. Старые симлинки переименованных команд SHALL отсутствовать.

#### Scenario: Вызов через локальный PATH
- **WHEN** пользователь разрешает путь каждого нового симлинка
- **THEN** он указывает на соответствующий исполняемый файл текущего проекта
