.DEFAULT_GOAL := help
SHELL := /bin/bash

ANSIBLE_DIR   := ansible
INVENTORY     := $(ANSIBLE_DIR)/inventory/hosts.ini
OUTPUT_DIR    := output
KUBECONFIG_FILE := $(OUTPUT_DIR)/kubeconfig

# Pass ASK_PASS=1 for any target if the SSH user needs a sudo password
# (e.g. `make cluster ASK_PASS=1`).
ifdef ASK_PASS
BECOME_FLAG := --ask-become-pass
else
BECOME_FLAG :=
endif

ANSIBLE_PLAYBOOK := ANSIBLE_CONFIG=$(ANSIBLE_DIR)/ansible.cfg ansible-playbook -i $(INVENTORY) $(BECOME_FLAG)

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: install-deps
install-deps: ## Install required Ansible collections
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

.PHONY: keyscan
keyscan: ## Add every inventory host's SSH key to known_hosts (run once per new VM)
	@ansible-inventory -i $(INVENTORY) --list | \
		python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(v['ansible_host'] for v in d['_meta']['hostvars'].values()))" | \
		xargs -I{} ssh-keyscan -H {} >> ~/.ssh/known_hosts
	@echo "Host keys added. Review ~/.ssh/known_hosts if you have concerns before trusting these."

.PHONY: ping
ping: ## Confirm Ansible can reach every node
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/playbooks/preflight.yml

.PHONY: bootstrap
bootstrap: ## Apply base OS prep only (no k3s install)
	$(ANSIBLE_PLAYBOOK) --tags common $(ANSIBLE_DIR)/playbooks/site.yml

.PHONY: cluster
cluster: ## Bring up the full cluster: OS prep + control-plane + workers (idempotent)
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/playbooks/site.yml

.PHONY: kubeconfig
kubeconfig: ## Fetch and localize kubeconfig for remote kubectl access
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/playbooks/fetch-kubeconfig.yml
	@echo ""
	@echo "Run: export KUBECONFIG=$$(pwd)/$(KUBECONFIG_FILE)"

.PHONY: healthcheck
healthcheck: ## Verify all nodes are Ready and core pods are healthy
	$(ANSIBLE_PLAYBOOK) $(ANSIBLE_DIR)/playbooks/healthcheck.yml

.PHONY: status
status: ## Show node status via remote kubectl (requires `make kubeconfig` first)
	@if [ ! -f $(KUBECONFIG_FILE) ]; then echo "Run 'make kubeconfig' first."; exit 1; fi
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide

.PHONY: lint
lint: ## Lint playbooks and roles with ansible-lint (if installed)
	@command -v ansible-lint >/dev/null 2>&1 && ansible-lint $(ANSIBLE_DIR) || echo "ansible-lint not installed, skipping"

.PHONY: clean
clean: ## Remove locally generated artifacts (kubeconfig, etc.) - does not touch the cluster
	rm -rf $(OUTPUT_DIR)
	mkdir -p $(OUTPUT_DIR)
