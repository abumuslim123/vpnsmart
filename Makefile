.PHONY: help deploy-exit deploy-entry status restart-entry restart-exit logs-entry logs-exit update-geodata test

ENTRY_IP ?=
EXIT_IP ?=
ENTRY_SSH ?= root@$(ENTRY_IP)
EXIT_SSH ?= root@$(EXIT_IP)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

deploy-exit: ## Deploy exit server (EXIT_IP=x.x.x.x)
	@if [ -z "$(EXIT_IP)" ]; then echo "Usage: make deploy-exit EXIT_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying exit server $(EXIT_IP) ==="
	scp servers/latvia/scripts/setup.sh $(EXIT_SSH):/tmp/vpnsmart-setup.sh
	ssh $(EXIT_SSH) "chmod +x /tmp/vpnsmart-setup.sh && /tmp/vpnsmart-setup.sh && rm /tmp/vpnsmart-setup.sh"
	@echo "=== Exit server deployment complete ==="

deploy-entry: ## Deploy entry server (ENTRY_IP=x.x.x.x)
	@if [ -z "$(ENTRY_IP)" ]; then echo "Usage: make deploy-entry ENTRY_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying entry server $(ENTRY_IP) ==="
	scp servers/russia/docker-compose.yml $(ENTRY_SSH):/opt/vpnsmart/docker-compose.yml
	scp servers/russia/bot/* $(ENTRY_SSH):/opt/vpnsmart/bot/
	scp servers/russia/scripts/* $(ENTRY_SSH):/opt/vpnsmart/scripts/
	ssh $(ENTRY_SSH) "chmod +x /opt/vpnsmart/scripts/*.sh && /opt/vpnsmart/scripts/setup.sh"
	ssh $(ENTRY_SSH) "cd /opt/vpnsmart && docker compose up -d --build"
	@echo "=== Entry server deployment complete ==="

restart-entry: ## Restart Xray on entry server
	ssh $(ENTRY_SSH) "cd /opt/vpnsmart && docker compose restart xray"

restart-exit: ## Restart AmneziaWG on exit server
	ssh $(EXIT_SSH) "systemctl restart awg-quick@awg0"

logs-entry: ## Show entry server logs
	ssh $(ENTRY_SSH) "cd /opt/vpnsmart && docker compose logs -f --tail=50"

logs-exit: ## Show exit server AWG status and journal
	ssh $(EXIT_SSH) "awg show; echo '---'; journalctl -u awg-quick@awg0 --no-pager -n 20"

update-geodata: ## Force update geodata on entry server
	ssh $(ENTRY_SSH) "/opt/vpnsmart/scripts/update-geodata.sh"

status: ## Check status of both servers
	@echo "=== Entry Server ==="
	@ssh $(ENTRY_SSH) "cd /opt/vpnsmart && docker compose ps; echo '---'; awg show awg0 2>/dev/null || echo 'AWG not running'; echo '---'; ip rule show | grep fwmark || echo 'No fwmark rules'" 2>/dev/null || echo "  Cannot connect"
	@echo ""
	@echo "=== Exit Server ==="
	@ssh $(EXIT_SSH) "awg show awg0 2>/dev/null || echo 'AWG not running'" 2>/dev/null || echo "  Cannot connect"

test: ## Run routing tests (ENTRY_IP=x.x.x.x EXIT_IP=x.x.x.x)
	@RUSSIA_IP=$(ENTRY_IP) LATVIA_IP=$(EXIT_IP) bash tests/test-routing.sh
