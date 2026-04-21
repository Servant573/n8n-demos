-- Моковые контрагенты для demo-02

INSERT INTO dlq_handler.counterparties (name, inn, amqp_queue, manager_email, mattermost_user) VALUES
    ('ООО "Ромашка Логистик"',   '7701234567',  'integration.romashka',    'manager1@example.com', 'ivan.petrov'),
    ('ИП Петров А.В.',           '770987654321','integration.petrov',      'manager2@example.com', 'anna.sidorova'),
    ('АО "ТрансГруз"',           '7712345678',  'integration.transgruz',   'manager3@example.com', 'ivan.petrov'),
    ('ООО "Складсервис"',        '7798765432',  'integration.skladservis', 'manager4@example.com', 'anna.sidorova'),
    ('ООО "Быстрая Доставка"',   '7745678901',  'integration.bystraya',    'manager5@example.com', 'olga.kuznetsova');
