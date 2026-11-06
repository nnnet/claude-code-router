Feature: Агрегированное обновление бесплатных моделей CCR
  Пользователь выбирает router-платформы, а CCR получает модели только через provider discovery-команды.

  @REQ-FMR-001
  Scenario: Выбор subset и всех платформ
    Given доступны четыре discovery-команды
    When refresh запускается с comma-separated subset либо без списка
    Then вызываются ровно выбранные либо все обнаруженные платформы без дублей

  @REQ-FMR-002
  Scenario: Строгое делегирование discovery
    Given discovery-команды записывают каждый вызов
    When refresh строит новый конфиг
    Then для каждой платформы используются только table json-ids и sizes без catalog-логики в refresh

  @REQ-FMR-003
  Scenario: Reconciliation выбранных провайдеров
    Given исходный конфиг содержит OpenRouter и пользовательский провайдер
    When выбраны OrcaRouter TeamoRouter и Kilo
    Then новые провайдеры получают модели discovery-команд а невыбранные данные сохраняются

  @REQ-FMR-004
  Scenario: Безопасное обновление credentials
    Given у провайдера есть ручной credential и новый ключ в окружении
    When refresh пересобирает управляемую часть пула
    Then ручной credential сохраняется а секрет отсутствует в выводе

  @REQ-FMR-005
  Scenario: Fail-fast до применения
    Given одна discovery-команда завершается ошибкой
    When запускается агрегированный refresh
    Then итоговый конфиг не записывается и последующие платформы не вызываются

  @REQ-FMR-006
  Scenario: Новые команды доступны через локальный PATH
    Given проектные скрипты переименованы
    When разрешаются симлинки в local bin
    Then каждый новый путь указывает на соответствующий исполняемый файл проекта
