#!/bin/bash
# vm_boot_dfu.sh — Start the vphone VM in DFU mode via super-tart.
#
# Usage:
#   ./vm_boot_dfu.sh [vm_name] [tart args...]
#
# Examples:
#   ./vm_boot_dfu.sh vphone --serial
#   ./vm_boot_dfu.sh vphone --stop-on-panic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
TART_HOME="${TART_HOME:-${REPO_ROOT}/.tart}"
TART_BIN="${TART_BIN:-${REPO_ROOT}/bin/tart}"
VPHONE_MODE="${VPHONE_MODE:-1}"

VM_NAME="${1:-vphone}"
if [ "$#" -gt 0 ]; then
  shift
fi

if [ ! -x "${TART_BIN}" ]; then
  echo "ERROR: tart not found at ${TART_BIN}"
  echo "Run: bash setup_bin.sh"
  exit 1
fi

mkdir -p "${TART_HOME}"

echo "=== Starting VM in DFU mode ==="
echo "VM name : ${VM_NAME}"
echo "TART    : ${TART_BIN}"
echo "TART_HOME: ${TART_HOME}"
echo "VPHONE_MODE: ${VPHONE_MODE}"

echo ""
echo "Command: VPHONE_MODE=${VPHONE_MODE} TART_HOME=\"${TART_HOME}\" ${TART_BIN} run ${VM_NAME} --dfu $*"

echo ""
exec env TART_HOME="${TART_HOME}" VPHONE_MODE="${VPHONE_MODE}" "${TART_BIN}" run "${VM_NAME}" --dfu "$@"
