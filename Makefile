SHELL  := /bin/bash
TF     := terraform -chdir=terraform
LOAD   := source scripts/common.sh && require_ccloud_creds
REMOTE := scripts/remote.sh

.DEFAULT_GOAL := help
.PHONY: help setup pki up outputs demo demo-batch java-demo shell revoke revoke-reset down clean

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

setup: ## Check prerequisites and credentials
	@scripts/check-prereqs.sh

pki: ## Generate the demo CAs and client certificates (pki/out/)
	@scripts/pki.sh init

up: pki ## Provision everything: Confluent Cloud + AWS VPC, PrivateLink, client host
	@test -f terraform/terraform.tfvars || { echo "[error] copy terraform/terraform.tfvars.example to terraform/terraform.tfvars first"; exit 1; }
	@$(LOAD) && $(TF) init -upgrade -input=false >/dev/null && $(TF) apply -input=false
	@mkdir -p .demo && $(TF) output -raw bootstrap_servers > .demo/bootstrap
	@printf 'INSTANCE_ID=%s\nBUNDLE_BUCKET=%s\nAWS_REGION=%s\n' \
		"$$($(TF) output -raw client_instance_id)" "$$($(TF) output -raw bundle_bucket)" "$$($(TF) output -raw region)" > .demo/remote.env
	@echo "[ok] bootstrap: $$(cat .demo/bootstrap)"
	@$(REMOTE) wait

outputs: ## Show Terraform outputs (IDs, pools, bootstrap)
	@$(TF) output

demo: ## Run the guided demo on the client host (interactive, needs session-manager-plugin)
	@$(REMOTE) tty scripts/demo.sh

demo-batch: ## Run the demo non-interactively and print the output
	@$(REMOTE) run DEMO_PAUSE=0 scripts/demo.sh

java-demo: ## Same idea with the Kafka Java CLI tools on the client host
	@$(REMOTE) run 'clients/java-cli.sh orders-producer kafka-topics --list \
	  && echo "{\"order_id\":\"java-1\",\"amount\":42}" | clients/java-cli.sh orders-producer kafka-console-producer --topic orders \
	  && clients/java-cli.sh analytics-consumer kafka-console-consumer --topic orders --group analytics-java --from-beginning --max-messages 3 --timeout-ms 30000'

shell: ## Open a shell on the client host
	@$(REMOTE) shell

revoke: ## Revoke legacy-producer's certificate via CRL and show it being rejected
	@scripts/revoke-demo.sh

revoke-reset: ## Reissue legacy-producer and upload a fresh CRL
	@scripts/revoke-demo.sh reset

down: ## Destroy everything this demo created (Confluent Cloud and AWS)
	@$(LOAD) && $(TF) destroy -input=false
	@rm -f .demo/bootstrap .demo/remote.env

clean: ## Remove generated certificates and local state (run after down)
	@scripts/pki.sh clean
	@rm -rf .demo .venv
