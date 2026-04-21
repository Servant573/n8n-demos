# Архитектура n8n-demos

## Уровень 1 — физическая раскладка

Всё разворачивается через один `docker compose up` на одной машине. Для демо этого достаточно, для продакшна — см. раздел "Production notes" в конце.

```
┌─────────────────────────────────────────────────────────────────┐
│  Host machine (docker network: demo-net)                        │
│                                                                 │
│  ┌───────────┐  ┌───────────┐  ┌────────────┐  ┌────────────┐ │
│  │ postgres  │  │  ollama   │  │ mattermost │  │  rabbitmq  │ │
│  │ :5432     │  │  :11434   │  │  :8065     │  │  :5672     │ │
│  │ pgvector  │  │  qwen2.5  │  │            │  │  :15672 UI │ │
│  └───────────┘  └───────────┘  └────────────┘  └────────────┘ │
│         │             │               │              │         │
│         └─────────────┴───────────────┴──────────────┘         │
│                              │                                 │
│                       ┌──────▼───────┐                         │
│                       │     N8N      │                         │
│                       │    :5678     │                         │
│                       └──────────────┘                         │
│                                                                 │
│  Моки, запускаемые по необходимости:                            │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐ │
│  │ gitlab-mock    │  │ cve-feed-mock  │  │ mock-svc-lk      │ │
│  │ :4001 (node)   │  │ :4002 (node)   │  │ :3100 (NestJS)   │ │
│  └────────────────┘  └────────────────┘  └──────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

Моки запускаются отдельно от docker-compose (не в контейнерах), чтобы:
- можно было перезапускать без влияния на основную инфру
- проще дебажить (логи прямо в терминале)
- можно было редактировать код на лету

## Уровень 2 — где что хранится

**Postgres** (одна инстанция, три БД + схемы):
- БД `n8n` — состояние самого N8N (воркфлоу, credentials, executions)
- БД `mattermost` — состояние Mattermost
- БД `demo` — прикладные данные всех демо, разделены по схемам:
  - `cve_watcher.*` — для demo-01
  - `dlq_handler.*` — для demo-02
  - `lk_assistant.*` — для demo-03 (включает pgvector)

**Ollama volume** (`ollama_data`):
- Модели: qwen2.5:7b (~4.7 GB), qwen2.5-coder:7b (~4.7 GB), nomic-embed-text (~270 MB)
- Итого ~10 GB

**N8N volume** (`n8n_data`):
- Зашифрованные credentials
- Внутренний sqlite для кэша (состояние воркфлоу в postgres)

## Уровень 3 — потоки данных по демо

### Demo-01 CVE Watcher

```
[schedule 2h] ──► [n8n: CVE Watcher wf] ──► [HTTP → cve-feed-mock]
                         │
                         ├──► [Postgres: найти затронутые репо]
                         ├──► [HTTP → ollama: оценка]
                         ├──► [Postgres: save triage]
                         │
                         ├──► [Mattermost #security]     (при critical)
                         └──► [HTTP → gitlab-mock: create issue]   (при update_immediately)
```

**Внешние системы в проде:** GitLab API, GitHub Advisory Database, npm audit API, snyk API.

### Demo-02 DLQ Handler

```
[1C] ──► [RabbitMQ: integration.main] ──TTL/nack──► [integration.dlq]
                                                           │
                                                           ▼
                              [n8n: DLQ Consumer wf (active listener)]
                                                           │
               ┌───────────────────────────────────────────┤
               ├──► [Postgres: load counterparty + stats]  │
               ├──► [Sanitize PII]                         │
               ├──► [HTTP → ollama: classify]              │
               ├──► [Postgres: save dlq_events]            │
               │                                            │
               └──► switch:                                 │
                     ├─ our_bug       → gitlab issue + Mattermost #bugs
                     ├─ partner_data  → Mattermost DM manager
                     ├─ infrastructure→ Mattermost #ops
                     └─ business_rule → Mattermost #analytics
```

### Demo-03 LK Assistant

```
[browser UI :8080]
       │ fetch POST /chat (с Bearer JWT)
       ▼
[mock-svc-lk :3100]
       │   ├─ parse JWT → tenant_id, user_id, role
       │   ├─ lookup tenants.ai_tier из БД (НЕ доверяем клиенту)
       │   └─ proxy в N8N webhook
       ▼
[n8n: webhook /webhook/lk-assistant]
       │
       ├─► switch on ai_tier
       │      ├─ basic  → [AI Agent + Ollama qwen2.5:7b]
       │      └─ premium → [AI Agent + Anthropic/OpenAI]
       │
       │   agent имеет tools:
       │      ├─ get_orders       → HTTP → mock-svc-lk  (с forward JWT)
       │      ├─ get_invoices     → HTTP → mock-svc-lk
       │      ├─ integration_status → HTTP → mock-svc-lk
       │      └─ search_documents → sub-workflow:
       │                              ├─ ollama /api/embed
       │                              └─ pgvector SELECT в lk_assistant
       │
       └─► [Postgres: save chat_messages]
       │
       ▼ response
[mock-svc-lk :3100] ──► [browser UI]
```

## Уровень 4 — как демо связаны между собой

Хорошая новость: связаны слабо. Запуск одного демо не зависит от других, за исключением:

1. **demo-03 опционально читает данные demo-02.** Endpoint `/integration/status` в mock-svc-lk смотрит в `dlq_handler.dlq_events`, чтобы показать статус интеграций пользователю. Если demo-02 не развёрнуто — возвращает "healthy" по умолчанию.
2. **Общая Postgres.** Все демо используют одну инстанцию БД (разные схемы). Это упрощает жизнь, но означает, что полный reset — это `docker volume rm demo-n8n-demos_pgdata` и пересоздание всего.

## Production notes (что поменять для реального использования)

| Область | Демо | Продакшн |
|---|---|---|
| N8N deployment | Один контейнер | Queue mode (main + workers через Redis) |
| Postgres | Один инстанс, одна БД для всего | Managed Postgres, раздельные БД для N8N и приложений |
| Ollama | Один инстанс, CPU | Отдельная GPU-нода, load balancer перед несколькими |
| Mattermost | Free team edition | Self-hosted Enterprise или коммерческий тариф |
| RabbitMQ | Single node | Cluster (минимум 3 ноды) с репликой очередей |
| JWT | base64-обёрнутый JSON | Полноценная подпись через svc_gateway, верификация в N8N webhook |
| Mock servers | node.js локально | Вырезаются, заменяются реальными GitLab/1С/svc_lk |
| Credentials | Читаются из `.env` | Vault/Doppler с ротацией |
| TLS | Нет | Reverse proxy (nginx/Traefik) с Let's Encrypt |
| Бэкапы N8N | Нет | Ежедневный pg_dump БД n8n + export воркфлоу в Git |

## Уровень 5 — разграничение ответственности

**Что делает N8N:**
- Оркестрация
- Простые трансформации данных (Code-ноды)
- Вызовы LLM
- Маршрутизация уведомлений

**Что НЕ делает N8N (для этого — микросервисы на NestJS):**
- Бизнес-логика ядра продукта
- Хранение первичных данных
- Авторизация и контроль доступа (этим занимается svc_gateway; N8N — потребитель JWT)
- Высоконагруженные синхронные API

**Что делают моки (в проде заменяется реальными сервисами):**
- `gitlab-mock` → реальный GitLab
- `cve-feed-mock` → GitHub Advisory DB, npm audit API
- `mock-svc-lk` → svc_lk в существующей платформе

Это разделение важно: если завтра N8N разонравится — микросервисы останутся работать, а оркестрацию можно будет переписать на что-то другое без касания данных и бизнес-логики.
