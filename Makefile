.PHONY: help lint test deploy-dev deploy-staging deploy-prod rollback clean

# Variables
CHART_PATH := helm/devops-ai-agent
NAMESPACE_DEV := devops-ai-dev
NAMESPACE_STAGING := devops-ai-staging
NAMESPACE_PROD := devops-ai-prod
RELEASE_NAME := devops-ai-agent

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Lint Helm chart
	@echo " Linting Helm chart..."
	helm lint $(CHART_PATH)
	helm lint $(CHART_PATH) -f $(CHART_PATH)/values-dev.yaml
	helm lint $(CHART_PATH) -f $(CHART_PATH)/values-staging.yaml
	helm lint $(CHART_PATH) -f $(CHART_PATH)/values-prod.yaml
	@echo " Lint completed"

template: ## Template Helm chart
	@echo " Templating Helm chart..."
	helm template $(RELEASE_NAME) $(CHART_PATH) --debug

template-dev: ## Template dev values
	helm template $(RELEASE_NAME) $(CHART_PATH) -f $(CHART_PATH)/values-dev.yaml --debug

template-prod: ## Template prod values
	helm template $(RELEASE_NAME) $(CHART_PATH) -f $(CHART_PATH)/values-prod.yaml --debug

dry-run-dev: ## Dry run dev deployment
	@echo " Dry run for dev..."
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		-f $(CHART_PATH)/values-dev.yaml \
		--namespace $(NAMESPACE_DEV) \
		--create-namespace \
		--dry-run --debug

dry-run-prod: ## Dry run prod deployment
	@echo " Dry run for production..."
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		-f $(CHART_PATH)/values-prod.yaml \
		--namespace $(NAMESPACE_PROD) \
		--create-namespace \
		--dry-run --debug

deploy-dev: ## Deploy to development
	@echo " Deploying to development..."
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		-f $(CHART_PATH)/values-dev.yaml \
		--namespace $(NAMESPACE_DEV) \
		--create-namespace \
		--wait \
		--timeout 5m
	@echo " Deployed to development"
	@make status-dev

deploy-staging: ## Deploy to staging
	@echo " Deploying to staging..."
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		-f $(CHART_PATH)/values-staging.yaml \
		--namespace $(NAMESPACE_STAGING) \
		--create-namespace \
		--wait \
		--timeout 10m
	@echo " Deployed to staging"
	@make status-staging

deploy-prod: ## Deploy to production (requires confirmation)
	@echo "️  WARNING: You are about to deploy to PRODUCTION"
	@read -p "Type 'yes' to continue: " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo " Deployment cancelled"; \
		exit 1; \
	fi
	@echo " Deploying to production..."
	helm upgrade --install $(RELEASE_NAME) $(CHART_PATH) \
		-f $(CHART_PATH)/values-prod.yaml \
		--namespace $(NAMESPACE_PROD) \
		--create-namespace \
		--wait \
		--timeout 15m
	@echo " Deployed to production"
	@make status-prod

status-dev: ## Show dev deployment status
	@echo " Development status:"
	kubectl get all -n $(NAMESPACE_DEV) -l app.kubernetes.io/name=devops-ai-agent

status-staging: ## Show staging deployment status
	@echo " Staging status:"
	kubectl get all -n $(NAMESPACE_STAGING) -l app.kubernetes.io/name=devops-ai-agent

status-prod: ## Show production deployment status
	@echo " Production status:"
	kubectl get all -n $(NAMESPACE_PROD) -l app.kubernetes.io/name=devops-ai-agent

logs-dev: ## Show dev logs
	kubectl logs -f -l app.kubernetes.io/name=devops-ai-agent -n $(NAMESPACE_DEV)

logs-staging: ## Show staging logs
	kubectl logs -f -l app.kubernetes.io/name=devops-ai-agent -n $(NAMESPACE_STAGING)

logs-prod: ## Show production logs
	kubectl logs -f -l app.kubernetes.io/name=devops-ai-agent -n $(NAMESPACE_PROD)

port-forward-dev: ## Port forward dev service
	@echo " Port forwarding dev service to localhost:8501..."
	kubectl port-forward -n $(NAMESPACE_DEV) svc/$(RELEASE_NAME) 8501:8501

port-forward-staging: ## Port forward staging service
	@echo " Port forwarding staging service to localhost:8501..."
	kubectl port-forward -n $(NAMESPACE_STAGING) svc/$(RELEASE_NAME) 8501:8501

