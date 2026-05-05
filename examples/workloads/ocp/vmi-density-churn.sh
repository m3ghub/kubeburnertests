#!/usr/bin/env bash
# Test 22: kube-burner-ocp vmi-density with churn
#
# Extends Test 20 (vmi-density) with a continuous churn phase:
#   - Creates an initial density of VMIs across all nodes
#   - Then cycles (creates + deletes) a percentage of VMIs continuously
#   - Measures whether the KubeVirt control plane can handle steady-state churn
#     without falling behind or accumulating stuck VMIs
#
# This is the endurance / soak test for OpenShift Virtualization.
# Run for 30+ minutes to expose memory leaks in virt-controller,
# excessive etcd key accumulation, or virt-handler lock contention.
#
# USAGE
#   export KUBECONFIG=~/kube-burner-project/cluster1-kubeconfig.yaml
#   chmod +x examples/workloads/ocp/vmi-density-churn.sh && ./examples/workloads/ocp/vmi-density-churn.sh
#
# PARAMETERS
#   VMIS_PER_NODE    — initial VMIs per node               (default: 20)
#   CHURN_PERCENT    — percentage of VMIs to churn         (default: 20)
#   CHURN_CYCLES     — number of churn iterations          (default: 5)
#   CHURN_DURATION   — seconds between churn cycles        (default: 60)
#   UUID             — unique run identifier               (default: auto-generated)

set -euo pipefail

VMIS_PER_NODE="${VMIS_PER_NODE:-20}"
CHURN_PERCENT="${CHURN_PERCENT:-20}"
CHURN_CYCLES="${CHURN_CYCLES:-5}"
CHURN_DURATION="${CHURN_DURATION:-60}"
UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
INDEXER="${INDEXER:-local}"
LOG_LEVEL="${LOG_LEVEL:-info}"

echo "============================================================"
echo " Test 22: vmi-density with churn (endurance test)"
echo "============================================================"
echo " VMIs per node : ${VMIS_PER_NODE}"
echo " Churn percent : ${CHURN_PERCENT}%"
echo " Churn cycles  : ${CHURN_CYCLES}"
echo " Churn pause   : ${CHURN_DURATION}s between cycles"
echo " UUID          : ${UUID}"
echo "============================================================"
echo ""
echo " This test runs for approximately $((CHURN_CYCLES * (CHURN_DURATION + 60))) seconds."
echo " Monitor virt-controller memory during the run:"
echo "   oc top pods -n kubevirt --sort-by=memory"
echo ""

kube-burner-ocp vmi-density \
  --vmis-per-node="${VMIS_PER_NODE}" \
  --churn=true \
  --churn-percent="${CHURN_PERCENT}" \
  --churn-cycles="${CHURN_CYCLES}" \
  --churn-duration="${CHURN_DURATION}" \
  --uuid="${UUID}" \
  --log-level="${LOG_LEVEL}" \
  --indexer-type="${INDEXER}"

echo ""
echo "Endurance run complete. UUID: ${UUID}"
