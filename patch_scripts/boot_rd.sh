#!/bin/zsh
# boot_rd.sh - Load IMG4 firmware components into DFU VM via irecovery.
#
# Prerequisites:
#   - prepare_ramdisk.py must have been run (IMG4 files in Ramdisk/)
#   - VM must be in DFU mode (started with tart)
#   - irecovery must be available
#
# Usage:
#   ./boot_rd.sh [ramdisk_dir]
#
# The boot sequence loads components in order:
#   iBSS → iBEC → go → SPTM → TXM → trustcache → ramdisk →
#   devicetree → SEP → kernel → bootx
#
# After boot, use iproxy to connect:
#   iproxy 2222 22 &
#   ssh root@127.0.0.1 -p2222  (password: alpine)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$REPO_ROOT/bin"

# Ramdisk directory (first arg or default)
RD_DIR="${1:-$REPO_ROOT/Ramdisk}"

# irecovery path
IRECOVERY="${IRECOVERY:-$BIN_DIR/irecovery}"

if [ ! -x "$IRECOVERY" ]; then
    echo "ERROR: irecovery not found at $IRECOVERY"
    exit 1
fi

if [ ! -d "$RD_DIR" ]; then
    echo "ERROR: Ramdisk directory not found: $RD_DIR"
    echo "Run prepare_ramdisk.py first."
    exit 1
fi

# Verify all required files exist
REQUIRED_FILES=(
    "iBSS.vresearch101.RELEASE.img4"
    "iBEC.vresearch101.RELEASE.img4"
    "sptm.vresearch1.release.img4"
    "txm.img4"
    "trustcache.img4"
    "ramdisk.img4"
    "DeviceTree.vphone600ap.img4"
    "sep-firmware.vresearch101.RELEASE.img4"
    "krnl.img4"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$RD_DIR/$f" ]; then
        echo "ERROR: Missing $RD_DIR/$f"
        exit 1
    fi
done

echo "=== Loading firmware components into DFU VM ==="
echo "Ramdisk dir: $RD_DIR"
echo ""

# 1. iBSS (first-stage bootloader)
echo "[1/10] Loading iBSS..."
"$IRECOVERY" -f "$RD_DIR/iBSS.vresearch101.RELEASE.img4"

# 2. iBEC (second-stage bootloader)
echo "[2/10] Loading iBEC..."
"$IRECOVERY" -f "$RD_DIR/iBEC.vresearch101.RELEASE.img4"

# 3. Execute bootloader
echo "[3/10] Executing bootloader (go)..."
"$IRECOVERY" -c go

sleep 1

# 4. SPTM (Secure Page Table Monitor)
echo "[4/10] Loading SPTM..."
"$IRECOVERY" -f "$RD_DIR/sptm.vresearch1.release.img4"
"$IRECOVERY" -c firmware

# 5. TXM (Trustcache Manager)
echo "[5/10] Loading TXM..."
"$IRECOVERY" -f "$RD_DIR/txm.img4"
"$IRECOVERY" -c firmware

# 6. Trustcache
echo "[6/10] Loading trustcache..."
"$IRECOVERY" -f "$RD_DIR/trustcache.img4"
"$IRECOVERY" -c firmware

# 7. Ramdisk
echo "[7/10] Loading ramdisk..."
"$IRECOVERY" -f "$RD_DIR/ramdisk.img4"
"$IRECOVERY" -c ramdisk

# 8. Device Tree
echo "[8/10] Loading device tree..."
"$IRECOVERY" -f "$RD_DIR/DeviceTree.vphone600ap.img4"
"$IRECOVERY" -c devicetree

# 9. SEP firmware
echo "[9/10] Loading SEP firmware..."
"$IRECOVERY" -f "$RD_DIR/sep-firmware.vresearch101.RELEASE.img4"
"$IRECOVERY" -c firmware

# 10. Kernel (triggers boot)
echo "[10/10] Loading kernel and booting..."
"$IRECOVERY" -f "$RD_DIR/krnl.img4"
"$IRECOVERY" -c bootx

echo ""
echo "=== Boot sequence complete ==="
echo ""
echo "If you see the Creeper face in the VM window and 'iPhone Research...'"
echo "appears in System Information > USB, the ramdisk booted successfully."
echo ""
echo "To connect via SSH:"
echo "  iproxy 2222 22 &"
echo "  ssh root@127.0.0.1 -p2222"
echo "  (password: alpine)"
