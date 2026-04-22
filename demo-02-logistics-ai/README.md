# Demo 02 — Logistics AI Assistant

AI-ассистент для логистической платформы. Пользователь задаёт вопрос на естественном языке в Mattermost → LLM генерирует SQL → валидатор проверяет → PostgreSQL выполняет → LLM формирует ответ на человеческом языке.

## Задача

У компании есть данные по контрагентам, счетам, обменам документами и логам интеграций. Менеджеры и дежурные инженеры тратят время на ручные SQL-запросы или ждут отчёт от аналитика. AI-ассистент позволяет задать вопрос в чате и получить ответ за секунды.

## Архитектура

```
Mattermost #logistics
       |
       | Outgoing Webhook (POST)
       v
n8n Webhook (/webhook/logistics-ai)
       |
       +---> Filter Bot Messages (отсечь свои сообщения)
       +---> Check Help (помощь / /help?)
       |        |
       |     [Send Help]
       |
       +---> Generate SQL (Ollama qwen2.5:7b)
       +---> Validate SQL (JS: SELECT-only, whitelist таблиц, LIMIT 50)
       |        |
       |     [Send Validation Error] (если невалидный)
       |
       +---> Execute Query (PostgreSQL)
       +---> Prepare Analysis (форматирование для LLM)
       +---> Analyze Result (Ollama qwen2.5:7b)
       +---> Send Answer (Mattermost #logistics)
```

## Как запустить

Демо запускается автоматически при `make init` в корне проекта. После завершения:

1. Откройте Mattermost: http://localhost:8065 (admin / Demo_secret1)
2. Перейдите в канал **#logistics**
3. Задайте вопрос, например: `Покажи все счета от Ромашки`
4. Дождитесь ответа (10-30 сек, зависит от GPU/CPU)

### Примеры вопросов

- "Покажи все счета от Ромашки"
- "Какие ошибки интеграции за последнюю неделю?"
- "Статус обмена данными с Быстрая Доставка"
- "Сколько счетов в статусе error?"
- "Какие контрагенты есть в системе?"

### Проверка через SQL

```sql
-- Контрагенты
SELECT * FROM logistics_assistant.counterparties;

-- Счета
SELECT i.number, i.amount, i.status, c.name
FROM logistics_assistant.invoices i
JOIN logistics_assistant.counterparties c ON c.id = i.counterparty_id;

-- Ошибки интеграции
SELECT * FROM logistics_assistant.integration_logs WHERE level = 'error';

-- Обмен данными с ошибками
SELECT de.*, c.name FROM logistics_assistant.data_exchanges de
JOIN logistics_assistant.counterparties c ON c.id = de.counterparty_id
WHERE de.status = 'error';
```

## Моковые данные

### 5 контрагентов

| Контрагент | ИНН |
|-----------|-----|
| ООО "Ромашка Логистик" | 7701234567 |
| ИП Петров А.В. | 770987654321 |
| АО "ТрансГруз" | 7712345678 |
| ООО "Складсервис" | 7798765432 |
| ООО "Быстрая Доставка" | 7745678901 |

### 8 счетов

| Номер | Контрагент | Сумма | Статус |
|-------|-----------|-------|--------|
| INV-2026-001 | Ромашка Логистик | 150 000 | processed |
| INV-2026-002 | Ромашка Логистик | 87 500 | pending |
| INV-2026-003 | Ромашка Логистик | 220 000 | error |
| INV-2026-010 | Петров А.В. | 45 000 | processed |
| INV-2026-020 | ТрансГруз | 310 000 | processed |
| INV-2026-021 | ТрансГруз | 95 000 | pending |
| INV-2026-030 | Складсервис | 62 000 | processed |
| INV-2026-040 | Быстрая Доставка | 178 000 | error |

## Безопасность: SQL-валидатор

LLM-сгенерированный SQL проходит через строгий валидатор перед выполнением:

1. **SELECT-only** — блокирует DROP, DELETE, UPDATE, INSERT, ALTER, TRUNCATE, CREATE, GRANT, REVOKE, EXEC
2. **Whitelist таблиц** — разрешены только 4 таблицы схемы `logistics_assistant`
3. **Auto-LIMIT** — добавляет `LIMIT 50` если не указан
4. **Auto-prefix** — дописывает `logistics_assistant.` к голым именам таблиц

Если LLM сгенерирует невалидный запрос, пользователь получит сообщение с описанием ошибки и предложением переформулировать вопрос.
