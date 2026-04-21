#!/bin/sh
# Импорт credentials и workflows в n8n.
# Запускается на хосте из Makefile после старта всех сервисов.
# Требует: curl, jq, python3, docker.

set -e

N8N_URL="${N8N_URL:-http://localhost:5678}"
MM_URL="${MM_URL:-http://localhost:8065}"
MM_ADMIN_USER="${MM_ADMIN_USER:-admin}"
MM_ADMIN_PASS="${MM_ADMIN_PASS:-Demo_secret1}"
MM_TEAM_NAME="${MM_TEAM_NAME:-demo}"
N8N_CONTAINER="${N8N_CONTAINER:-demo-n8n}"
WORKFLOW_DIR="${WORKFLOW_DIR:-demo-01-cve-watcher/workflows}"

echo "===> n8n bootstrap started"

# ── Wait for n8n ─────────────────────────────────────────────────────────────
echo "     Waiting for n8n API..."
until curl -sf "$N8N_URL/healthz" > /dev/null 2>&1; do
    sleep 3
done
echo "     n8n is up"

# ── Get Mattermost channel IDs ──────────────────────────────────────────────
echo "===> Fetching Mattermost channel IDs..."
MM_TOKEN=$(curl -si "$MM_URL/api/v4/users/login" \
    -H 'Content-Type: application/json' \
    -d "{\"login_id\":\"$MM_ADMIN_USER\",\"password\":\"$MM_ADMIN_PASS\"}" 2>/dev/null \
    | grep -i '^token:' | tr -d '\r\n' | awk '{print $2}')

TEAM_ID=$(curl -s "$MM_URL/api/v4/teams/name/$MM_TEAM_NAME" \
    -H "Authorization: Bearer $MM_TOKEN" | jq -r '.id')

get_channel_id() {
    curl -s "$MM_URL/api/v4/teams/$TEAM_ID/channels/name/$1" \
        -H "Authorization: Bearer $MM_TOKEN" | jq -r '.id'
}

CH_OPS=$(get_channel_id ops)
CH_SECURITY=$(get_channel_id security)
CH_BUGS=$(get_channel_id bugs)
CH_ANALYTICS=$(get_channel_id analytics)

echo "     #ops       = $CH_OPS"
echo "     #security  = $CH_SECURITY"
echo "     #bugs      = $CH_BUGS"
echo "     #analytics = $CH_ANALYTICS"

# ── Read bot token from .env ─────────────────────────────────────────────────
BOT_TOKEN=$(grep '^MATTERMOST_BOT_TOKEN=' .env | cut -d= -f2)
if [ -z "$BOT_TOKEN" ]; then
    echo "FATAL: MATTERMOST_BOT_TOKEN not found in .env"
    exit 1
fi

# ── Create credentials JSON ─────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
cat > "$TMPDIR/credentials.json" << CEOF
[
  {
    "id": "1",
    "name": "Demo Postgres",
    "type": "postgres",
    "data": {
      "host": "postgres",
      "port": 5432,
      "database": "demo",
      "user": "demo",
      "password": "demo_secret",
      "ssl": "disable"
    }
  },
  {
    "id": "2",
    "name": "Mattermost Demo",
    "type": "mattermostApi",
    "data": {
      "accessToken": "$BOT_TOKEN",
      "baseUrl": "http://mattermost:8065"
    }
  }
]
CEOF

# ── Check if already imported ────────────────────────────────────────────────
EXISTING=$(docker exec "$N8N_CONTAINER" n8n list:workflow 2>/dev/null | wc -l)
if [ "$EXISTING" -gt 0 ]; then
    echo "===> Workflows already imported ($EXISTING found), skipping"
    rm -rf "$TMPDIR"
    exit 0
fi

echo "===> Importing credentials..."
docker cp "$TMPDIR/credentials.json" "$N8N_CONTAINER:/tmp/credentials.json"
docker exec "$N8N_CONTAINER" n8n import:credentials --input=/tmp/credentials.json 2>&1
echo "     Credentials imported"

# ── Patch workflows with channel IDs and import ─────────────────────────────
echo "===> Patching and importing workflows..."

# Node name → channel ID mapping
python3 -c "
import json, sys, os, glob

channel_map = {
    'Notify Ops':      '$CH_OPS',
    'Alert Security':  '$CH_SECURITY',
    'Notify Sprint':   '$CH_OPS',
    'Send Report':     '$CH_OPS',
    'Notify Bugs':     '$CH_BUGS',
    'Notify Analytics':'$CH_ANALYTICS',
}

tmpdir = '$TMPDIR'
wf_dir = '$WORKFLOW_DIR'

import string, random
def nanoid(size=16):
    alphabet = string.ascii_letters + string.digits
    return ''.join(random.choices(alphabet, k=size))

for fpath in sorted(glob.glob(os.path.join(wf_dir, '*.json'))):
    with open(fpath) as f:
        wf = json.load(f)

    if 'id' not in wf:
        wf['id'] = nanoid()

    for node in wf.get('nodes', []):
        params = node.get('parameters', {})
        if params.get('channelId') == 'CONFIGURE_CHANNEL_ID':
            name = node.get('name', '')
            ch_id = channel_map.get(name, '$CH_OPS')
            params['channelId'] = ch_id

    out = os.path.join(tmpdir, os.path.basename(fpath))
    with open(out, 'w') as f:
        json.dump(wf, f, indent=2)
    print(f'     Patched {os.path.basename(fpath)}: channels set')
"

for f in "$TMPDIR"/*.json; do
    [ "$(basename "$f")" = "credentials.json" ] && continue
    docker cp "$f" "$N8N_CONTAINER:/tmp/$(basename "$f")"
    docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/$(basename "$f")" 2>&1
    echo "     Imported $(basename "$f")"
done

rm -rf "$TMPDIR"

# ── Fix triggerCount (n8n CLI doesn't set it on import) ──────────────────────
echo "===> Fixing triggerCount..."
docker exec demo-postgres psql -U demo -d n8n -c "
UPDATE workflow_entity
SET \"triggerCount\" = (
    SELECT count(*)
    FROM jsonb_array_elements(nodes) AS n
    WHERE n->>'type' LIKE '%Trigger%'
       OR n->>'type' LIKE '%trigger%'
)
WHERE \"triggerCount\" = 0;" 2>/dev/null
echo "     triggerCount updated"

echo ""
echo "===> n8n bootstrap complete"
echo "     Workflows and credentials imported"
