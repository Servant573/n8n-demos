// Показывает состояние очередей в реальном времени.
// Полезно держать открытым во время демо — видно, как DLQ наполняется и очищается.

const http = require('http');

const MGMT_URL = 'http://localhost:15672';
const AUTH = 'Basic ' + Buffer.from('demo:demo_secret').toString('base64');

const QUEUES_TO_WATCH = ['integration.main', 'integration.dlq'];

function fetchQueue(name) {
    return new Promise((resolve, reject) => {
        const url = `${MGMT_URL}/api/queues/%2F/${encodeURIComponent(name)}`;
        http.get(url, { headers: { Authorization: AUTH } }, res => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => {
                if (res.statusCode !== 200) return resolve(null);
                try { resolve(JSON.parse(body)); }
                catch (e) { resolve(null); }
            });
        }).on('error', reject);
    });
}

function colorNum(n) {
    if (n === 0) return `\x1b[32m${String(n).padStart(6)}\x1b[0m`;      // зелёный
    if (n < 10)  return `\x1b[33m${String(n).padStart(6)}\x1b[0m`;      // жёлтый
    return `\x1b[31m${String(n).padStart(6)}\x1b[0m`;                    // красный
}

async function tick() {
    // clear screen
    process.stdout.write('\x1b[2J\x1b[H');
    console.log('RabbitMQ queues — live view');
    console.log('Press Ctrl+C to stop.');
    console.log('');
    console.log('  queue                    │  messages  │  ready  │  unacked  │  rate(/s)');
    console.log('  ─────────────────────────┼────────────┼─────────┼───────────┼──────────');

    for (const qname of QUEUES_TO_WATCH) {
        const q = await fetchQueue(qname);
        if (!q) {
            console.log(`  ${qname.padEnd(25)} │   (offline or not declared)`);
            continue;
        }
        const rate = (q.message_stats && q.message_stats.publish_details)
            ? q.message_stats.publish_details.rate.toFixed(1)
            : '—';
        console.log(
            `  ${qname.padEnd(25)} │ ${colorNum(q.messages)}     │ ${colorNum(q.messages_ready)}  │ ${colorNum(q.messages_unacknowledged)}    │   ${rate}`
        );
    }
    console.log('');
    console.log(`  last update: ${new Date().toLocaleTimeString()}`);
}

console.log('Starting watch loop... (refresh every 2s)');
tick();
setInterval(tick, 2000);
