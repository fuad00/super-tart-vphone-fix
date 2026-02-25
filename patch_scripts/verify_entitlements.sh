#!/bin/bash
#
# verify_entitlements.sh — Iterate over all 6 known Virtualization entitlements,
# sign the dummy loader with each one, launch it, attach lldb to read the
# entitlement bitmap, and report results.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/verify_entitlements.c"
LLDB_SCRIPT="$SCRIPT_DIR/lldb_call_ent.py"
BIN="/tmp/verify_ent"

cleanup() { pkill -f verify_ent 2>/dev/null || true; }
trap cleanup EXIT

echo "=== Building verify_entitlements ==="
clang -O2 -o "$BIN" "$SRC" -arch arm64e -lobjc \
    -framework CoreFoundation -framework Virtualization
echo "Built: $BIN"
echo ""

# All 6 entitlements
ENTITLEMENTS=(
    "com.apple.security.virtualization"
    "com.apple.private.virtualization"
    "com.apple.vm.networking"
    "com.apple.private.ggdsw.GPUProcessProtectedContent"
    "com.apple.private.virtualization.security-research"
    "com.apple.private.virtualization.private-vsock"
)

# Launch process with given entitlements plist, attach lldb, return bitmap
read_bitmap() {
    local ent_plist="$1"

    pkill -f verify_ent 2>/dev/null || true
    sleep 0.3

    if [ "$ent_plist" = "NONE" ]; then
        codesign --force --sign - "$BIN" 2>/dev/null
    else
        codesign --force --sign - --entitlements "$ent_plist" "$BIN" 2>/dev/null
    fi

    "$BIN" > /dev/null 2>&1 &
    sleep 0.8

    local pid
    pid=$(pgrep -f verify_ent | head -1 || true)
    if [ -z "$pid" ]; then
        echo "CRASH"
        return
    fi

    local result
    result=$(lldb -p "$pid" --batch \
        -o "command script import $LLDB_SCRIPT" 2>&1 \
        | grep "^bitmap=" | head -1 | cut -d= -f2 || true)

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo "${result:-FAILED}"
}

echo "=== Test 1: No entitlements (baseline) ==="
BASELINE=$(read_bitmap "NONE")
echo "  bitmap = $BASELINE"
echo ""

echo "=== Test 2: Each entitlement individually ==="
printf "  %-60s %s\n" "Entitlement" "Bitmap"
printf "  %-60s %s\n" "$(printf '%.0s-' {1..60})" "------"

for i in "${!ENTITLEMENTS[@]}"; do
    ent="${ENTITLEMENTS[$i]}"

    # Create plist with just this one entitlement
    plist="/tmp/ent_single_${i}.plist"
    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${ent}</key>
  <true/>
</dict>
</plist>
EOF

    result=$(read_bitmap "$plist")
    printf "  %-60s %s\n" "$ent" "$result"
done

echo ""
echo "=== Test 3: Cumulative (add entitlements one by one) ==="
printf "  %-4s %-60s %s\n" "#" "Added Entitlement" "Bitmap"
printf "  %-4s %-60s %s\n" "----" "$(printf '%.0s-' {1..60})" "------"

for n in $(seq 1 ${#ENTITLEMENTS[@]}); do
    # Create plist with first n entitlements
    plist="/tmp/ent_cumulative_${n}.plist"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        for i in $(seq 0 $((n - 1))); do
            echo "  <key>${ENTITLEMENTS[$i]}</key>"
            echo '  <true/>'
        done
        echo '</dict>'
        echo '</plist>'
    } > "$plist"

    result=$(read_bitmap "$plist")
    printf "  %-4s %-60s %s\n" "$n" "${ENTITLEMENTS[$((n-1))]}" "$result"
done

echo ""
echo "=== Test 4: All entitlements ==="
plist="/tmp/ent_all.plist"
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    for ent in "${ENTITLEMENTS[@]}"; do
        echo "  <key>${ent}</key>"
        echo '  <true/>'
    done
    echo '</dict>'
    echo '</plist>'
} > "$plist"
result=$(read_bitmap "$plist")
echo "  bitmap = $result (expected 0x3f)"

echo ""
echo "=== Done ==="
