#!/usr/bin/env bash
# Test 20: kube-burner-ocp vmi-density
#
# Creates VirtualMachineInstances (VMIs) across worker nodes to test:
#   - KubeVirt control-plane throughput (virt-controller, virt-api)
#   - virt-handler reconcile loop at density
#   - etcd write amplification per VMI object
#   - Node-level resource contention (memory balloon, CPU pinning)
#
# CRITICAL: This is the flagship OpenShift Virtualization scale test.
# Run this to establish your cluster's maximum VM density baseline.
#
# USAGE
#   export KUBECONFIG=~/kube-burner-project/cluster1-kubeconfig.yaml
#   chmod +x examples/workloads/ocp/vmi-density-ocp.sh && ./examples/workloads/ocp/vmi-density-ocp.sh
#
# PARAMETERS (override with env vars)
#   VMIS_PER_NODE    — VMIs per worker node                (default: 25)
#   NAMESPACE_PREFIX — namespace prefix                    (default: vmi-density)
#   UUID             — unique run identifier               (default: auto-generated)
#   INDEXER          — results backend: local|opensearch   (default: local)
#   IMAGE            — container disk image URL            (default: quay.io/containerdisks/fedora:latest)

set -euo pipefail

VMIS_PER_NODE="${VMIS_PER_NODE:-25}"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-vmi-density}"
UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
INDEXER="${INDEXER:-local}"
LOG_LEVEL="${LOG_LEVEL:-info}"
IMAGE="${IMAGE:-quay.io/containerdisks/fedora:latest}"

echo "============================================================"
echo " Test 20: kube-burner-ocp vmi-density"
echo "============================================================"
echo " VMIs per node : ${VMIS_PER_NODE}"
echo " Image         : ${IMAGE}"
echo " UUID          : ${UUID}"
echo " Indexer       : ${INDEXER}"
echo "============================================================"
echo ""
echo " WATCH WHILE RUNNING:"
echo "  oc get vmi -A --watch"
echo "  oc adm top nodes"
echo "  oc get -n kubevirt kubevirt kubevirt -o jsonpath='{.status.conditions}'"
echo ""

kube-burner-ocp vmi-density \
  --vmis-per-node="${VMIS_PER_NODE}" \
  --uuid="${UUID}" \
  --log-level="${LOG_LEVEL}" \
  --indexer-type="${INDEXER}"

echo ""
echo "Run complete. UUID: ${UUID}"
echo "Check results in: ./collected-metrics/${UUID}/"
echo ""
echo "Summary query (requires Prometheus access):"
echo "  sum(kube_pod_status_phase{phase=\"Running\",namespace=~\"${NAMESPACE_PREFIX}.*\"}) by (namespace)"
