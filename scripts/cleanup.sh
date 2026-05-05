#!/usr/bin/env bash
# cleanup.sh
# Tears down all resources created by a kube-burner benchmark run.
#
# Usage:
#   ./scripts/cleanup.sh [config-file]
#
# Example:
#   ./scripts/cleanup.sh examples/workloads/pod-density.yml

set -euo pipefail

CONFIG="${1:-}"

if [[ -z "${CONFIG}" ]]; then
    echo "Usage: $0 <config-file>"
    echo "Example: $0 examples/workloads/pod-density.yml"
    exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG}"
    exit 1
fi

if ! command -v kube-burner &>/dev/null; then
    echo "ERROR: kube-burner not found in PATH"
    exit 1
fi

echo "Destroying resources defined in: ${CONFIG}"
echo "This will delete all namespaces and objects created by kube-burner."
echo ""
read -r -p "Continue? [y/N] " CONFIRM

if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

kube-burner destroy -c "${CONFIG}"

echo ""
echo "Cleanup complete."
