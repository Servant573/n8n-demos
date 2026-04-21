# Snippets для demo-02 (DLQ Handler)

---

## `extract-payload.js` — разбор сообщения из RabbitMQ

```javascript
// Input: $json = { content: "<raw body>", fields: {...}, properties: {...} } от RabbitMQ Trigger
// Output: нормализованный объект + флаг parse_error

const raw = $input.first().json;
const headers = raw.properties?.headers || {};
const routingKey = raw.fields?.routingKey || '';

// Берём причину смерти (rejected/expired/delivery-limit)
const xdeath = headers['x-death'] || [];
const deathReason = xdeath[0]?.reason || 'unknown';
const originalRouting = xdeath[0]?.['routing-keys']?.[0] || routingKey;

// Пытаемся распарсить body
let payload = null;
let parseError = null;
try {
    // raw.content приходит как Buffer или base64 — в N8N v1 это уже строка
    const bodyStr = typeof raw.content === 'string'
        ? raw.content
        : Buffer.from(raw.content).toString('utf8');
    payload = JSON.parse(bodyStr);
} catch (e) {
    parseError = e.message;
    payload = { _raw_body_preview: String(raw.content).slice(0, 500) };
}

// Достаём ключ контрагента из routing_key: "integration.romashka" → "romashka"
const counterpartyKey = originalRouting.replace(/^integration\./, '');

return [{
    json: {
        payload,
        parse_error: parseError,
        routing_key: originalRouting,
        death_reason: deathReason,
        counterparty_key: counterpartyKey,
        counterparty_id: payload?.counterparty_id || null,
        doc_type: payload?.doc_type || 'unknown',
        doc_number: payload?.doc_number || null,
        error_text: payload?._error || parseError || 'no error message in payload'
    }
}];
```

---

## `sanitize-pii.js` — маскировка перед отправкой в LLM

```javascript
// Маскируем чувствительные поля перед тем как передать payload в LLM.
// Цель: не логировать PII в execution history N8N и не отправлять во внешние
// модели (если когда-нибудь переключимся на премиум-режим).

function mask(obj) {
    if (obj === null || obj === undefined) return obj;
    if (typeof obj === 'string') {
        return obj
            .replace(/\b(\d{3})\d{7,9}\b/g, '$1***')                // ИНН — оставляем 3 цифры
            .replace(/\+?[78]?[\s\-\(]*\d{3}[\s\-\)]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}/g, '+7***')  // телефоны
            .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '***@***');       // email
    }
    if (Array.isArray(obj)) return obj.map(mask);
    if (typeof obj === 'object') {
        const out = {};
        for (const [k, v] of Object.entries(obj)) {
            // Поля с именами, содержащими "inn", "phone", "email" — маскируем агрессивно
            if (/inn|phone|email/i.test(k) && typeof v === 'string') {
                out[k] = v.length > 3 ? v.slice(0, 3) + '***' : '***';
            } else {
                out[k] = mask(v);
            }
        }
        return out;
    }
    return obj;
}

const input = $input.first().json;
return [{
    json: {
        ...input,
        payload_sanitized: mask(input.payload)
    }
}];
```

---

## `triage-prompt.md` — промпт для классификации DLQ

```text
Ты - дежурный инженер интеграций. К тебе пришло упавшее сообщение из Dead Letter Queue нашей платформы обмена данными с контрагентами (1С ↔ RabbitMQ).

Задача: классифицировать корневую причину и предложить действие.

СООБЩЕНИЕ:
- Routing: {{ $json.routing_key }}
- Причина смерти: {{ $json.death_reason }}
- Тип документа: {{ $json.doc_type }}
- Номер документа: {{ $json.doc_number }}
- Текст ошибки: {{ $json.error_text }}
- Payload (санитизированный): {{ JSON.stringify($json.payload_sanitized) }}

КОНТРАГЕНТ:
- Название: {{ $json.counterparty_name || 'неизвестен' }}
- Ошибок за последний час: {{ $json.errors_1h }}
- Ошибок за сутки: {{ $json.errors_24h }}

КАТЕГОРИИ:
- "our_bug" — ошибка в нашем коде (NullPointer, UNIQUE violation, неожиданный формат, деление на ноль и т.д.)
- "partner_data" — контрагент прислал некорректные данные (битый ИНН, отрицательная сумма, неизвестный справочник, битый JSON/XML)
- "infrastructure" — проблема сети/внешних сервисов (timeout, HTTP 5xx, connection refused)
- "business_rule" — данные корректны, но нарушают бизнес-логику (превышен лимит, дубликат документа, попытка изменить закрытый период)

ДЕЙСТВИЯ:
- "retry" — мягкий сбой, имеет смысл повторить через N минут
- "manual_review" — неясно, нужна человеческая оценка
- "escalate" — критично, нужен инженер/менеджер прямо сейчас
- "ignore" — известная и безопасная ошибка (например, дубль из-за повторной отправки клиентом)

Верни строго JSON без преамбулы:
{
  "category": "our_bug" | "partner_data" | "infrastructure" | "business_rule",
  "severity": "low" | "medium" | "high" | "critical",
  "action": "retry" | "manual_review" | "escalate" | "ignore",
  "summary_ru": "<одно короткое предложение для Mattermost>",
  "reasoning": "<1-2 предложения почему именно эта категория>",
  "assignee_hint": "backend" | "integrations" | "account_manager" | "ops"
}
```

