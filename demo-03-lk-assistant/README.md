# Demo 03 — LK Assistant

**Цель:** AI-ассистент для личного кабинета клиента, с tool-calling в наши сервисы (mock svc_lk) и RAG по документам клиента. Главное в демо — показать, что это продаётся клиентам как B2B-функционал.

## Что демонстрирует

1. **Tool-calling в микросервисы.** Ассистент понимает запросы в свободной форме и сам решает, какой эндпоинт дёрнуть: «где моя накладная 123» → вызов `GET /invoices?number=123`, «сколько заказов в работе» → `GET /orders?status=in_progress`.
2. **RAG по документам.** В БД загружены документы клиента (инструкции, договоры, регламенты) с эмбеддингами в pgvector. Вопросы вида «какой у нас SLA по ответам на заявки» — ассистент находит релевантный кусок и отвечает с цитатой.
3. **Мультитенантность и изоляция.** Ассистент видит данные только того клиента, от чьего JWT пришёл запрос. Это проверяется на уровне Postgres-запросов (WHERE tenant_id = ...).
4. **Два AI-режима.** Basic (Ollama, внутри контура) и Premium (внешняя модель). Переключатель — поле `ai_tier` у tenant'а.

## Архитектура

```
  ui/index.html (Vue3 чат)
       │ POST /chat { message, jwt }
       ▼
  mock-svc-lk (NestJS :3100)
       ├── /chat → проксирует в N8N webhook
       ├── /orders, /invoices, /integration/status — вызывают БД (данные tenant)
       └── проверяет JWT, прокидывает tenant_id
       │
       ▼ HTTP POST
  N8N webhook  /webhook/lk-assistant
       │
       ▼
  AI Agent (tool-calling)
       ├── tool: get_orders        → HTTP mock-svc-lk
       ├── tool: get_invoices      → HTTP mock-svc-lk
       ├── tool: integration_status→ HTTP mock-svc-lk
       └── tool: search_docs       → Postgres pgvector
       │
       ▼
  Ollama (qwen2.5:7b)  или  внешний LLM (для premium)
```

## Как запустить

### 1. Инфраструктура

```bash
cd ..
docker compose up -d
```

### 2. Seed данных (tenant'ы, заказы, документы)

```bash
psql -h localhost -U demo -d demo -f mock-data/seed.sql
```

### 3. Мок svc_lk

```bash
cd mock-svc-lk
npm install
npm run start:dev
# доступен на http://localhost:3100
# /api/docs — Swagger
```

### 4. Индексация документов (один раз)

Запусти в N8N воркфлоу `02-document-indexer` вручную. Он:
- читает `lk_assistant.documents`
- режет `content` на чанки по ~500 токенов
- для каждого чанка генерит embedding через Ollama (`nomic-embed-text`)
- сохраняет в `lk_assistant.document_chunks`

### 5. Импорт `01-assistant-chat.json` в N8N

Активируй (переключатель справа вверху). Webhook доступен по:
`http://localhost:5678/webhook/lk-assistant`

### 6. Открой UI

```
open ui/index.html
```

Либо раздай через простой static-сервер:
```bash
cd ui && python3 -m http.server 8080
# открой http://localhost:8080
```

В UI есть селектор tenant'а (эмулирует вход под разными клиентами) и галка "Premium режим".

## Сценарии для демо

### Сценарий А — базовые запросы

1. «Где моя накладная INV-2026-0042?» → tool: get_invoices → ответ с деталями
2. «Сколько у меня заказов в работе?» → tool: get_orders с фильтром → ответ с цифрой
3. «Что с обменом данными сегодня?» → tool: integration_status → сводка

### Сценарий Б — RAG по документам

1. «Какой у нас SLA по обработке накладных?» → search_docs → цитата из регламента
2. «Как вернуть товар?» → search_docs → шаги из инструкции

### Сценарий В — изоляция

1. В UI переключись на другого tenant → тот же вопрос → ассистент возвращает данные нового tenant'а.
2. Попробуй в свободной форме запросить данные другого клиента (например, «покажи заказы Ромашки» от имени Петрова) — ассистент должен отказаться, т.к. у него нет доступа.

### Сценарий Г — Premium режим

1. Галка "Premium" → те же запросы летят через внешний LLM (нужен `ANTHROPIC_API_KEY` или `OPENAI_API_KEY` в .env).
2. Разница: быстрее/лучше формулирует, но данные уходят наружу. Это и есть ценностное предложение для клиента, который готов доплатить.

## Что должны делать воркфлоу (для Claude Code)

### `01-assistant-chat.json` — основной чат-ассистент

