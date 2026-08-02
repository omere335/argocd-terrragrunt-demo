SHELL := /usr/bin/env bash
ENV_NAME ?= dev
UNIT_DIR := envs/$(ENV_NAME)/app
VALUES_FILE := $(UNIT_DIR)/values.generated.yaml
CHART_DIR := charts/hello-app
# Keep in step with K8S_VERSION in scripts/bootstrap.sh and .github/workflows/ci.yaml.
K8S_VERSION ?= 1.34.10

.DEFAULT_GOAL := help

.PHONY: help up deploy verify down render lint fmt clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Start minikube (with Calico) and install ArgoCD
	./scripts/bootstrap.sh

deploy: ## Render values with Terragrunt and apply the ArgoCD Application
	./scripts/deploy.sh

verify: ## Assert the deployment works and the security controls are real
	./scripts/verify.sh

down: ## Delete the Application and the minikube profile
	./scripts/teardown.sh

render: ## Render the Helm values file only (no cluster needed)
	cd $(UNIT_DIR) && terragrunt apply -auto-approve -input=false

fmt: ## Format Terraform and Terragrunt files
	terraform fmt -recursive
	./scripts/terragrunt-fmt.sh

lint: ## Run the static checks CI runs (kubeconform/actionlint skip with a notice if not installed)
	terraform fmt -check -recursive
	./scripts/terragrunt-fmt.sh --check --diff
	cd modules/app && terraform init -backend=false -input=false >/dev/null && terraform validate
	helm lint $(CHART_DIR) --values $(VALUES_FILE)
	@# kubeconform silently ignores files without a .yaml/.yml/.json extension
	@# ("0 resources found in 0 files", exit 0), so the temp file must keep one.
	@#
	@# set -e + a trap (not a trailing `rm -rf`) so that a helm template failure or
	@# a kubeconform strict-validation failure actually fails this recipe line -
	@# without the trap, cleanup running after those commands as a plain last
	@# statement would silently swallow their exit status and `make lint` would
	@# report success no matter what kubeconform found.
	@set -e; \
	tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	helm template hello-app $(CHART_DIR) --namespace hello-app --values $(VALUES_FILE) > $$tmpdir/rendered.yaml; \
	if command -v kubeconform >/dev/null 2>&1; then \
		kubeconform -strict -summary -kubernetes-version $(K8S_VERSION) \
			-schema-location default \
			-schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v{{ .NormalizedKubernetesVersion }}-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json' \
			$$tmpdir/rendered.yaml; \
	else \
		echo "NOTE: kubeconform not installed; skipping (CI runs it)"; \
	fi
	yamllint -c .yamllint.yaml argocd/ $(CHART_DIR)/values.yaml $(CHART_DIR)/Chart.yaml .github/workflows/
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint; \
	else \
		echo "NOTE: actionlint not installed; skipping (CI runs it)"; \
	fi

clean: ## Remove local Terraform state and caches
	rm -rf .terragrunt-state .terragrunt-cache envs/*/*/.terragrunt-cache modules/app/.terraform
