#!/usr/bin/env bash
# Test 21: kube-burner-ocp web-burner
#
# Simulates a realistic production web application workload:
#   - Deployments with multiple containers (app + sidecar)
#   - Services, Routes, ConfigMaps, Secrets
#   - HorizontalPodAutoscaler (HPA) targeting
#   - Network policy between namespaces
#   - Ingress traffic via OpenShift Routes
#
# Use this to validate that your cluster can host a realistic production
# workload density — not just empty pods. This is the most customer-relevant
# test because it mirrors what a large enterprise app farm looks like.
#
# USAGE
#   export KUBECONFIG=~/kube-burner-project/cluster1-kubeconfig.yaml
#   chmod +x examples/workloads/ocp/web-burner-ocp.sh && ./examples/workloads/ocp/web-burner-ocp.sh
#
# PARAMETERS (override with env vars)
#   APP_NODES        — target number of app worker nodes   (default: all workers)
#   BURL             — base URL for route verification     (default: not set)
#   LB_TYPE          — LoadBalancer type (NodePort/Ingress) (default: NodePort)
#   UUID             — unique run identifier               (default: auto-generated)
#   INDEXER          — results backend: local|opensearch   (default: local)

set -euo pipefail

UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
INDEXER="${INDEXER:-local}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LB_TYPE="${LB_TYPE:-NodePort}"

echo "============================================================"
echo " Test 21: kube-burner-ocp web-burner"
echo "============================================================"
echo " LB type       : ${LB_TYPE}"
echo " UUID          : ${UUID}"
echo " Indexer       : ${INDEXER}"
echo "============================================================"
echo ""
echo " This test creates realistic web application namespaces."
echo " Each namespace includes: Deployment + Service + Route + HPA"
echo ""

kube-burner-ocp web-burner \
  --uuid="${UUID}" \
  --log-level="${LOG_LEVEL}" \
  --indexer-type="${INDEXER}" \
  --lb-type="${LB_TYPE}"

echo ""
echo "Run complete. UUID: ${UUID}"
echo "Check results in: ./collected-metrics/${UUID}/"
