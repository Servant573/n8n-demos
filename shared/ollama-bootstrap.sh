#!/bin/sh
# Подтягивает нужные модели Ollama при первом запуске.
# Запускается автоматически из docker-compose (сервис ollama-bootstrap).

set -e

echo "===> Ollama bootstrap started"
echo "     Host:        $OLLAMA_HOST"
echo "     Chat model:  $OLLAMA_MODEL_CHAT"
echo "     Code model:  $OLLAMA_MODEL_CODE"
echo "     Embed model: $OLLAMA_MODEL_EMBED"

# Ждём, пока API поднимется
until curl -sf "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; do
    echo "     Waiting for Ollama API..."
    sleep 3
done
echo "===> Ollama API is up"

pull_model() {
    local model=$1
    local label=$2
    echo ""
    echo "===> Pulling [$label]: $model"
    curl -sf "$OLLAMA_HOST/api/pull" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$model\",\"stream\":false}" \
        -o /dev/null
    echo "     [$label] done"
}

pull_model "$OLLAMA_MODEL_CHAT"  "chat"
pull_model "$OLLAMA_MODEL_CODE"  "code"
pull_model "$OLLAMA_MODEL_EMBED" "embed"

echo ""
echo "===> All models ready"
