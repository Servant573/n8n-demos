// ============================================================================
// Настраивает RabbitMQ под demo-02:
//   - exchange   integration (topic)
//   - queue      integration.main        — "здоровая" очередь
//   - queue      integration.dlq         — Dead Letter Queue
//   - binding    integration.*  →  integration.main
//   - DLX:       integration.main nack/expired → integration.dlq
// ============================================================================

const amqp = require('amqplib');

const URL = process.env.AMQP_URL || 'amqp://demo:demo_secret@localhost:5672';

(async () => {
    console.log(`Connecting to ${URL}...`);
    const conn = await amqp.connect(URL);
    const ch = await conn.createChannel();

    const exch = 'integration';
    const mainQ = 'integration.main';
    const dlqQ = 'integration.dlq';
    const dlxExch = 'integration.dlx';

    // Exchanges
    await ch.assertExchange(exch, 'topic', { durable: true });
    await ch.assertExchange(dlxExch, 'fanout', { durable: true });

    // DLQ
    await ch.assertQueue(dlqQ, { durable: true });
    await ch.bindQueue(dlqQ, dlxExch, '');

    // Основная очередь с политикой переадресации в DLX
    await ch.assertQueue(mainQ, {
        durable: true,
        arguments: {
            'x-dead-letter-exchange': dlxExch,
            'x-message-ttl': 60000   // 60 секунд — если не обработано, уходит в DLQ
        }
    });
    await ch.bindQueue(mainQ, exch, 'integration.*');

    console.log('✓ exchange:     integration (topic)');
    console.log('✓ exchange:     integration.dlx (fanout)');
    console.log('✓ queue:        integration.main (TTL 60s, DLX → integration.dlx)');
    console.log('✓ queue:        integration.dlq');
    console.log('✓ binding:      integration.* → integration.main');
    console.log('');
    console.log('Management UI:  http://localhost:15672  (demo / demo_secret)');

    await ch.close();
    await conn.close();
})().catch(err => {
    console.error('Setup failed:', err.message);
    process.exit(1);
});
