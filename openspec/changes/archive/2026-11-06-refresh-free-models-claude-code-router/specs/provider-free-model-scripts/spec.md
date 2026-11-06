## MODIFIED Requirements

### Requirement: REQ-PFM-001 Совместимые команды и параметры
Система SHALL предоставлять отдельные команды `get-free-models-openrouter.sh`, `get-free-models-orcarouter.sh`, `get-free-models-teamorouter.sh` и `get-free-models-kilo.sh`. Каждая команда SHALL принимать параметры `--format`, `--limit`, `--sort`, `--with-endpoints`, `--endpoints-concurrency`, `--cache-dir`, `--max-age`, `--max-age-endpoints`, `--refresh`, `--offline`, `--help` с одинаковой семантикой форматов.

#### Scenario: Одинаковая поверхность CLI
- **WHEN** пользователь запрашивает справку любой из четырёх команд
- **THEN** команда перечисляет одинаковый набор поддерживаемых параметров и провайдер-специфичные переменные окружения
