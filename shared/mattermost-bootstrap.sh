#!/bin/sh
# Первичная настройка Mattermost: админ, команда, каналы, бот.
# Запускается автоматически из docker-compose (сервис mattermost-bootstrap).
# Идемпотентен — при повторном запуске пропускает уже существующие сущности.

set -e

MM_URL="${MATTERMOST_URL:-http://mattermost:8065}"
ADMIN_EMAIL="${MM_ADMIN_EMAIL:-admin@demo.local}"
ADMIN_USER="${MM_ADMIN_USER:-admin}"
ADMIN_PASS="${MM_ADMIN_PASS:-Demo_secret1}"
TEAM_NAME="${MM_TEAM_NAME:-demo}"
CHANNELS="${MM_CHANNELS:-security ops bugs analytics}"

echo "===> Mattermost bootstrap started"
echo "     URL:      $MM_URL"
echo "     Admin:    $ADMIN_USER"
echo "     Team:     $TEAM_NAME"
echo "     Channels: $CHANNELS"

until curl -sf "$MM_URL/api/v4/system/ping" > /dev/null 2>&1; do
    echo "     Waiting for Mattermost API..."
    sleep 3
done
echo "===> Mattermost API is up"

# ── Admin user ───────────────────────────────────────────────────────────────
HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "{\"login_id\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
    "$MM_URL/api/v4/users/login")

if [ "$HTTP" != "200" ]; then
    echo "===> Creating admin user: $ADMIN_USER"
    curl -sf "$MM_URL/api/v4/users" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
        > /dev/null
    echo "     Admin created"
else
    echo "===> Admin already exists, skipping"
fi

# ── Login ────────────────────────────────────────────────────────────────────
echo "===> Logging in..."
RESP_HEADERS=$(mktemp)
RESP_BODY=$(mktemp)

curl -s -D "$RESP_HEADERS" -o "$RESP_BODY" \
    -H 'Content-Type: application/json' \
    -d "{\"login_id\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
    "$MM_URL/api/v4/users/login"

TOKEN=$(grep -i '^token:' "$RESP_HEADERS" | tr -d '\r\n' | awk '{print $2}')
ADMIN_ID=$(cat "$RESP_BODY" | jq -r '.id')
rm -f "$RESP_HEADERS" "$RESP_BODY"

if [ -z "$TOKEN" ]; then
    echo "FATAL: could not obtain auth token"
    exit 1
fi
echo "     Logged in (user_id=$ADMIN_ID)"

AUTH="Authorization: Bearer $TOKEN"

# ── Team ─────────────────────────────────────────────────────────────────────
echo "===> Setting up team: $TEAM_NAME"
TEAM_HTTP=$(curl -s -o /tmp/team_resp -w '%{http_code}' \
    -H "$AUTH" "$MM_URL/api/v4/teams/name/$TEAM_NAME")

if [ "$TEAM_HTTP" = "200" ]; then
    TEAM_ID=$(jq -r '.id' /tmp/team_resp)
    echo "     Team exists:  $TEAM_ID"
else
    TEAM_ID=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
        -d "{\"name\":\"$TEAM_NAME\",\"display_name\":\"Demo\",\"type\":\"O\"}" \
        "$MM_URL/api/v4/teams" | jq -r '.id')
    echo "     Team created: $TEAM_ID"
fi
rm -f /tmp/team_resp

# ── Channels ─────────────────────────────────────────────────────────────────
echo "===> Creating channels..."
for CH in $CHANNELS; do
    FIRST=$(echo "$CH" | cut -c1 | tr '[:lower:]' '[:upper:]')
    REST=$(echo "$CH" | cut -c2-)
    DISPLAY="${FIRST}${REST}"

    EXISTS=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "$AUTH" "$MM_URL/api/v4/teams/$TEAM_ID/channels/name/$CH")

    if [ "$EXISTS" = "200" ]; then
        echo "     #$CH already exists"
    else
        curl -sf -H "$AUTH" -H 'Content-Type: application/json' \
            -d "{\"team_id\":\"$TEAM_ID\",\"name\":\"$CH\",\"display_name\":\"$DISPLAY\",\"type\":\"O\"}" \
            "$MM_URL/api/v4/channels" > /dev/null
        echo "     #$CH created"
    fi
