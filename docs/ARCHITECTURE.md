# Архитектура n8n-demos

## Уровень 1 — физическая раскладка

Всё разворачивается через один `docker compose up` на одной машине. Для демо этого достаточно, для продакшна — см. раздел "Production notes" в конце.

```
+-------------------------------------------------------------+
|  Host machine (docker network: demo-net)                     |
|                                                              |
|  +-----------+  +-----------+  +------------+               |
|  | postgres  |  |  ollama   |  | mattermost |               |
|  | :5432     |  |  :11434   |  |  :8065     |               |
|  +-----------+  +-----------+  +------------+               |
|         |             |               |                      |
|         +-------------+---------------+                      |
|                       |                                      |
|                +------v-------+                              |
|                |     N8N      |                              |
|                |    :5678     |                              |
|                +--------------+                              |
|                                                              |
|  Моки:                                                       |
|  +----------------+  +----------------+                      |
|  | gitlab-mock    |  | cve-feed-mock  |                      |
|  | :4001 (node)   |  | :4002 (node)   |                      |
|  +----------------+  +----------------+                      |
+--------------------------------------------------------------+
```

## Уровень 2 — где что хранится

**Postgres** (одна инстанция, три БД + схемы):
- БД `n8n` — состояние самого N8N (воркфлоу, credentials, executions)
- БД `mattermost` — состояние Mattermost
- БД `demo` — прикладные данные, схемы `cve_watcher.*`, `logistics_assistant.*`

**Ollama volume** (`ollama_data`):
- Модели: qwen2.5:7b (~4.7 GB), qwen2.5-coder:7b (~4.7 GB)
- Итого ~10 GB

**N8N volume** (`n8n_data`):
- Зашифрованные credentials
- Внутренний sqlite для кэша (состояние воркфлоу в postgres)

## Уровень 3 — потоки данных

### Demo-01 CVE Watcher

```
[schedule 2h] --> [n8n: CVE Watcher wf] --> [HTTP -> cve-feed-mock]
                         |
                         +---> [Postgres: найти затронутые репо]
                         +---> [HTTP -> ollama: оценка]
                         +---> [Postgres: save triage]
                         |
                         +---> [Mattermost #security]     (при critical)
                         +---> [HTTP -> gitlab-mock: create issue]   (при update_immediately)
```

**Внешние системы в проде:** GitLab API, GitHub Advisory Database, npm audit API, snyk API.

### Demo-02 Logistics AI Assistant

```
[Mattermost #logistics]
       |  Outgoing Webhook (POST)
       v
[n8n: Webhook /webhook/logistics-ai]
       |
       +---> [Filter bot messages]
       +---> [HTTP -> ollama: generate SQL]
       +---> [Code: validate SQL (whitelist)]
       +---> [Postgres: execute query]
       +---> [HTTP -> ollama: summarize results]
       +---> [Mattermost #logistics: ответ]
```

**Внешние системы в проде:** реальная БД логистики вместо seed-данных, корпоративный Mattermost.

## Production notes (что поменять для реального использования)

| Область | Демо | Продакшн |
|---|---|---|
| N8N deployment | Один контейнер | Queue mode (main + workers через Redis) |
| Postgres | Один инстанс, одна БД для всего | Managed Postgres, раздельные БД для N8N и приложений |
| Ollama | Один инстанс, CPU | Отдельная GPU-нода, load balancer перед несколькими |
| Mattermost | Free team edition | Self-hosted Enterprise или коммерческий тариф |
| Mock servers | node.js в контейнерах | Вырезаются, заменяются реальными GitLab |
| Credentials | Читаются из `.env` | Vault/Doppler с ротацией |
| TLS | Нет | Reverse proxy (nginx/Traefik) с Let's Encrypt |
| Бэкапы N8N | Нет | Ежедневный pg_dump БД n8n + export воркфлоу в Git |

## Уровень 4 — разграничение ответственности

**Что делает N8N:**
- Оркестрация
- Простые трансформации данных (Code-ноды)
- Вызовы LLM
- Маршрутизация уведомлений

**Что НЕ делает N8N (для этого — микросервисы на NestJS):**
- Бизнес-логика ядра продукта
- Хранение первичных данных
- Авторизация и контроль доступа
- Высоконагруженные синхронные API

**Что делают моки (в проде заменяется реальными сервисами):**
- `gitlab-mock` -> реальный GitLab
- `cve-feed-mock` -> GitHub Advisory DB, npm audit API

Это разделение важно: если завтра N8N разонравится — микросервисы останутся работать, а оркестрацию можно будет переписать на что-то другое без касания данных и бизнес-логики.
