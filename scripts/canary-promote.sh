#!/bin/bash

# Canary Deployment Promotion Script
# Usage: ./canary-promote.sh <weight> [namespace]
# Weight: percentage of traffic to canary (0-100)

set -e

WEIGHT=$1
NAMESPACE=${2:-devops-ai-prod}
RELEASE_NAME="devops-ai-agent"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
if [[ ! "$WEIGHT" =~ ^[0-9]+$ ]] || [[ "$WEIGHT" -lt 0 ]] || [[ "$WEIGHT" -gt 100 ]]; then
    log_error "Invalid weight. Must be between 0 and 100"
    echo "Usage: $0 <weight> [namespace]"
    exit 1
fi

log_info "Canary Deployment Promotion"
log_info "Namespace: $NAMESPACE"
log_info "Target weight: ${WEIGHT}%"
echo ""

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Check if canary is enabled
CANARY_ENABLED=$(helm get values "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.canary.enabled' 2>/dev/null || echo "false")

if [[ "$CANARY_ENABLED" != "true" ]]; then
    log_error "Canary deployment is not enabled"
    log_info "Enable it with: helm upgrade $RELEASE_NAME ... --set canary.enabled=true"
    exit 1
fi

# Get current weight
CURRENT_WEIGHT=$(helm get values "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.canary.weight' 2>/dev/null || echo "0")
log_info "Current canary weight: ${CURRENT_WEIGHT}%"

# Special case: weight 0 = rollback to stable
if [[ "$WEIGHT" -eq 0 ]]; then
    log_warning "This will route ALL traffic to stable version (rollback)"
    read -p "Continue? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
fi

# Special case: weight 100 = promote canary to stable
if [[ "$WEIGHT" -eq 100 ]]; then
    log_warning " This will promote canary to stable (complete rollout)"
    read -p "Continue? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
fi

# Check canary deployment health
log_info "Checking canary deployment health..."
CANARY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=devops-ai-agent,version=canary -o json)
READY_PODS=$(echo "$CANARY_PODS" | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
TOTAL_PODS=$(echo "$CANARY_PODS" | jq '.items | length')

if [[ "$TOTAL_PODS" -eq 0 ]]; then
    log_error "No canary pods found"
    exit 1
fi

if [[ "$READY_PODS" -ne "$TOTAL_PODS" ]]; then
    log_error "Canary pods not healthy. Ready: $READY_PODS/$TOTAL_PODS"
    log_info "Check pod status:"
    kubectl get pods -n "$NAMESPACE" -l version=canary
    exit 1
fi

log_success "Canary deployment healthy ($READY_PODS/$TOTAL_PODS pods ready)"
echo ""

# Progressive rollout recommendations
if [[ "$WEIGHT" -gt "$CURRENT_WEIGHT" ]]; then
    INCREMENT=$((WEIGHT - CURRENT_WEIGHT))
    if [[ "$INCREMENT" -gt 20 ]]; then
        log_warning "Large weight increase detected (+${INCREMENT}%)"
        log_warning "Consider progressive rollout: 10% → 25% → 50% → 100%"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            exit 0
        fi
    fi
fi

# Update canary weight
log_info "Updating canary weight to ${WEIGHT}%..."

helm upgrade "$RELEASE_NAME" ./helm/devops-ai-agent \
    -n "$NAMESPACE" \
    --reuse-values \
    --set canary.enabled=true \
    --set canary.weight="$WEIGHT" \
    --wait \
    --timeout 5m

log_success "Canary weight updated to ${WEIGHT}%"
echo ""

# Monitor traffic distribution
log_info "Monitoring traffic distribution for 30 seconds..."
sleep 5

# Check metrics (if Prometheus is available)
if kubectl get svc prometheus-server -n monitoring &>/dev/null; then
    log_info "Fetching metrics from Prometheus..."

    # Port forward Prometheus temporarily
    kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &>/dev/null &
    PF_PID=$!
    sleep 3

    # Query request rate per version
    STABLE_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{version="stable"}[1m])' | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    CANARY_RATE=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{version="canary"}[1m])' | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")

    kill $PF_PID 2>/dev/null || true

    log_info "Request rates:"
    echo "  Stable: $STABLE_RATE req/s"
    echo "  Canary: $CANARY_RATE req/s"
fi

echo ""

# Check error rates
log_info "Checking error rates..."
ERROR_COUNT=$(kubectl logs -n "$NAMESPACE" -l version=canary --tail=100 2>/dev/null | grep -i "error" | wc -l || echo "0")

if [[ "$ERROR_COUNT" -gt 10 ]]; then
    log_warning "High error count detected in canary: $ERROR_COUNT errors in last 100 log lines"
    log_warning "Consider rolling back or investigating"
else
    log_success "Error rate acceptable ($ERROR_COUNT errors)"
fi

echo ""

# Completion message based on weight
if [[ "$WEIGHT" -eq 0 ]]; then

    log_success "  Rollback completed - 100% traffic on stable"

    echo ""
    log_info "Canary deployment can now be removed"

elif [[ "$WEIGHT" -eq 100 ]]; then
    log_success "  Canary promoted! - 100% traffic on canary"
    echo ""
    log_info "Next steps:"
    echo "  1. Monitor application for 15-30 minutes"
    echo "  2. If stable, promote canary to stable:"
    echo "     helm upgrade $RELEASE_NAME ... --set canary.enabled=false"
    echo "  3. Update stable image tag to match canary"

else

    log_success "  Traffic distribution: ${WEIGHT}% canary, $((100-WEIGHT))% stable"
    echo ""
    log_info "Recommended next steps:"

    if [[ "$WEIGHT" -lt 25 ]]; then
        log_info "  → Continue monitoring for 10-15 minutes"
        log_info "  → If metrics look good: $0 25 $NAMESPACE"
    elif [[ "$WEIGHT" -lt 50 ]]; then
        log_info "  → Continue monitoring for 15-20 minutes"
        log_info "  → If metrics look good: $0 50 $NAMESPACE"
    elif [[ "$WEIGHT" -lt 100 ]]; then
        log_info "  → Continue monitoring for 20-30 minutes"
        log_info "  → If metrics look good: $0 100 $NAMESPACE"
    fi

    log_info "  → Rollback if issues: $0 $CURRENT_WEIGHT $NAMESPACE"
fi

echo ""
log_info "Monitoring commands:"
echo "  Logs:    kubectl logs -f -l version=canary -n $NAMESPACE"
echo "  Metrics: kubectl top pods -n $NAMESPACE -l version=canary"
echo "  Status:  kubectl get pods -n $NAMESPACE -l version=canary"
echo ""

# Optional: Generate report
read -p "Generate detailed canary report? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    REPORT_FILE="/tmp/canary-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "Canary Deployment Report"
        echo "Timestamp: $(date)"
        echo "Namespace: $NAMESPACE"
        echo "Release: $RELEASE_NAME"
        echo "Previous Weight: ${CURRENT_WEIGHT}%"
        echo "New Weight: ${WEIGHT}%"
        echo ""
        echo "=== Canary Pods ==="
        kubectl get pods -n "$NAMESPACE" -l version=canary
        echo ""
        echo "=== Stable Pods ==="
        kubectl get pods -n "$NAMESPACE" -l version=stable
        echo ""
        echo "=== Recent Logs (Canary) ==="
        kubectl logs -n "$NAMESPACE" -l version=canary --tail=50
    } > "$REPORT_FILE"

    log_success "Report saved to: $REPORT_FILE"
fi

exit 0