port-forward-prod: ## Port forward production service
	@echo " Port forwarding production service to localhost:8501..."
	kubectl port-forward -n $(NAMESPACE_PROD) svc/$(RELEASE_NAME) 8501:8501

rollback-dev: ## Rollback dev deployment
	@echo " Rolling back development..."
	helm rollback $(RELEASE_NAME) -n $(NAMESPACE_DEV)
	@echo " Rollback completed"

rollback-staging: ## Rollback staging deployment
	@echo " Rolling back staging..."
	helm rollback $(RELEASE_NAME) -n $(NAMESPACE_STAGING)
	@echo " Rollback completed"

rollback-prod: ## Rollback production deployment
	@echo "  WARNING: You are about to rollback PRODUCTION"
	@read -p "Type 'yes' to continue: " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo " Rollback cancelled"; \
		exit 1; \
	fi
	@echo " Rolling back production..."
	helm rollback $(RELEASE_NAME) -n $(NAMESPACE_PROD)
	@echo " Rollback completed"

blue-green-switch-blue: ## Switch production to blue
	@echo " Switching to BLUE deployment..."
	./scripts/blue-green-switch.sh blue $(NAMESPACE_PROD)

blue-green-switch-green: ## Switch production to green
	@echo " Switching to GREEN deployment..."
	./scripts/blue-green-switch.sh green $(NAMESPACE_PROD)

history-dev: ## Show dev release history
	helm history $(RELEASE_NAME) -n $(NAMESPACE_DEV)

history-staging: ## Show staging release history
	helm history $(RELEASE_NAME) -n $(NAMESPACE_STAGING)

history-prod: ## Show production release history
	helm history $(RELEASE_NAME) -n $(NAMESPACE_PROD)

delete-dev: ## Delete dev deployment
	@echo "  Deleting development deployment..."
	helm uninstall $(RELEASE_NAME) -n $(NAMESPACE_DEV)
	kubectl delete namespace $(NAMESPACE_DEV)
	@echo " Development deleted"

delete-staging: ## Delete staging deployment
	@echo "  Deleting staging deployment..."
	helm uninstall $(RELEASE_NAME) -n $(NAMESPACE_STAGING)
	kubectl delete namespace $(NAMESPACE_STAGING)
	@echo " Staging deleted"

delete-prod: ## Delete production deployment (DANGEROUS!)
	@echo "DANGER: Deleting PRODUCTION deployment "
	@read -p "Type 'DELETE-PRODUCTION' to continue: " confirm; \
	if [ "$$confirm" != "DELETE-PRODUCTION" ]; then \
		echo "Deletion cancelled"; \
		exit 1; \
	fi
	helm uninstall $(RELEASE_NAME) -n $(NAMESPACE_PROD)
	kubectl delete namespace $(NAMESPACE_PROD)
	@echo " Production deleted"

install-argocd: ## Install ArgoCD
	@echo " Installing ArgoCD..."
	kubectl create namespace argocd || true
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "ArgoCD installed"
	@echo "Get admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
	@echo " Port forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"

deploy-argocd-apps: ## Deploy ArgoCD applications
	@echo " Deploying ArgoCD applications..."
	kubectl apply -f argocd/projects/devops-ai-project.yaml
	kubectl apply -f argocd/applications/dev-application.yaml
	kubectl apply -f argocd/applications/staging-application.yaml
	kubectl apply -f argocd/applications/prod-application.yaml
	@echo " ArgoCD applications deployed"

install-prometheus: ## Install Prometheus stack
	@echo " Installing Prometheus stack..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--create-namespace \
		--wait
	@echo " Prometheus installed"
	@echo " Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"

test-health: ## Test application health
	@echo " Testing health endpoints..."
	@if curl -sf http://localhost:8501/healthz; then \
		echo " Health check passed"; \
	else \
		echo " Health check failed"; \
		exit 1; \
	fi

package: ## Package Helm chart
	@echo " Packaging Helm chart..."
	helm package $(CHART_PATH)
	@echo " Chart packaged"

clean: ## Clean temporary files
	@echo " Cleaning..."
	rm -f *.tgz
	@echo " Cleaned"

validate-k8s: ## Validate Kubernetes connection
	@echo " Validating Kubernetes connection..."
	kubectl cluster-info
	kubectl get nodes
	@echo " Connection validated"