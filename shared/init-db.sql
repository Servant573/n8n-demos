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
-- SCHEMA: logistics_assistant (для demo-02)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS logistics_assistant;

CREATE TABLE logistics_assistant.counterparties (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    inn        TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE logistics_assistant.invoices (
    id               SERIAL PRIMARY KEY,
    counterparty_id  INT REFERENCES logistics_assistant.counterparties(id),
    number           TEXT NOT NULL,
    amount           NUMERIC(12,2) NOT NULL,
    status           TEXT NOT NULL DEFAULT 'pending',
    created_at       TIMESTAMP DEFAULT NOW()
);

CREATE TABLE logistics_assistant.integration_logs (
    id         SERIAL PRIMARY KEY,
    service    TEXT NOT NULL,
    level      TEXT NOT NULL DEFAULT 'info',
    message    TEXT NOT NULL,
    payload    JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE logistics_assistant.data_exchanges (
    id               SERIAL PRIMARY KEY,
    counterparty_id  INT REFERENCES logistics_assistant.counterparties(id),
    direction        TEXT NOT NULL,       -- 'incoming' | 'outgoing'
    doc_type         TEXT NOT NULL,       -- 'invoice' | 'waybill' | 'act'
    status           TEXT NOT NULL,       -- 'success' | 'error' | 'pending'
    error_message    TEXT,
    created_at       TIMESTAMP DEFAULT NOW()
);
