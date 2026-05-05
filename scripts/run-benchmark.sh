#!/usr/bin/env bash
# run-benchmark.sh
# Helper script to run a kube-burner benchmark with sensible defaults.
#
# Usage:
#   ./scripts/run-benchmark.sh [config-file] [uuid]
#
# Examples:
#   ./scripts/run-benchmark.sh examples/workloads/pod-density.yml
#   ./scripts/run-benchmark.sh examples/workloads/node-density.yml my-test-001

set -euo pipefail

CONFIG="${1:-examples/workloads/pod-density.yml}"
UUID="${2:-$(date +%Y%m%d-%H%M%S)}"
LOG_LEVEL="${LOG_LEVEL:-info}"
TIMEOUT="${TIMEOUT:-4h}"
RESULTS_DIR="./results/${UUID}"

echo "========================================"
echo "  Kube-Burner Benchmark Runner"
echo "========================================"
echo "  Config:     ${CONFIG}"
echo "  UUID:       ${UUID}"
echo "  Log level:  ${LOG_LEVEL}"
echo "  Timeout:    ${TIMEOUT}"
echo "  Results:    ${RESULTS_DIR}"
echo "========================================"
echo ""

# Verify kube-burner is installed
if ! command -v kube-burner &>/dev/null; then
    echo "ERROR: kube-burner not found in PATH"
    echo "Install with:"
    echo "  curl -Ls https://raw.githubusercontent.com/kube-burner/kube-burner/refs/heads/main/hack/install.sh | sh"
    exit 1
fi

# Verify kubeconfig is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster."
    echo "Check your kubeconfig: kubectl cluster-info"
    exit 1
fi

# Run cluster health check before benchmark
echo "Running pre-flight cluster health check..."
kube-burner health-check || {
    echo "WARNING: Cluster health check failed. Proceeding anyway."
}

mkdir -p "${RESULTS_DIR}"

echo ""
echo "Starting benchmark..."
echo ""

kube-burner init \
    -c "${CONFIG}" \
    --uuid "${UUID}" \
    --log-level "${LOG_LEVEL}" \
    --timeout "${TIMEOUT}"

EXIT_CODE=$?

echo ""
case ${EXIT_CODE} in
    0) echo "Benchmark completed successfully." ;;
    1) echo "ERROR: Benchmark failed with an unrecoverable error." ;;
    2) echo "ERROR: Benchmark timed out (timeout: ${TIMEOUT})." ;;
    3) echo "WARNING: An alert was fired during the benchmark." ;;
    4) echo "WARNING: A measurement threshold was exceeded." ;;
    *) echo "Benchmark exited with code: ${EXIT_CODE}" ;;
esac

exit ${EXIT_CODE}
