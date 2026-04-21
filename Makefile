# ============================================================================
# Демо-стенд: N8N + Mattermost + Ollama + RabbitMQ + Postgres
# ============================================================================
#
#   make init   — первый запуск: .env, сервисы, настройка Mattermost
#   make up     — поднять сервисы (без инициализации)
#   make down   — остановить
#   make clean  — остановить + удалить все данные
#   make logs   — логи всех сервисов
#   make status — состояние контейнеров

.PHONY: init up down clean logs status

# ── Полная инициализация ─────────────────────────────────────────────────────
init: .env
	@echo ""
	@echo "=== Запуск сервисов ==="
	-docker compose up -d
	@docker compose up -d mattermost-bootstrap 2>/dev/null || true
	@echo ""
	@echo "=== Ожидание настройки Mattermost ==="
	@until docker ps -a --filter name=demo-mm-bootstrap --format '{{.Status}}' 2>/dev/null | grep -q 'Exited'; do \
		sleep 3; \
	done
	@EXIT_CODE=$$(docker inspect demo-mm-bootstrap --format '{{.State.ExitCode}}' 2>/dev/null); \
	if [ "$$EXIT_CODE" != "0" ]; then \
		echo ""; \
		echo "ERROR: Mattermost bootstrap failed (exit code $$EXIT_CODE):"; \
		docker compose logs mattermost-bootstrap; \
		exit 1; \
	fi
	@BOT_TOKEN=$$(docker compose logs mattermost-bootstrap 2>/dev/null \
		| grep 'MATTERMOST_BOT_TOKEN=' | head -1 | sed 's/.*MATTERMOST_BOT_TOKEN=//'); \
	if [ -n "$$BOT_TOKEN" ]; then \
		sed -i "s|^MATTERMOST_BOT_TOKEN=.*|MATTERMOST_BOT_TOKEN=$$BOT_TOKEN|" .env; \
		echo "    Bot token записан в .env"; \
	else \
		echo "    Bot уже существовал, .env не изменён"; \
	fi
	@echo ""
	@echo "=== Импорт workflows и credentials в n8n ==="
	@bash shared/n8n-bootstrap.sh
	@echo ""
	@echo "============================================================"
	@echo "  Готово! Все сервисы запущены."
	@echo ""
	@echo "  Mattermost  : http://localhost:8065  (admin / Demo_secret1)"
	@echo "  N8N         : http://localhost:5678"
	@echo "  RabbitMQ    : http://localhost:15672  (demo / demo_secret)"
	@echo "  Postgres    : localhost:5432          (demo / demo_secret)"
	@echo "  Ollama      : http://localhost:11434"
	@echo "  GitLab mock : http://localhost:4001"
	@echo "  CVE feed    : http://localhost:4002"
	@echo "  mock-svc-lk : http://localhost:3100"
	@echo "============================================================"

# ── Генерация .env из шаблона ────────────────────────────────────────────────
.env:
	@echo "=== Создание .env из .env.example ==="
	cp .env.example .env
	@KEY=$$(openssl rand -hex 32); \
	sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$$KEY|" .env
	@echo "    N8N_ENCRYPTION_KEY сгенерирован"

# ── Управление сервисами ─────────────────────────────────────────────────────
up:
	docker compose up -d

down:
	docker compose down

clean:
	docker compose down -v
	rm -f .env

logs:
	docker compose logs -f

status:
	docker compose ps
