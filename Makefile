.PHONY: keys deploy-finland deploy-russia add-client test help

RUSSIA_IP ?=
FINLAND_IP ?=
RUSSIA_SSH ?= root@$(RUSSIA_IP)
FINLAND_SSH ?= root@$(FINLAND_IP)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

keys: ## Generate all keys (requires sing-box and wg locally)
	@bash servers/russia/scripts/generate-keys.sh

deploy-finland: ## Deploy Finland server (FINLAND_IP=x.x.x.x)
	@if [ -z "$(FINLAND_IP)" ]; then echo "Usage: make deploy-finland FINLAND_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying to Finland server $(FINLAND_IP) ==="
	rsync -avz --exclude='.git' servers/finland/ $(FINLAND_SSH):/opt/vpnsmart/
	ssh $(FINLAND_SSH) "chmod +x /opt/vpnsmart/scripts/setup.sh && /opt/vpnsmart/scripts/setup.sh"
	ssh $(FINLAND_SSH) "cd /opt/vpnsmart && docker compose up -d"
	@echo "=== Finland deployment complete ==="

deploy-russia: ## Deploy Russia server (RUSSIA_IP=x.x.x.x)
	@if [ -z "$(RUSSIA_IP)" ]; then echo "Usage: make deploy-russia RUSSIA_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying to Russia server $(RUSSIA_IP) ==="
	rsync -avz --exclude='.git' servers/russia/ $(RUSSIA_SSH):/opt/vpnsmart/
	ssh $(RUSSIA_SSH) "chmod +x /opt/vpnsmart/scripts/*.sh && /opt/vpnsmart/scripts/setup.sh"
	ssh $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose up -d"
	@echo "=== Russia deployment complete ==="

add-client: ## Add a new client (NAME=xxx RUSSIA_IP=x.x.x.x PUBLIC_KEY=xxx SHORT_ID=xxx)
	@if [ -z "$(NAME)" ]; then echo "Usage: make add-client NAME=my-phone RUSSIA_IP=x.x.x.x PUBLIC_KEY=xxx SHORT_ID=xxx"; exit 1; fi
	@bash servers/russia/scripts/add-client.sh "$(NAME)" "$(RUSSIA_IP)" "$(PUBLIC_KEY)" "$(SHORT_ID)"

client-config: ## Generate client config (SERVER_IP=x.x.x.x UUID=xxx PUBLIC_KEY=xxx SHORT_ID=xxx)
	@bash clients/generate-client-config.sh \
		--server-ip "$(SERVER_IP)" \
		--uuid "$(UUID)" \
		--public-key "$(PUBLIC_KEY)" \
		--short-id "$(SHORT_ID)"

test: ## Run routing tests (RUSSIA_IP=x.x.x.x FINLAND_IP=x.x.x.x)
	@RUSSIA_IP=$(RUSSIA_IP) FINLAND_IP=$(FINLAND_IP) bash tests/test-routing.sh

test-direct: ## Test direct routing to Russian sites
	@bash tests/test-direct.sh

restart-russia: ## Restart sing-box on Russia server
	ssh $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose restart"

restart-finland: ## Restart WireGuard on Finland server
	ssh $(FINLAND_SSH) "cd /opt/vpnsmart && docker compose restart"

logs-russia: ## Show Russia server logs
	ssh $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose logs -f --tail=50"

logs-finland: ## Show Finland server logs
	ssh $(FINLAND_SSH) "cd /opt/vpnsmart && docker compose logs -f --tail=50"

status: ## Check status of both servers
	@echo "=== Russia Server ==="
	@ssh $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose ps" 2>/dev/null || echo "  Cannot connect to Russia server"
	@echo ""
	@echo "=== Finland Server ==="
	@ssh $(FINLAND_SSH) "cd /opt/vpnsmart && docker compose ps" 2>/dev/null || echo "  Cannot connect to Finland server"
