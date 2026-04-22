# N8N Demo Platform

Демонстрационный стенд: два сценария автоматизации на базе **N8N** с локальными LLM (Ollama) и мессенджером (Mattermost). Всё поднимается одной командой, работает полностью локально, не требует внешних API-ключей.

---

## Оглавление

- [Что это и зачем](#что-это-и-зачем)
- [Архитектура](#архитектура)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Что происходит при `make init`](#что-происходит-при-make-init)
- [Демо 01 — CVE Watcher](#демо-01--cve-watcher)
- [Демо 02 — Logistics AI](#демо-02--logistics-ai)
- [Сервисы и порты](#сервисы-и-порты)
- [Переменные окружения](#переменные-окружения)
- [Частые проблемы](#частые-проблемы)
- [Структура проекта](#структура-проекта)
- [Безопасность](#безопасность)

---

## Что это и зачем

Стенд показывает, как N8N (low-code оркестратор workflow) решает реальные задачи в IT-компании, разрабатывающей платформу для логистики и ритейла.

| # | Демо | Задача | Статус |
|---|------|--------|--------|
| 01 | [CVE Watcher](./demo-01-cve-watcher) | Мониторинг уязвимостей npm-пакетов во всех репозиториях с AI-оценкой реальной угрозы | Готово |
| 02 | [Logistics AI](./demo-02-logistics-ai) | AI-ассистент для логистических данных: вопрос на естественном языке -> SQL -> ответ | Готово |

Все внешние зависимости заменены моками (GitLab API, CVE-фид) или seed-данными, поэтому стенд полностью автономен.

---

## Архитектура

```
                        +----------------------------------+
                        |         MOCK-СЕРВЕРЫ              |
                        |                                    |
                        |  gitlab-mock (:4001)               |
                        |   +- GET /api/v4/projects          |
                        |   +- GET .../package-lock.json     |
                        |   +- POST .../issues               |
                        |                                    |
                        |  cve-feed-mock (:4002)             |
                        |   +- GET /advisories?since=...     |
                        |   +- POST /__admin__/publish       |
                        +----------------+-----------------  +
                                         |
                                         v
+--------------+              +------------------+              +--------------+
|              |              |                  |              |              |
|  PostgreSQL  |<------------>|      N8N         |<------------>|   Ollama     |
|  (:5432)     |   SQL        |   (:5678)        |   HTTP       |  (:11434)    |
|              |              |                  |              |              |
|  Схемы:      |              |  4 workflow:       |              |  Модели:     |
|  cve_watcher |              |  01-scan           |              |  qwen2.5:7b  |
|  logistics_  |              |  02-cve-watcher    |              |  qwen2.5-    |
|   assistant  |              |  03-weekly-report  |              |  coder:7b    |
|              |              |  04-logistics-ai   |              |              |
+--------------+              +--------+---------+              +--------------+
                                       |
                                       v
                              +------------------+
                              |  Mattermost      |
                              |  (:8065)         |
                              |                  |
                              |  Каналы:         |
                              |  #security       |
                              |  #ops            |
                              |  #logistics      |
                              +------------------+
```

**Стек:** PostgreSQL 16 | Ollama (ROCm/CUDA) | Mattermost Team Edition | Node.js 20 (моки)

---

## Требования

| Что | Минимум | Рекомендуется |
|-----|---------|---------------|
| Docker + Docker Compose | v2.20+ | последняя версия |
| RAM | 8 GB | 16+ GB |
| Диск | 15 GB | 25 GB (модели Ollama ~5 GB) |
| GPU | не обязательно | AMD ROCm / NVIDIA CUDA для Ollama |
| ОС | Linux, macOS, Windows (WSL2) | Linux |
| Утилиты на хосте | `curl`, `jq`, `python3`, `docker` | — |

> **Примечание по GPU:** docker-compose.yml настроен на AMD ROCm (`ollama/ollama:rocm`). Для NVIDIA замените образ на `ollama/ollama` и добавьте `deploy.resources.reservations.devices` с GPU. Для CPU замените образ на `ollama/ollama` — будет работать, но медленнее (7B модель ~10 сек/ответ на CPU vs ~1 сек на GPU).

---

## Быстрый старт

```bash
# 1. Клонируйте репозиторий
git clone <repo-url> && cd n8n-demos

# 2. Запустите всё одной командой
make init
```

`make init` делает всё: генерирует `.env`, поднимает контейнеры, настраивает Mattermost (админ, команда, каналы, бот), импортирует credentials и workflows в n8n.

После завершения (3-5 минут при первом запуске) на экране появятся адреса:

```
Mattermost  : http://localhost:8065  (admin / Demo_secret1)
N8N         : http://localhost:5678
Postgres    : localhost:5432          (demo / demo_secret)
Ollama      : http://localhost:11434
GitLab mock : http://localhost:4001
CVE feed    : http://localhost:4002
```

### Другие команды

```bash
make up       # поднять сервисы (без инициализации)
make down     # остановить
make clean    # остановить + удалить все данные (volumes, .env)
make logs     # логи всех сервисов
make status   # состояние контейнеров
```

---

## Что происходит при `make init`

1. **Генерация `.env`** из `.env.example` + случайный `N8N_ENCRYPTION_KEY` через `openssl rand`
2. **`docker compose up -d`** — поднимает все контейнеры (Postgres, n8n, Mattermost, Ollama, моки)
3. **Ollama bootstrap** — контейнер `ollama-bootstrap` скачивает модели `qwen2.5:7b`, `qwen2.5-coder:7b` (при первом запуске — ~5 GB)
4. **Mattermost bootstrap** (`shared/mattermost-bootstrap.sh`) — через REST API Mattermost:
   - Создаёт admin-пользователя
   - Создаёт команду `demo`
   - Создаёт каналы: `#security`, `#ops`, `#logistics`
   - Создаёт бота `n8n-bot` и генерирует токен
   - Добавляет бота во все каналы
   - Токен бота записывается в `.env`
5. **N8N bootstrap** (`shared/n8n-bootstrap.sh`) — через Docker CLI:
   - Импортирует credentials: Postgres, Mattermost (с токеном бота)
   - Патчит workflow JSON: заменяет `CONFIGURE_CHANNEL_ID` на реальные ID каналов Mattermost
   - Загружает seed-данные (контрагенты для demo-02)
   - Настраивает Outgoing Webhook в Mattermost для #logistics -> n8n
   - Импортирует все workflows из `demo-01` и `demo-02`
   - Фиксит `triggerCount` в БД n8n (баг CLI-импорта)

---

## Демо 01 — CVE Watcher

**Задача:** Автоматический мониторинг уязвимостей npm-пакетов во всех репозиториях компании с AI-оценкой реальной угрозы.

**Проблема:** У компании 5+ репозиториев (NestJS-бэкенды, Vue3-фронтенд). Каждый тянет десятки npm-пакетов. Уязвимости публикуются ежедневно. Вручную отслеживать — нереально. А большинство CVE для нас неактуальны (например, уязвимость в XML-парсере, а мы им не пользуемся).

### Три workflow

#### 01 — Inventory Scan
Сканирует все репозитории, парсит `package-lock.json`, строит единую таблицу зависимостей.

```
Manual Trigger / Schedule (03:00)
  -> List Repos (GitLab API)
  -> Upsert Repos (Postgres)
  -> Fetch package-lock.json
  -> Parse Lock (JS: извлекает name + version)
  -> Upsert Dependencies (Postgres)
  -> Aggregate Results
  -> Update Scan Times
  -> Notify #ops: "Сканирование завершено. 5 репо, 22 пакета."
```

#### 02 — CVE Watcher
Каждые 2 часа проверяет CVE-фид, находит затронутые репозитории, запрашивает AI-оценку угрозы.

```
Manual Trigger / Schedule (каждые 2ч)
  -> Get Last Seen (Postgres: MAX published_at)
  -> Fetch Advisories (CVE feed mock)
  -> Extract & Save Advisories
  -> Find Affected Dependencies (Postgres JOIN)
  -> Semver Filter (JS + semver: version in affected_range?)
  -> Aggregate by Advisory
  -> Build AI Prompt -> Ollama Triage (qwen2.5-coder:7b)
  -> Parse AI Response (severity, action, reasoning)
  -> Save Triage (Postgres)
  -> Switch on recommended_action:
      +- update_immediately -> Alert #security + Create GitLab Issue
      +- update_in_sprint   -> Notify #ops
      +- monitor/ignore     -> Log Only
```

**Пример AI-оценки:** CVE в `fast-xml-parser` (severity: critical). AI видит, что пакет используется в `svc_integration` и парсит XML от внешних партнёров -> подтверждает critical, рекомендует `update_immediately`.

#### 03 — Weekly Report
Еженедельная сводка: сколько CVE обработано, сколько критических, общий статус.

```
Manual Trigger / Schedule (пятница 16:00)
  -> Aggregate Stats (Postgres)
  -> Ollama Summary (qwen2.5:7b)
  -> Format Report
  -> Send to #ops
```

### Как запустить демо

1. Откройте http://localhost:5678 (n8n UI)
2. Перейдите в "01 — Inventory Scan"
3. Нажмите Manual Trigger -> Execute
4. Дождитесь завершения (заполнит таблицу зависимостей)
5. Перейдите в "02 — CVE Watcher"
6. Нажмите Manual Trigger -> Execute
7. Посмотрите результат:
   - В Mattermost (#security, #ops) — алерты с AI-оценкой
   - В БД: `SELECT * FROM cve_watcher.ai_triage;`

### Моковые данные

**5 репозиториев** (GitLab mock):
| Репо | Уязвимые пакеты |
|------|-----------------|
| svc_gateway | lodash 4.17.15 (prototype pollution) |
| ui_platform | axios 1.6.0 (CSRF) |
| svc_integration | fast-xml-parser 4.2.4 (XXE) |
| svc_lk | все версии безопасны |
| svc_notify | нет затронутых пакетов |

**3 advisory** (CVE feed mock):
| CVE | Пакет | Range | Severity |
|-----|-------|-------|----------|
| GHSA-demo-lodash-4lik | lodash | <4.17.21 | high |
| GHSA-demo-axios-9824 | axios | >=1.0.0 <1.6.2 | medium |
| GHSA-demo-xmlparser-7g2p | fast-xml-parser | <4.4.0 | critical |

---

## Демо 02 — Logistics AI

**Задача:** AI-ассистент для логистической платформы. Пользователь задаёт вопрос на естественном языке в Mattermost — получает ответ из базы данных.

**Проблема:** Менеджеры и дежурные инженеры тратят время на ручные SQL-запросы к БД логистики или ждут отчёт от аналитика. AI-ассистент позволяет задать вопрос в чате и получить ответ за секунды.

### Один workflow

#### 01 — Logistics AI Assistant
Слушает канал `#logistics` через Outgoing Webhook. Генерирует SQL, валидирует, выполняет, формирует ответ.

```
Mattermost #logistics (Outgoing Webhook)
  -> Webhook (n8n)
  -> Filter Bot Messages (отсечь свои сообщения)
  -> Check Help (помощь / /help?)
      +- true  -> Send Help
      +- false -> Generate SQL (Ollama qwen2.5:7b)
                   -> Validate SQL (SELECT-only, whitelist, LIMIT 50)
                   -> Check Validation
                       +- valid   -> Execute Query (Postgres)
                       |             -> Prepare Analysis
                       |             -> Analyze Result (Ollama)
                       |             -> Send Answer
                       +- invalid -> Send Validation Error
```

### Как запустить демо

1. Откройте http://localhost:8065 (Mattermost)
2. Перейдите в канал **#logistics**
3. Напишите: `Покажи все счета от Ромашки`
4. Дождитесь ответа (10-30 сек)

**Примеры вопросов:**
- "Покажи все счета от Ромашки"
- "Какие ошибки интеграции за последнюю неделю?"
- "Статус обмена данными с Быстрая Доставка"
- "Сколько счетов в статусе error?"

### Моковые данные

**5 контрагентов** и связанные данные: 8 счетов, 8 записей обмена данными, 8 логов интеграции. Подробнее: [demo-02-logistics-ai/README.md](./demo-02-logistics-ai/README.md).

---

## Сервисы и порты

| Сервис | Контейнер | Порт | Назначение |
|--------|-----------|------|------------|
| N8N | demo-n8n | 5678 | UI оркестратора workflow |
| PostgreSQL | demo-postgres | 5432 | Основная БД (demo) + БД n8n + БД Mattermost |
| Mattermost | demo-mattermost | 8065 | Мессенджер для уведомлений |
| Ollama | demo-ollama | 11434* | Локальные LLM (qwen2.5) |
| GitLab mock | demo-cve-mocks | 4001 | Эмуляция GitLab API (5 репозиториев) |
| CVE feed mock | demo-cve-mocks | 4002 | Эмуляция GitHub Advisory Database |

> \* Порт Ollama не маппится на хост, если нативный Ollama уже запущен. Внутри docker-сети доступен как `ollama:11434`.

---

## Переменные окружения

Файл `.env` генерируется автоматически из `.env.example` при `make init`.

| Переменная | Значение по умолчанию | Описание |
|------------|----------------------|----------|
| `N8N_ENCRYPTION_KEY` | (генерируется) | Ключ шифрования credentials в n8n |
| `MATTERMOST_BOT_TOKEN` | (генерируется) | Токен бота n8n-bot в Mattermost |
| `OLLAMA_MODEL_CHAT` | `qwen2.5:7b` | Модель для общих задач (triage, саммари) |
| `OLLAMA_MODEL_CODE` | `qwen2.5-coder:7b` | Модель для анализа кода и CVE |
| `MM_ADMIN_USER` | `admin` | Логин админа Mattermost |
| `MM_ADMIN_PASS` | `Demo_secret1` | Пароль админа Mattermost |

---

## Частые проблемы

### Ollama не стартует (port 11434 already in use)

У вас запущен нативный Ollama на хосте. Два варианта:
- Остановить нативный: `sudo systemctl stop ollama`
- Оставить как есть: контейнерный Ollama поднимется без порта на хосте, но будет доступен внутри docker-сети как `ollama:11434`. N8N workflow будут работать.

### Workflow не выполняется дальше триггера

`triggerCount = 0` в БД n8n (баг CLI-импорта). Фиксится автоматически при `make init`. Если пересоздали вручную:

```sql
-- Выполнить в БД n8n (localhost:5432, database: n8n)
UPDATE workflow_entity
SET "triggerCount" = 2
WHERE "triggerCount" = 0;
```

### "User attempted to access a workflow without permissions"

Stale cookies от предыдущей сессии n8n. Откройте n8n в инкогнито-окне.

### Ollama отвечает долго (>30 сек)

На CPU модель 7B генерирует ~10 токенов/сек. Для комфортного демо нужен GPU. Или используйте модель поменьше: установите `OLLAMA_MODEL_CHAT=qwen2.5:3b` в `.env`.

---

## Структура проекта

```
n8n-demos/
+-- docker-compose.yml           # Все сервисы (Postgres, n8n, Mattermost, Ollama, моки)
+-- Makefile                     # make init / up / down / clean / logs / status
+-- .env.example                 # Шаблон переменных окружения
|
+-- shared/                      # Общие скрипты и конфигурация
|   +-- init-db.sql              # Инициализация БД: схемы cve_watcher, logistics_assistant
|   +-- mattermost-bootstrap.sh  # Автонастройка Mattermost (админ, команда, каналы, бот)
|   +-- n8n-bootstrap.sh         # Импорт credentials, workflows, seed-данных
|   +-- ollama-bootstrap.sh      # Загрузка моделей в Ollama
|   +-- error-handler.json       # Общий error workflow для n8n
|
+-- demo-01-cve-watcher/
|   +-- workflows/
|   |   +-- 01-inventory-scan.json    # Сканирование зависимостей
|   |   +-- 02-cve-watcher.json       # Поиск и оценка CVE
|   |   +-- 03-weekly-report.json     # Еженедельная сводка
|   +-- mock-servers/
|   |   +-- index.js                  # GitLab API mock (:4001) + CVE feed mock (:4002)
|   |   +-- Dockerfile
|   |   +-- package.json
|   +-- mock-data/
|       +-- repos.sql
|
+-- demo-02-logistics-ai/
|   +-- workflows/
|   |   +-- 01-logistics-ai.json      # AI-ассистент: вопрос -> SQL -> ответ
|   +-- mock-data/
|   |   +-- seed.sql                  # 5 контрагентов, счета, обмены, логи
|   +-- snippets/
|       +-- SNIPPETS.md
|
+-- docs/
    +-- ARCHITECTURE.md
    +-- CLAUDE.md
    +-- SECURITY.md
```

---

## Безопасность

Всё окружение — **демонстрационное**, не для продакшена.

- Пароли статичные и хранятся в `.env` / `.env.example`
- N8N доступен без SSL и аутентификации
- Postgres без TLS
- Ollama без авторизации
- PII в тестовых данных — вымышленные

**Перед показом на внешней машине** минимум смените пароли в `.env` и ограничьте доступ по сети.

Подробнее: [docs/SECURITY.md](./docs/SECURITY.md)
