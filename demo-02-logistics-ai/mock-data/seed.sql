-- ============================================================
-- Демо-данные для logistics_assistant (demo-02)
-- ============================================================

SET search_path TO logistics_assistant;

-- Контрагенты
INSERT INTO counterparties (name, inn) VALUES
    ('ООО "Ромашка Логистик"',  '7701234567'),
    ('ИП Петров А.В.',          '770987654321'),
    ('АО "ТрансГруз"',          '7712345678'),
    ('ООО "Складсервис"',       '7798765432'),
    ('ООО "Быстрая Доставка"',  '7745678901')
ON CONFLICT DO NOTHING;

-- Счета (разный статус, разные даты)
INSERT INTO invoices (counterparty_id, number, amount, status, created_at) VALUES
    (1, 'INV-2026-001', 150000.00, 'processed',  NOW() - INTERVAL '2 days'),
    (1, 'INV-2026-002', 87500.50,  'pending',    NOW() - INTERVAL '1 day'),
    (1, 'INV-2026-003', 220000.00, 'error',      NOW() - INTERVAL '3 hours'),
    (2, 'INV-2026-010', 45000.00,  'processed',  NOW() - INTERVAL '5 days'),
    (3, 'INV-2026-020', 310000.00, 'processed',  NOW() - INTERVAL '1 day'),
    (3, 'INV-2026-021', 95000.00,  'pending',    NOW() - INTERVAL '6 hours'),
    (4, 'INV-2026-030', 62000.00,  'processed',  NOW() - INTERVAL '10 days'),
    (5, 'INV-2026-040', 178000.00, 'error',      NOW() - INTERVAL '2 hours');

-- Обмен данными
INSERT INTO data_exchanges (counterparty_id, direction, doc_type, status, error_message, created_at) VALUES
    (1, 'incoming', 'invoice', 'success',  NULL,                                      NOW() - INTERVAL '2 days'),
    (1, 'incoming', 'invoice', 'success',  NULL,                                      NOW() - INTERVAL '1 day'),
    (1, 'incoming', 'invoice', 'error',    'XML validation failed: missing field INN', NOW() - INTERVAL '3 hours'),
    (2, 'incoming', 'waybill', 'success',  NULL,                                      NOW() - INTERVAL '5 days'),
    (3, 'outgoing', 'act',     'success',  NULL,                                      NOW() - INTERVAL '1 day'),
    (3, 'incoming', 'invoice', 'pending',  NULL,                                      NOW() - INTERVAL '6 hours'),
    (5, 'incoming', 'invoice', 'error',    'Connection timeout to partner API',        NOW() - INTERVAL '2 hours'),
    (5, 'outgoing', 'waybill', 'error',    'Partner returned HTTP 503',                NOW() - INTERVAL '1 hour');

-- Логи интеграции
INSERT INTO integration_logs (service, level, message, payload, created_at) VALUES
    ('edm-gateway',   'info',  'Document received from counterparty',      '{"counterparty_id": 1, "doc_type": "invoice"}',     NOW() - INTERVAL '2 days'),
    ('edm-gateway',   'info',  'Document received from counterparty',      '{"counterparty_id": 1, "doc_type": "invoice"}',     NOW() - INTERVAL '1 day'),
    ('edm-gateway',   'error', 'XML validation failed',                    '{"counterparty_id": 1, "field": "INN", "doc_type": "invoice"}', NOW() - INTERVAL '3 hours'),
    ('sync-service',  'warn',  'Retry attempt 3/5 for partner API',        '{"counterparty_id": 5, "endpoint": "/api/v2/docs"}', NOW() - INTERVAL '2 hours'),
    ('sync-service',  'error', 'Connection timeout after 30s',             '{"counterparty_id": 5, "endpoint": "/api/v2/docs"}', NOW() - INTERVAL '2 hours'),
    ('sync-service',  'error', 'Partner API returned 503 Service Unavailable', '{"counterparty_id": 5, "status": 503}',          NOW() - INTERVAL '1 hour'),
    ('health-check',  'info',  'All services operational',                  '{"db": "ok", "redis": "ok", "edm": "ok"}',         NOW() - INTERVAL '30 minutes'),
    ('edm-gateway',   'info',  'Outgoing document sent successfully',       '{"counterparty_id": 3, "doc_type": "act"}',        NOW() - INTERVAL '1 day');
