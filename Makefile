.PHONY: help deploy-latvia deploy-russia status restart-russia restart-latvia logs-russia logs-latvia update-geodata test

RUSSIA_IP ?=
LATVIA_IP ?=
RUSSIA_SSH ?= root@$(RUSSIA_IP)
LATVIA_SSH ?= root@$(LATVIA_IP)
SSH_KEY ?= $(HOME)/.ssh/id_ed25519_vpnsmart
SSH_OPTS = -i $(SSH_KEY)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

deploy-latvia: ## Deploy Latvia server (LATVIA_IP=x.x.x.x)
	@if [ -z "$(LATVIA_IP)" ]; then echo "Usage: make deploy-latvia LATVIA_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying to Latvia server $(LATVIA_IP) ==="
	rsync -avz servers/latvia/scripts/ $(LATVIA_SSH):/opt/vpnsmart/scripts/
	ssh $(SSH_OPTS) $(LATVIA_SSH) "chmod +x /opt/vpnsmart/scripts/*.sh && /opt/vpnsmart/scripts/setup.sh"
	@echo "=== Latvia deployment complete ==="

deploy-russia: ## Deploy Russia server (RUSSIA_IP=x.x.x.x)
	@if [ -z "$(RUSSIA_IP)" ]; then echo "Usage: make deploy-russia RUSSIA_IP=x.x.x.x"; exit 1; fi
	@echo "=== Deploying to Russia server $(RUSSIA_IP) ==="
	rsync -avz --exclude='.git' --exclude='*.dat' servers/russia/ $(RUSSIA_SSH):/opt/vpnsmart/
	ssh $(SSH_OPTS) $(RUSSIA_SSH) "chmod +x /opt/vpnsmart/scripts/*.sh && /opt/vpnsmart/scripts/setup.sh"
	ssh $(SSH_OPTS) $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose up -d --build"
	@echo "=== Russia deployment complete ==="

restart-russia: ## Restart Xray on Russia server
	ssh $(SSH_OPTS) $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose restart xray"

restart-latvia: ## Restart AmneziaWG on Latvia server
	ssh $(SSH_OPTS) $(LATVIA_SSH) "systemctl restart awg-quick@awg0"

logs-russia: ## Show Russia server logs
	ssh $(SSH_OPTS) $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose logs -f --tail=50"

logs-latvia: ## Show Latvia AWG status and journal
	ssh $(SSH_OPTS) $(LATVIA_SSH) "awg show; echo '---'; journalctl -u awg-quick@awg0 --no-pager -n 20"

update-geodata: ## Force update geodata on Russia server
	ssh $(SSH_OPTS) $(RUSSIA_SSH) "/opt/vpnsmart/scripts/update-geodata.sh"

status: ## Check status of both servers
	@echo "=== Russia Server ==="
	@ssh $(SSH_OPTS) $(RUSSIA_SSH) "cd /opt/vpnsmart && docker compose ps; echo '---'; awg show awg0 2>/dev/null || echo 'AWG not running'; echo '---'; ip rule show | grep fwmark || echo 'No fwmark rules'" 2>/dev/null || echo "  Cannot connect to Russia server"
	@echo ""
	@echo "=== Latvia Server ==="
	@ssh $(SSH_OPTS) $(LATVIA_SSH) "awg show awg0 2>/dev/null || echo 'AWG not running'" 2>/dev/null || echo "  Cannot connect to Latvia server"

test: ## Run routing tests (RUSSIA_IP=x.x.x.x LATVIA_IP=x.x.x.x)
	@RUSSIA_IP=$(RUSSIA_IP) LATVIA_IP=$(LATVIA_IP) bash tests/test-routing.sh
