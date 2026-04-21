// Имитация сломанных сообщений — они улетят в DLQ после того как TTL истечёт
// или воркфлоу их отреджектит. Даёт разнообразный набор для тестирования AI-классификации.
//
// Публикуем напрямую в integration.dlq для ускорения демо (в реальности они
// падали бы из integration.main через TTL/nack).

const amqp = require('amqplib');
const URL = process.env.AMQP_URL || 'amqp://demo:demo_secret@localhost:5672';

const BROKEN_MESSAGES = [
    // --- "our_bug": наша ошибка в обработке ---
    {
        label: 'our_bug: null в обязательном поле',
        payload: {
            doc_type: 'invoice',
            doc_number: null,
            counterparty_id: 1,
            amount: 150000,
            _error: 'NullPointerException at com.example.InvoiceProcessor.validate:42'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.romashka'] }] }
    },
    {
        label: 'our_bug: UNIQUE violation',
        payload: {
            doc_type: 'waybill',
            doc_number: 'WAYBILL-2026-0042',
            counterparty_id: 2,
            _error: 'duplicate key value violates unique constraint "waybills_number_uniq"'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.petrov'] }] }
    },
    // --- "partner_data": данные от контрагента кривые ---
    {
        label: 'partner_data: битый ИНН',
        payload: {
            doc_type: 'invoice',
            doc_number: 'INV-2026-1234',
            counterparty_id: 5,
            counterparty_inn: '123',  // слишком короткий
            amount: 99999,
            _error: 'ИНН не проходит валидацию контрольной суммы'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.bystraya'] }] }
    },
    {
        label: 'partner_data: отрицательная сумма',
        payload: {
            doc_type: 'invoice',
            doc_number: 'INV-2026-9999',
            counterparty_id: 3,
            amount: -45000,
            _error: 'Сумма счёта не может быть отрицательной'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.transgruz'] }] }
    },
    {
        label: 'partner_data: неизвестный контрагент',
        payload: {
            doc_type: 'act',
            doc_number: 'ACT-2026-1111',
            counterparty_id: 999,
            counterparty_inn: '9999999999',
            _error: 'Контрагент с ИНН 9999999999 не найден в справочнике'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.unknown'] }] }
    },
    // --- "infrastructure": внешние проблемы ---
    {
        label: 'infrastructure: timeout partner API',
        payload: {
            doc_type: 'waybill',
            doc_number: 'WAYBILL-2026-5555',
            counterparty_id: 5,
            _error: 'Connection timeout to partner API https://edi.bystraya.ru/api/v2/docs after 30s'
        },
        headers: { 'x-death': [{ reason: 'expired', 'routing-keys': ['integration.bystraya'] }] }
    },
    {
        label: 'infrastructure: HTTP 503 от партнёра',
        payload: {
            doc_type: 'invoice',
            doc_number: 'INV-2026-8888',
            counterparty_id: 5,
            _error: 'Partner API returned HTTP 503 Service Unavailable (retry 5/5 failed)'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.bystraya'] }] }
    },
    // --- "business_rule": нарушение бизнес-правил ---
    {
        label: 'business_rule: превышен кредитный лимит',
        payload: {
            doc_type: 'invoice',
            doc_number: 'INV-2026-7777',
            counterparty_id: 4,
            amount: 2500000,
            _error: 'Сумма счёта превышает установленный кредитный лимит контрагента (1 000 000 RUB)'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.skladservis'] }] }
    },
    {
        label: 'business_rule: дубликат счёта',
        payload: {
            doc_type: 'invoice',
            doc_number: 'INV-2026-0001',
            counterparty_id: 1,
            _error: 'Счёт с этим номером от данного контрагента уже был зарегистрирован 3 дня назад'
        },
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.romashka'] }] }
    },
    // --- Битый JSON (граничный кейс) ---
    {
        label: 'our_bug: битый JSON',
        payload: '{"doc_type": "invoice", "doc_number": "INV-', // буквально битая строка
        headers: { 'x-death': [{ reason: 'rejected', 'routing-keys': ['integration.unknown'] }] },
        raw: true
    }
];

(async () => {
    const conn = await amqp.connect(URL);
    const ch = await conn.createChannel();

    // Публикуем прямо в dlq для скорости демо
    for (const [i, msg] of BROKEN_MESSAGES.entries()) {
        const body = msg.raw ? msg.payload : JSON.stringify(msg.payload);
        ch.publish('integration.dlx', '', Buffer.from(body), {
            persistent: true,
            contentType: 'application/json',
            headers: msg.headers
        });
        console.log(`  [${i + 1}/${BROKEN_MESSAGES.length}] ${msg.label}`);
        await new Promise(r => setTimeout(r, 300));
    }
    console.log(`\n✓ Published ${BROKEN_MESSAGES.length} broken messages to DLQ`);
    await ch.close();
    await conn.close();
})().catch(err => {
    console.error('Publish failed:', err.message);
    process.exit(1);
});