Body HTTP-запроса:
```json
{
  "model": "{{ $env.OLLAMA_MODEL_CHAT }}",
  "prompt": "...см. выше...",
  "format": "json",
  "stream": false,
  "options": { "temperature": 0.2, "num_predict": 300 }
}
```

---

## `parse-ai-response.js` — разбор ответа с fallback

```javascript
const fallback = {
    category: 'our_bug',
    severity: 'medium',
    action: 'manual_review',
    summary_ru: 'Автоклассификация не удалась — требуется ручная проверка',
    reasoning: 'AI response parsing failed',
    assignee_hint: 'ops'
};

const VALID_CATEGORIES = ['our_bug', 'partner_data', 'infrastructure', 'business_rule'];
const VALID_ACTIONS = ['retry', 'manual_review', 'escalate', 'ignore'];
const VALID_SEVERITIES = ['low', 'medium', 'high', 'critical'];

let parsed;
try {
    const raw = $json.response || $json;
    parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!VALID_CATEGORIES.includes(parsed.category)) parsed.category = fallback.category;
    if (!VALID_ACTIONS.includes(parsed.action)) parsed.action = fallback.action;
    if (!VALID_SEVERITIES.includes(parsed.severity)) parsed.severity = fallback.severity;
    if (!parsed.summary_ru) parsed.summary_ru = fallback.summary_ru;
} catch (e) {
    parsed = fallback;
}

// Прокидываем дальше и payload и триаж для следующих нод
return [{ json: { ...$input.first().json, triage: parsed } }];
```

---

## `anomaly-prompt.md` — промпт для объяснения тихой деградации

```text
Ты - дежурный по интеграциям. Обнаружена аномалия в потоке сообщений от контрагента.

Контрагент: {{ $json.name }}
Типичный поток в это время суток: {{ $json.baseline_avg }} сообщений/час
Сейчас: {{ $json.current }} сообщений/час
Z-score: {{ $json.z_score }}
Последнее сообщение: {{ $json.last_message_ago }} назад

Текущее время: {{ $now }} ({{ $json.weekday }})
Сегодня праздник: {{ $json.is_holiday }}

Напиши короткий пояснительный текст для канала #integrations. 2-3 предложения:
1. Что именно произошло (в цифрах)
2. Наиболее вероятная причина (плановые работы / сбой / выходной)
3. Что стоит проверить дежурному

Только текст, без markdown, без списков. На русском.
```

---

## `mm-templates.md` — шаблоны сообщений в Mattermost

### Для `#bugs` (our_bug)

```markdown
:bug: **Баг в обработке DLQ** · {{ severity }}

**Контрагент:** {{ counterparty.name }}
**Документ:** {{ doc_type }} {{ doc_number }}
**Категория:** `{{ triage.category }}` → `{{ triage.action }}`

{{ triage.summary_ru }}

> {{ triage.reasoning }}

Создан issue: [svc_integration#{{ issue.iid }}]({{ issue.web_url }})
Событие: `dlq_events.id = {{ event.id }}`
```

### Для персонального сообщения менеджеру (partner_data)

```markdown
Привет! По клиенту **{{ counterparty.name }}** (ИНН {{ counterparty.inn }}) — проблема с данными, которые они прислали.

{{ triage.summary_ru }}

Документ: {{ doc_type }} № {{ doc_number }}
Ошибок от них за сутки: **{{ stats.errors_24h }}**

Возможно стоит связаться с их интеграционной командой. Если это единичный случай — игнорь.
```

### Для `#ops` (infrastructure)

```markdown
:warning: **Инфра-алерт** · {{ severity }}

{{ triage.summary_ru }}

**Контрагент:** {{ counterparty.name }}
**Сервис:** {{ payload.service || 'unknown' }}
**Ошибок за час:** {{ stats.errors_1h }}

> {{ triage.reasoning }}

[Retry вручную](http://localhost:5678/workflow/dlq-retry/trigger?event={{ event.id }})
```

### Для `#analytics` (business_rule)

```markdown
:chart_with_upwards_trend: **Нарушение бизнес-правила**

{{ triage.summary_ru }}

Контрагент: {{ counterparty.name }}
Документ: {{ doc_type }} № {{ doc_number }}
Сумма: {{ payload.amount }} {{ payload.currency }}

Требуется оценка аналитика: стоит ли менять правило или это действительно ошибка контрагента.
```