done

# ── Bot for N8N ──────────────────────────────────────────────────────────────
echo "===> Setting up N8N bot..."
BOT_USER_ID=$(curl -s -H "$AUTH" "$MM_URL/api/v4/bots" \
    | jq -r '.[] | select(.username=="n8n-bot") | .user_id // empty')

if [ -z "$BOT_USER_ID" ] || [ "$BOT_USER_ID" = "null" ]; then
    BOT_USER_ID=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
        -d '{"username":"n8n-bot","display_name":"N8N Bot","description":"Workflow notifications"}' \
        "$MM_URL/api/v4/bots" | jq -r '.user_id')

    BOT_TOKEN=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
        -d '{"description":"n8n integration"}' \
        "$MM_URL/api/v4/users/$BOT_USER_ID/tokens" | jq -r '.token')

    echo "     Bot created (user_id=$BOT_USER_ID)"
    echo ""
    echo "============================================================"
    echo "  MATTERMOST_BOT_TOKEN=$BOT_TOKEN"
    echo "  Add this to .env to connect N8N → Mattermost"
    echo "============================================================"
    echo ""
else
    echo "     Bot already exists (user_id=$BOT_USER_ID)"
fi

# ── Add bot to team and channels ─────────────────────────────────────────────
echo "===> Adding bot to team and channels..."
curl -s -o /dev/null -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"team_id\":\"$TEAM_ID\",\"user_id\":\"$BOT_USER_ID\"}" \
    "$MM_URL/api/v4/teams/$TEAM_ID/members" 2>/dev/null || true

for CH in $CHANNELS; do
    CH_ID=$(curl -s -H "$AUTH" "$MM_URL/api/v4/teams/$TEAM_ID/channels/name/$CH" \
        | jq -r '.id')
    curl -s -o /dev/null -H "$AUTH" -H 'Content-Type: application/json' \
        -d "{\"user_id\":\"$BOT_USER_ID\"}" \
        "$MM_URL/api/v4/channels/$CH_ID/members" 2>/dev/null || true
    echo "     Bot → #$CH"
done

# ── Outgoing Webhook for demo-02 (Logistics AI → n8n) ───────────────────────
echo "===> Setting up outgoing webhook for #logistics..."
LOGISTICS_CH_ID=$(curl -s -H "$AUTH" "$MM_URL/api/v4/teams/$TEAM_ID/channels/name/logistics" \
    | jq -r '.id // empty')

if [ -n "$LOGISTICS_CH_ID" ] && [ "$LOGISTICS_CH_ID" != "null" ]; then
    EXISTING_HOOK=$(curl -s -H "$AUTH" "$MM_URL/api/v4/hooks/outgoing" \
        | jq -r ".[] | select(.channel_id==\"$LOGISTICS_CH_ID\") | .id // empty")

    if [ -z "$EXISTING_HOOK" ]; then
        curl -sf -H "$AUTH" -H 'Content-Type: application/json' \
            -d "{\"team_id\":\"$TEAM_ID\",\"channel_id\":\"$LOGISTICS_CH_ID\",\"display_name\":\"Logistics AI\",\"description\":\"Forwards messages to n8n for AI processing\",\"content_type\":\"application/json\",\"trigger_when\":0,\"callback_urls\":[\"http://n8n:5678/webhook/logistics-ai\"]}" \
            "$MM_URL/api/v4/hooks/outgoing" > /dev/null
        echo "     Outgoing webhook created → http://n8n:5678/webhook/logistics-ai"
    else
        echo "     Outgoing webhook already exists"
    fi
else
    echo "     #logistics channel not found, skipping webhook"
fi

echo ""
echo "===> Mattermost bootstrap complete"
echo "     UI: http://localhost:8065  (login: $ADMIN_USER / $ADMIN_PASS)"
