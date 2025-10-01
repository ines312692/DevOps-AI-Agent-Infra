#!/bin/bash

# Blue-Green Deployment Switch Script
# Usage: ./blue-green-switch.sh <blue|green> [namespace]

set -e

COLOR=$1
NAMESPACE=${2:-devops-ai-prod}
RELEASE_NAME="devops-ai-agent"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

function log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Validate input
if [[ "$COLOR" != "blue" && "$COLOR" != "green" ]]; then
    log_error "Invalid color. Usage: $0 <blue|green> [namespace]"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Check if deployment exists
if ! kubectl get deployment "${RELEASE_NAME}-${COLOR}" -n "$NAMESPACE" &> /dev/null; then
    log_error "Deployment '${RELEASE_NAME}-${COLOR}' not found in namespace '$NAMESPACE'"
    exit 1
fi

log_info "Starting Blue-Green switch to: ${COLOR^^}"
log_info "Namespace: $NAMESPACE"
echo ""

# Step 1: Check target deployment health
log_info "Step 1/5: Checking ${COLOR} deployment health..."
READY_REPLICAS=$(kubectl get deployment "${RELEASE_NAME}-${COLOR}" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
DESIRED_REPLICAS=$(kubectl get deployment "${RELEASE_NAME}-${COLOR}" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

if [[ "$READY_REPLICAS" != "$DESIRED_REPLICAS" ]]; then
    log_error "${COLOR} deployment is not healthy. Ready: $READY_REPLICAS, Desired: $DESIRED_REPLICAS"
    exit 1
fi
log_success "${COLOR} deployment is healthy ($READY_REPLICAS/$DESIRED_REPLICAS pods ready)"
echo ""

# Step 2: Test target deployment
log_info "Step 2/5: Testing ${COLOR} deployment..."
SERVICE_NAME="${RELEASE_NAME}-${COLOR}"
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "deployment-color=${COLOR}" -o jsonpath='{.items[0].metadata.name}')

if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- curl -sf http://localhost:8501/healthz &> /dev/null; then
    log_success "${COLOR} deployment health check passed"
else
    log_error "${COLOR} deployment health check failed"
    exit 1
fi
echo ""

# Step 3: Get current active color
log_info "Step 3/5: Checking current active deployment..."
CURRENT_COLOR=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}')
log_info "Current active: ${CURRENT_COLOR^^}"

if [[ "$CURRENT_COLOR" == "$COLOR" ]]; then
    log_warning "${COLOR} is already the active deployment"
    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
fi
echo ""

# Step 4: Confirmation
log_warning "  You are about to switch traffic from ${CURRENT_COLOR^^} to ${COLOR^^}"
read -p "Are you sure? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Operation cancelled"
    exit 0
fi

# Step 5: Switch traffic
log_info "Step 4/5: Switching traffic to ${COLOR}..."

# Update the main service selector using Helm
helm upgrade "$RELEASE_NAME" ./helm/devops-ai-agent \
    -n "$NAMESPACE" \
    --reuse-values \
    --set blueGreen.activeColor="$COLOR" \
    --wait

log_success "Traffic switched to ${COLOR^^}"
echo ""

# Step 6: Verify switch
log_info "Step 5/5: Verifying switch..."
NEW_COLOR=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.deployment-color}')

if [[ "$NEW_COLOR" == "$COLOR" ]]; then
    log_success " Switch verified. Active deployment: ${COLOR^^}"
    echo ""
    log_info "Monitoring traffic..."
    kubectl get pods -n "$NAMESPACE" -l "deployment-color=${COLOR}" -w &
    WATCH_PID=$!
    sleep 10
    kill $WATCH_PID 2>/dev/null || true
else
    log_error "Switch verification failed. Expected: $COLOR, Got: $NEW_COLOR"
    exit 1
fi

echo ""
log_success "  Blue-Green switch completed successfully!"
log_success "  Active deployment: ${COLOR^^}"
echo ""

# Show next steps
log_info "Next steps:"
echo "  1. Monitor the application: kubectl logs -f -l deployment-color=${COLOR} -n ${NAMESPACE}"
echo "  2. Check metrics in Grafana"
echo "  3. If issues occur, rollback: $0 ${CURRENT_COLOR} ${NAMESPACE}"
echo ""

# Optional: Scale down inactive deployment
read -p "Do you want to scale down the inactive (${CURRENT_COLOR}) deployment? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl scale deployment "${RELEASE_NAME}-${CURRENT_COLOR}" --replicas=0 -n "$NAMESPACE"
    log_success "Scaled down ${CURRENT_COLOR} deployment"
fi

exit 0