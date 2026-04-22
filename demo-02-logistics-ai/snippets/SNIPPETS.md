# Snippets — Demo 02: Logistics AI Assistant

Готовые промпты и JS-код для нод workflow.

---

## System prompt: генерация SQL

Используется в ноде **Generate SQL** (HTTP Request → Ollama).

```
Ты — ассистент для логистической IT-платформы. Твоя задача — преобразовать вопрос пользователя в SQL-запрос к PostgreSQL.

Схема базы данных:

Таблица: logistics_assistant.counterparties (id SERIAL, name TEXT, inn TEXT, created_at TIMESTAMP)
Таблица: logistics_assistant.invoices (id SERIAL, counterparty_id INT REFERENCES logistics_assistant.counterparties(id), number TEXT, amount NUMERIC, status TEXT, created_at TIMESTAMP)
Таблица: logistics_assistant.integration_logs (id SERIAL, service TEXT, level TEXT, message TEXT, payload JSONB, created_at TIMESTAMP)
Таблица: logistics_assistant.data_exchanges (id SERIAL, counterparty_id INT REFERENCES logistics_assistant.counterparties(id), direction TEXT, doc_type TEXT, status TEXT, error_message TEXT, created_at TIMESTAMP)

Правила:
1. Генерируй ТОЛЬКО SELECT-запросы
2. Всегда добавляй LIMIT 50
3. Для поиска по имени используй ILIKE с %
4. Для дат по умолчанию бери последние 7 дней: created_at >= NOW() - INTERVAL '7 days'
5. Возвращай ТОЛЬКО SQL-запрос, без пояснений, без markdown, без ```
6. Всегда используй полные имена таблиц с префиксом схемы logistics_assistant.
7. Если вопрос про ошибки интеграции — ищи в logistics_assistant.integration_logs и logistics_assistant.data_exchanges
8. Если вопрос про контрагента — ищи в logistics_assistant.counterparties, logistics_assistant.invoices и logistics_assistant.data_exchanges
```

---

## System prompt: анализ результатов

Используется в ноде **Prepare Analysis** (Code node формирует payload для Ollama).

```
Ты — ассистент для логистической IT-платформы. Тебе дан вопрос клиента и результат SQL-запроса к базе данных. Дай понятный ответ на русском языке.

Правила:
1. Отвечай кратко и по делу
2. Если данные найдены — опиши что нашлось, укажи ключевые цифры
3. Если данных нет — скажи что не найдено и предложи что проверить
4. Если видишь ошибки — укажи на возможную причину и на чьей стороне проблема
5. Не показывай SQL-запрос
6. Не используй markdown-форматирование (жирный, курсив) — только простой текст
```

---

## JS: фильтр bot-сообщений

Нода **Filter Bot Messages** — отсекает сообщения от самого бота (предотвращает зацикливание) и пустые сообщения.

```javascript
const body = $input.first().json.body;

if (!body || !body.text) return [];
if (body.user_name === 'n8n-bot') return [];

const text = body.text.trim();
if (!text) return [];

return [{ json: { text, user_name: body.user_name, channel_id: body.channel_id } }];
```

---

## JS: валидатор SQL

Нода **Validate SQL** — проверяет что LLM сгенерировал безопасный SELECT, таблицы в whitelist, добавляет LIMIT. Авто-префиксит голые имена таблиц схемой `logistics_assistant.`.

```javascript
const rawContent = $input.first().json.message.content;

const sql = rawContent
  .replace(/```sql\n?/g, '')
  .replace(/```\n?/g, '')
  .trim();

const upper = sql.toUpperCase();

const FORBIDDEN_KEYWORDS = [
  'DROP', 'DELETE', 'UPDATE', 'INSERT', 'ALTER',
  'TRUNCATE', 'CREATE', 'GRANT', 'REVOKE', 'EXEC'
];

const ALLOWED_TABLES = [
  'logistics_assistant.counterparties',
  'logistics_assistant.invoices',
  'logistics_assistant.integration_logs',
  'logistics_assistant.data_exchanges',
  'counterparties', 'invoices', 'integration_logs', 'data_exchanges'
];

if (!upper.startsWith('SELECT')) {
  return [{ json: { valid: false, error: 'Запрос должен начинаться с SELECT', sql } }];
}

for (const kw of FORBIDDEN_KEYWORDS) {
  const regex = new RegExp(`\\b${kw}\\b`, 'i');
  if (regex.test(sql)) {
    return [{ json: { valid: false, error: `Обнаружена запрещённая команда: ${kw}`, sql } }];
  }
}

const tableMatches = sql.match(/(?:FROM|JOIN)\s+([\w]+\.[\w]+|[\w]+)/gi) || [];
const BARE_NAMES = ['counterparties', 'invoices', 'integration_logs', 'data_exchanges'];
for (const match of tableMatches) {
  const table = match.replace(/(?:FROM|JOIN)\s+/i, '').toLowerCase();
  if (!ALLOWED_TABLES.includes(table)) {
    return [{ json: { valid: false, error: `Таблица '${table}' не в списке разрешённых`, sql } }];
  }
}

// Авто-префикс для голых имён таблиц
let finalSql = sql.replace(/;\s*$/, '');
for (const bare of BARE_NAMES) {
  const re = new RegExp(`(?<=FROM|JOIN)\\s+(?!logistics_assistant\\.)${bare}\\b`, 'gi');
  finalSql = finalSql.replace(re, ` logistics_assistant.${bare}`);
}

if (!upper.includes('LIMIT')) {
  finalSql += ' LIMIT 50';
}

return [{ json: { valid: true, sql: finalSql } }];
```

---

## JS: подготовка анализа

Нода **Prepare Analysis** — формирует payload для Ollama: вопрос пользователя + результат SQL в JSON.

```javascript
const question = $('Filter Bot Messages').item.json.text;
const rows = $('Execute Query').all().map(item => item.json);
const resultJson = JSON.stringify(rows, null, 2);

const userMessage = `Вопрос клиента: ${question}\n\nРезультат запроса к БД (JSON):\n${resultJson}`;

return [{
  json: {
    model: 'qwen2.5:7b',
    messages: [
      {
        role: 'system',
        content: 'Ты — ассистент для логистической IT-платформы...' // см. промпт выше
      },
      {
        role: 'user',
        content: userMessage
      }
    ],
    stream: false,
    keep_alive: '30m',
    options: { temperature: 0.1 }
  }
}];
```

---

## Тестовые curl-запросы

Проверка webhook напрямую (эмуляция Mattermost outgoing webhook):

```bash
# Обычный вопрос
curl -X POST http://localhost:5678/webhook/logistics-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"Покажи все счета от Ромашки","user_name":"testuser","channel_id":"test"}'

# Помощь
curl -X POST http://localhost:5678/webhook/logistics-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"помощь","user_name":"testuser","channel_id":"test"}'

# Попытка SQL injection (должна быть отклонена валидатором)
curl -X POST http://localhost:5678/webhook/logistics-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"DELETE FROM counterparties","user_name":"testuser","channel_id":"test"}'
```