**Триггер:** Webhook POST `/webhook/lk-assistant`, принимает `{ tenant_id, user_id, role, message, session_id, ai_tier }`.

**Шаги:**
1. **Webhook** — принимает payload + headers с JWT (mock-svc-lk сам верифицирует JWT и прокидывает tenant_id в body — это упрощает демо; в проде JWT верифицируется здесь или в свойствах webhook'а).
2. **Code: validate input** — проверяем обязательные поля, нормализуем.
3. **Postgres: load session history** — последние 10 сообщений из `chat_messages` (опционально, для контекста).
4. **AI Agent (n8n-langchain)** — центральная нода. Настройки:
   - Chat Model: Ollama (если `ai_tier=basic`) или Anthropic/OpenAI (если premium). Выбор — через Switch-ноду перед агентом или через условный параметр.
   - Memory: Postgres Chat Memory (таблица `chat_messages`)
   - System prompt: см. `snippets/SNIPPETS.md`
   - Tools (см. ниже)
5. **Postgres: save response** — сохраняем ответ в `chat_messages`.
6. **Respond to Webhook** — возвращаем `{ answer, tools_used, session_id }`.

**Tools для агента (каждый — отдельная подключённая нода):**

| Tool name | Type | Endpoint / query |
|---|---|---|
| `get_orders` | HTTP Request | `GET http://mock-svc-lk:3100/orders?tenant_id={{tenant_id}}&status={status}` |
| `get_invoices` | HTTP Request | `GET http://mock-svc-lk:3100/invoices?tenant_id={{tenant_id}}&number={number}` |
| `integration_status` | HTTP Request | `GET http://mock-svc-lk:3100/integration/status?tenant_id={{tenant_id}}` |
| `search_documents` | Postgres (Custom Tool) | см. запрос ниже, query-параметр — описание на естественном языке |

**Важно для tool `search_documents`:**
Это не просто SQL-tool — это цепочка из двух шагов, обёрнутая в под-воркфлоу (Sub-workflow):
1. Получаем текст запроса → HTTP POST в Ollama `/api/embed` → получаем вектор 768-dim
2. Postgres: `SELECT chunk_text, document.title FROM lk_assistant.document_chunks JOIN lk_assistant.documents ON ... WHERE tenant_id = $1 ORDER BY embedding <=> $vector LIMIT 5`

### `02-document-indexer.json` — индексация

**Триггер:** Manual + Schedule (каждый час).

**Шаги:**
1. Postgres: `SELECT id, tenant_id, title, content FROM lk_assistant.documents WHERE id NOT IN (SELECT DISTINCT document_id FROM lk_assistant.document_chunks)` — только новые документы.
2. Split In Batches.
3. Code: нарезаем `content` на чанки ~500 токенов с перекрытием 50.
4. Для каждого чанка → HTTP POST Ollama `/api/embed` model=`nomic-embed-text`, prompt=chunk_text → получаем вектор.
5. Postgres INSERT в `document_chunks`.

## Подводные камни

1. **JWT верификация.** В демо я упрощаю — mock-svc-lk верифицирует сам и прокидывает tenant_id в body. В проде N8N-webhook обязательно должен либо сам верифицировать JWT (есть нода), либо принимать запросы только от svc_gateway через internal network.

2. **Galactic leak через tool.** Если агент получит возможность сам формулировать SQL — он может обойти `WHERE tenant_id = ?`. Поэтому все tool'ы принимают параметры, а tenant_id прибивается хардкодом в подзапросе от кода, а не от LLM.

3. **Кэш эмбеддингов.** Если запустишь индексацию много раз — будешь тратить мощность зря. Лучше добавить hash в document_chunks и skip'ать если контент не изменился.

4. **Размер контекста.** Ollama с qwen2.5:7b имеет ограниченное контекстное окно (~8K токенов). Если история чата большая — делай summarization после 10 сообщений (есть нода в langchain).

5. **Галлюцинации на базовой модели.** qwen 7B иногда придумывает несуществующие номера накладных, когда tool возвращает пустой результат. В системном промпте явно пиши: «если tool вернул пустой массив — честно скажи "не найдено"».

## Критерии успеха демо

- [ ] UI открывается, чат работает (хотя бы echo)
- [ ] «Где мой заказ номер X» → ассистент реально дёргает tool и отвечает на основе данных из БД
- [ ] Вопрос по документам → ассистент показывает цитату из правильного документа
- [ ] Переключение tenant → изоляция: не виден никакой чужой контент
- [ ] Переключение Premium → ответ приходит от другого провайдера (видно в execution history)
