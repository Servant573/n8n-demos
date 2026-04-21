-- ============================================================================
-- Инициализация БД для всех демо-проектов.
-- Выполняется один раз при первом запуске postgres.
-- ============================================================================

-- Отдельные БД для инфраструктурных сервисов (изоляция)
CREATE DATABASE n8n;
CREATE DATABASE mattermost;

-- Основная demo-БД остаётся "demo", в ней — схемы для каждого демо.
\c demo;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector для RAG в demo-03

-- ============================================================================
-- SCHEMA: cve_watcher (для demo-01)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS cve_watcher;

-- Реестр репозиториев (эмуляция выдачи GitLab API)
CREATE TABLE cve_watcher.repositories (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,
    url          TEXT NOT NULL,
    default_branch TEXT NOT NULL DEFAULT 'main',
    last_scanned_at TIMESTAMPTZ
);

-- Инвентарь зависимостей: что в каком репо в какой версии
CREATE TABLE cve_watcher.dependencies (
    id           SERIAL PRIMARY KEY,
    repo_id      INT NOT NULL REFERENCES cve_watcher.repositories(id) ON DELETE CASCADE,
    package_name TEXT NOT NULL,
    version      TEXT NOT NULL,
    is_direct    BOOLEAN NOT NULL DEFAULT false,
    scanned_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (repo_id, package_name, version)
);
CREATE INDEX idx_deps_package ON cve_watcher.dependencies (package_name);

-- Advisories (CVE), которые мы уже видели
CREATE TABLE cve_watcher.advisories (
    id                SERIAL PRIMARY KEY,
    cve_id            TEXT NOT NULL UNIQUE,      -- например "GHSA-xxxx-xxxx"
    package_name      TEXT NOT NULL,
    affected_versions TEXT NOT NULL,             -- semver range, напр. ">=1.0.0 <1.4.2"
    severity          TEXT NOT NULL,             -- "low"/"medium"/"high"/"critical"
    description       TEXT,
    published_at      TIMESTAMPTZ NOT NULL,
    discovered_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Результаты AI-оценки: что реально актуально для нас
CREATE TABLE cve_watcher.ai_triage (
    id                    SERIAL PRIMARY KEY,
    advisory_id           INT NOT NULL REFERENCES cve_watcher.advisories(id),
    affected_repos        INT[] NOT NULL,        -- массив repo_id
    real_severity         TEXT NOT NULL,
    is_exploitable        BOOLEAN NOT NULL,
    reasoning             TEXT,
    recommended_action    TEXT NOT NULL,
    summary_ru            TEXT,
    ai_model              TEXT NOT NULL,
    triaged_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- SCHEMA: dlq_handler (для demo-02)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS dlq_handler;

CREATE TABLE dlq_handler.counterparties (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    inn          TEXT NOT NULL UNIQUE,
    amqp_queue   TEXT NOT NULL,  -- имя очереди этого контрагента
    manager_email TEXT,
    mattermost_user TEXT
);

-- Лог обработанных DLQ-событий
CREATE TABLE dlq_handler.dlq_events (
    id                 SERIAL PRIMARY KEY,
    counterparty_id    INT REFERENCES dlq_handler.counterparties(id),
    original_queue     TEXT NOT NULL,
    original_payload   JSONB NOT NULL,
    error_headers      JSONB NOT NULL,
    ai_category        TEXT,                    -- our_bug / partner_data / infrastructure / business_rule
    ai_severity        TEXT,
    ai_summary_ru      TEXT,
    ai_action          TEXT,                    -- retry / manual_review / escalate / ignore
    routing_target     TEXT,                    -- куда улетело уведомление
    processed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_dlq_counterparty ON dlq_handler.dlq_events (counterparty_id);
CREATE INDEX idx_dlq_processed_at ON dlq_handler.dlq_events (processed_at DESC);

-- ============================================================================
-- SCHEMA: lk_assistant (для demo-03)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS lk_assistant;

-- Имитация tenant'ов (клиентов нашей платформы)
CREATE TABLE lk_assistant.tenants (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    ai_tier     TEXT NOT NULL DEFAULT 'basic'  -- 'basic' (Ollama) | 'premium' (внешний LLM)
);

CREATE TABLE lk_assistant.users (
    id          SERIAL PRIMARY KEY,
    tenant_id   INT NOT NULL REFERENCES lk_assistant.tenants(id),
    username    TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'operator',  -- operator / manager / admin
    UNIQUE (tenant_id, username)
);

-- Пример бизнес-данных, к которым обращается ассистент
CREATE TABLE lk_assistant.orders (
    id             SERIAL PRIMARY KEY,
    tenant_id      INT NOT NULL REFERENCES lk_assistant.tenants(id),
    number         TEXT NOT NULL,
    counterparty   TEXT NOT NULL,
    amount         NUMERIC(12,2) NOT NULL,
    status         TEXT NOT NULL,
    delivery_date  DATE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_orders_tenant ON lk_assistant.orders (tenant_id);

CREATE TABLE lk_assistant.invoices (
    id             SERIAL PRIMARY KEY,
    tenant_id      INT NOT NULL REFERENCES lk_assistant.tenants(id),
    order_id       INT REFERENCES lk_assistant.orders(id),
    number         TEXT NOT NULL,
    amount         NUMERIC(12,2) NOT NULL,
    status         TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RAG: документы и их чанки с эмбеддингами
CREATE TABLE lk_assistant.documents (
    id          SERIAL PRIMARY KEY,
    tenant_id   INT NOT NULL REFERENCES lk_assistant.tenants(id),
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,       -- полный текст (для small docs) или ссылка на svc_disk
    doc_type    TEXT NOT NULL,       -- 'policy' | 'manual' | 'contract' | ...
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE lk_assistant.document_chunks (
    id          SERIAL PRIMARY KEY,
    document_id INT NOT NULL REFERENCES lk_assistant.documents(id) ON DELETE CASCADE,
    tenant_id   INT NOT NULL,                         -- дублируем для row-level фильтра
    chunk_text  TEXT NOT NULL,
    chunk_idx   INT NOT NULL,
    embedding   vector(768)                           -- nomic-embed-text = 768-dim
);
CREATE INDEX idx_chunks_tenant ON lk_assistant.document_chunks (tenant_id);
CREATE INDEX idx_chunks_embedding ON lk_assistant.document_chunks
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- История чата (опционально, для продвинутых сценариев)
CREATE TABLE lk_assistant.chat_sessions (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   INT NOT NULL REFERENCES lk_assistant.tenants(id),
    user_id     INT NOT NULL REFERENCES lk_assistant.users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE lk_assistant.chat_messages (
    id          SERIAL PRIMARY KEY,
    session_id  UUID NOT NULL REFERENCES lk_assistant.chat_sessions(id) ON DELETE CASCADE,
    role        TEXT NOT NULL,                     -- 'user' | 'assistant' | 'tool'
    content     TEXT NOT NULL,
    metadata    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
