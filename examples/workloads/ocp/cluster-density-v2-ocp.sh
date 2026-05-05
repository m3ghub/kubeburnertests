#!/usr/bin/env bash
# Test 19: kube-burner-ocp cluster-density-v2
#
# Creates a realistic OpenShift workload per namespace:
#   - Deployments, Services, Routes, ConfigMaps, Secrets
#   - Probes (liveness + readiness), resource limits
#   - Scale-up/down cycle to stress the scheduler and HPA paths
#
# This is the PRIMARY test for validating OpenShift control-plane scalability
# under a production-representative mixed workload. Use it before major cluster
# upgrades and after adding worker nodes.
#
# USAGE
#   export KUBECONFIG=~/kube-burner-project/cluster1-kubeconfig.yaml
#   chmod +x examples/workloads/ocp/cluster-density-v2-ocp.sh && ./examples/workloads/ocp/cluster-density-v2-ocp.sh
#
# PARAMETERS (override with env vars)
#   ITERATIONS       — number of namespaces to create     (default: 500)
#   CHURN            — enable churn cycling (true/false)   (default: false)
#   CHURN_PERCENT    — percentage of namespaces to churn   (default: 10)
#   CHURN_CYCLES     — number of churn cycles              (default: 2)
#   UUID             — unique run identifier               (default: auto-generated)
#   INDEXER          — results backend: local|opensearch   (default: local)

set -euo pipefail

ITERATIONS="${ITERATIONS:-500}"
CHURN="${CHURN:-false}"
CHURN_PERCENT="${CHURN_PERCENT:-10}"
CHURN_CYCLES="${CHURN_CYCLES:-2}"
UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
INDEXER="${INDEXER:-local}"
LOG_LEVEL="${LOG_LEVEL:-info}"

echo "============================================================"
echo " Test 19: kube-burner-ocp cluster-density-v2"
echo "============================================================"
echo " Iterations    : ${ITERATIONS} namespaces"
echo " Churn enabled : ${CHURN}"
if [[ "${CHURN}" == "true" ]]; then
  echo " Churn percent : ${CHURN_PERCENT}%"
  echo " Churn cycles  : ${CHURN_CYCLES}"
fi
echo " UUID          : ${UUID}"
echo " Indexer       : ${INDEXER}"
echo "============================================================"

CHURN_FLAGS=""
if [[ "${CHURN}" == "true" ]]; then
  CHURN_FLAGS="--churn=true --churn-percent=${CHURN_PERCENT} --churn-cycles=${CHURN_CYCLES}"
fi

# shellcheck disable=SC2086
kube-burner-ocp cluster-density-v2 \
  --iterations="${ITERATIONS}" \
  --uuid="${UUID}" \
  --log-level="${LOG_LEVEL}" \
  --indexer-type="${INDEXER}" \
  ${CHURN_FLAGS}

echo ""
echo "Run complete. UUID: ${UUID}"
echo "Check results in: ./collected-metrics/${UUID}/"
