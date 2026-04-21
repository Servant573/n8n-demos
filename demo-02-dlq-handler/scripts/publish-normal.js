// Имитация нормального потока сообщений от 1С.
// Публикует 50 валидных сообщений в integration.* по разным контрагентам.

const amqp = require('amqplib');
const URL = process.env.AMQP_URL || 'amqp://demo:demo_secret@localhost:5672';

const COUNTERPARTIES = [
    { id: 1, name: 'Ромашка Логистик',  inn: '7701234567',    key: 'romashka' },
    { id: 2, name: 'Петров А.В.',       inn: '770987654321',  key: 'petrov' },
    { id: 3, name: 'ТрансГруз',         inn: '7712345678',    key: 'transgruz' },
    { id: 4, name: 'Складсервис',       inn: '7798765432',    key: 'skladservis' },
    { id: 5, name: 'Быстрая Доставка',  inn: '7745678901',    key: 'bystraya' }
];

const DOC_TYPES = ['invoice', 'waybill', 'act'];

function randomMessage() {
    const cp = COUNTERPARTIES[Math.floor(Math.random() * COUNTERPARTIES.length)];
    const doc = DOC_TYPES[Math.floor(Math.random() * DOC_TYPES.length)];
    return {
        routing_key: `integration.${cp.key}`,
        payload: {
            doc_type: doc,
            doc_number: `${doc.toUpperCase()}-2026-${String(Math.floor(Math.random() * 9999)).padStart(4, '0')}`,
            counterparty_id: cp.id,
            counterparty_name: cp.name,
            counterparty_inn: cp.inn,
            amount: +(Math.random() * 500000).toFixed(2),
            currency: 'RUB',
            created_at: new Date().toISOString(),
            items: Array.from({ length: 1 + Math.floor(Math.random() * 5) }, (_, i) => ({
                sku: `SKU-${1000 + i}`,
                qty: 1 + Math.floor(Math.random() * 10),
                price: +(Math.random() * 10000).toFixed(2)
            }))
        }
    };
}

(async () => {
    const conn = await amqp.connect(URL);
    const ch = await conn.createChannel();

    const N = 50;
    for (let i = 0; i < N; i++) {
        const msg = randomMessage();
        ch.publish('integration', msg.routing_key, Buffer.from(JSON.stringify(msg.payload)), {
            persistent: true,
            contentType: 'application/json',
            headers: { 'x-source': '1c-emulator' }
        });
        process.stdout.write(`\rPublished ${i + 1}/${N}`);
        await new Promise(r => setTimeout(r, 100));
    }
    console.log(`\n✓ Published ${N} normal messages`);
    await ch.close();
    await conn.close();
})().catch(err => {
    console.error('Publish failed:', err.message);
    process.exit(1);
});
