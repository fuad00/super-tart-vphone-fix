#!/bin/bash
# build_and_sign.sh — Build vphone-cli and sign with private entitlements.
#
# Requires: SIP/AMFI disabled (amfi_get_out_of_my_way=1)
#
# Usage:
#   bash build_and_sign.sh           # build + sign
#   bash build_and_sign.sh --install # also copy to ../bin/vphone-cli
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/.build/release/vphone-cli"
ENTITLEMENTS="${SCRIPT_DIR}/vphone.entitlements"

echo "=== Building vphone-cli ==="
cd "${SCRIPT_DIR}"
swift build -c release 2>&1 | tail -5

echo ""
echo "=== Signing with entitlements ==="
echo "  entitlements: ${ENTITLEMENTS}"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BINARY}"
echo "  signed OK"

# Verify entitlements
echo ""
echo "=== Entitlement verification ==="
codesign -d --entitlements - "${BINARY}" 2>/dev/null | head -20

echo ""
echo "=== Binary ==="
ls -lh "${BINARY}"

if [ "${1:-}" = "--install" ]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  mkdir -p "${REPO_ROOT}/bin"
  cp -f "${BINARY}" "${REPO_ROOT}/bin/vphone-cli"
  echo ""
  echo "Installed to ${REPO_ROOT}/bin/vphone-cli"
fi

echo ""
echo "Done. Run with:"
echo "  ${BINARY} --rom <rom> --disk <disk> --serial"
