# Demo 02 — DLQ Handler

**Цель:** Обработка упавших сообщений (Dead Letter Queue) из RabbitMQ, с AI-классификацией корневой причины и умным роутингом уведомлений.

## Что демонстрирует

Стандартная боль в интеграциях: из 1С через RabbitMQ прилетают сообщения, часть падает. Дежурный инженер утром смотрит список из сотни ошибок, большая часть из которых — повторы одной причины. N8N решает это так:

1. Читает DLQ-очередь в реальном времени.
2. Обогащает сообщение контекстом из БД (кто контрагент, когда было последнее успешное сообщение, сколько ошибок у него за сутки).
3. LLM классифицирует корневую причину: наш баг / данные партнёра / инфраструктура / нарушение бизнес-правила.
4. Роутит уведомление в правильный канал: инфра — в `#ops`, проблема партнёра — менеджеру этого клиента, наш баг — автоматический issue в GitLab.
5. Дополнительно: anomaly detector раз в час сравнивает текущий поток с baseline и предупреждает о тихих деградациях («у клиента X обычно 20 накладных в час, сейчас 0 второй час подряд»).

## Как запустить

### 1. Инфраструктура

```bash
cd ..
docker compose up -d
```

RabbitMQ management UI: http://localhost:15672 (demo / demo_secret)

### 2. Seed данных

```bash
psql -h localhost -U demo -d demo -f mock-data/seed.sql
```

### 3. Скрипты для эмуляции потока сообщений

```bash
cd scripts
npm install

# 50 "нормальных" сообщений — имитация штатной работы
node publish-normal.js

# 10 "битых" — уйдут в DLQ: битый JSON, missing fields, unknown counterparty
node publish-broken.js

# Просто смотреть очереди в realtime (полезно для демо)
node watch-queues.js
```

### 4. Импорт воркфлоу в N8N

- Открой http://localhost:5678
- Import → `workflows/01-dlq-consumer.json` и `02-anomaly-detector.json`
- Настрой credentials: RabbitMQ (host: `rabbitmq`, user: `demo`, pass: `demo_secret`), Postgres, Ollama, Mattermost.
- Активируй первый воркфлоу (переключатель справа вверху)

### 5. Демонстрация

Запусти `node publish-broken.js` — через 2-3 секунды увидишь алерты в Mattermost, сгруппированные по причинам.

## Подготовка RabbitMQ (один раз)

Воркфлоу `01-dlq-consumer` подписывается на очередь `integration.dlq`. Создай её через management UI или скриптом:

```bash
cd scripts
node setup-rabbit.js
```

Этот скрипт создаёт:
- Exchange `integration` (topic)
- Queue `integration.main` с bound на `integration.*`
- Queue `integration.dlq` куда падают rejected сообщения
- Dead-letter policy: `integration.main` → `integration.dlq` при nack/expired

## Что должны делать воркфлоу (для Claude Code)

### `01-dlq-consumer.json` — основной обработчик

**Триггер:** RabbitMQ Trigger, очередь `integration.dlq`, ack после обработки.

**Шаги:**
1. RabbitMQ Trigger — читаем сообщение + headers (в headers `x-death` есть причина)
2. Code (JS): парсим payload, извлекаем counterparty_id, doc_type
3. Postgres: `SELECT` контрагента + агрегаты (успешных за час, ошибок за сутки)
4. Ollama: классификатор. Промпт — см. `snippets/SNIPPETS.md`.
5. Postgres: сохраняем в `dlq_handler.dlq_events`
6. Switch по `ai_category`:
   - `our_bug` → HTTP POST в gitlab-mock для создания issue + Mattermost в `#bugs`
   - `partner_data` → Mattermost DM менеджеру клиента (по полю `mattermost_user` контрагента)
   - `infrastructure` → Mattermost в `#ops` + retry (публикуем обратно в `integration.main` через delay)
   - `business_rule` → Mattermost в `#analytics` для аналитика

### `02-anomaly-detector.json` — детектор тишины

**Триггер:** Schedule каждые 15 минут.

**Шаги:**
1. Postgres: `SELECT` — для каждого активного контрагента посчитать кол-во сообщений за последний час
2. Postgres: baseline — среднее за тот же час в предыдущие 4 понедельника (или что-то по timeline)
3. Code: если текущее < baseline - 2σ → аномалия
4. Ollama: человеческое описание + возможные причины
5. Mattermost: алерт в `#integrations`, со ссылкой на контрагента в ЛК

## Подводные камни

1. **RabbitMQ reconnect**: нода RabbitMQ Trigger в N8N теряет соединение при рестарте брокера. Настрой retry в credentials, heartbeat 30s.
2. **Prefetch**: по умолчанию нода читает по одному сообщению. Для демо этого хватит, но в проде повышай prefetch=10-50.
3. **Идемпотентность**: если воркфлоу упадёт после ack'а но до записи в БД — сообщение потеряется. Сохраняй в БД сразу, а ack делай в конце. Или используй manual ack с error-workflow.
4. **Retry и infinite loop**: при ошибке парсинга публикация обратно в `integration.main` создаст loop. Смотри на `x-death` header и считай число retry — после N попыток роутим в `integration.trash`.
5. **PII в логах**: payload из 1С содержит персональные данные. В Code-ноде перед LLM — sanitize: маскируй ИНН, номера телефонов регулярками.

## Критерии успеха демо

- [ ] Публикуем 10 битых сообщений — все попадают в `dlq_events` с непустым `ai_category`
- [ ] В Mattermost приходит сгруппированный алерт (не 10 отдельных сообщений одинаковой ошибки)
- [ ] В `#bugs`, `#ops`, `#analytics` попадают разные типы ошибок
- [ ] Anomaly detector при полной остановке скрипта через 15 минут пишет «контрагент X молчит»
