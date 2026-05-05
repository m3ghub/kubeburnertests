#!/usr/bin/env bash
# Test 18: kube-burner-ocp node-density
#
# Deploys 1 pod per worker node by default, scaling to test scheduler throughput.
# Unlike the generic pod-density test, this variant:
#   - Uses OpenShift-tuned tolerations and node selectors
#   - Collects the full OCP metrics profile (etcd, API server, scheduler)
#   - Enforces OCP-specific alert thresholds
#
# USAGE
#   export KUBECONFIG=~/kube-burner-project/cluster1-kubeconfig.yaml
#   chmod +x examples/workloads/ocp/node-density-ocp.sh && ./examples/workloads/ocp/node-density-ocp.sh
#
# PARAMETERS (override with env vars)
#   PODS_PER_NODE    — pods scheduled per worker node     (default: 245)
#   NAMESPACE_PREFIX — namespace prefix for test pods     (default: node-density)
#   ITERATIONS       — number of namespaces to create     (default: 1)
#   UUID             — unique run identifier               (default: auto-generated)
#   INDEXER          — results backend: local|opensearch   (default: local)

set -euo pipefail

PODS_PER_NODE="${PODS_PER_NODE:-245}"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-node-density}"
ITERATIONS="${ITERATIONS:-1}"
UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
INDEXER="${INDEXER:-local}"
LOG_LEVEL="${LOG_LEVEL:-info}"

echo "============================================================"
echo " Test 18: kube-burner-ocp node-density"
echo "============================================================"
echo " Pods per node : ${PODS_PER_NODE}"
echo " UUID          : ${UUID}"
echo " Indexer       : ${INDEXER}"
echo " Kubeconfig    : ${KUBECONFIG:-~/.kube/config}"
echo "============================================================"

kube-burner-ocp node-density \
  --pods-per-node="${PODS_PER_NODE}" \
  --uuid="${UUID}" \
  --iterations="${ITERATIONS}" \
  --log-level="${LOG_LEVEL}" \
  --indexer-type="${INDEXER}"

echo ""
echo "Run complete. UUID: ${UUID}"
echo "Check results in: ./collected-metrics/${UUID}/"
