#!/usr/bin/env python3
"""
patch_fw.py - Patch vphone600ap firmware binaries for virtual iPhone boot.

Patches applied:
  1. iBSS  - image4_validate_property_callback → return 0 (bypass signature verification)
  2. iBEC  - image4_validate_property_callback → return 0 + boot-args override
  3. LLB   - image4_validate_property_callback → return 0 + boot-args + SSV/rootfs bypass
  4. TXM   - trustcache bypass (allow unsigned binaries)
  5. kernel - SSV (Signed System Volume) bypass (prevent boot panics)

Based on cloudOS 23B85 (PCC) + iOS 26.1 23B85 (iPhone17,3) mixed firmware.
Offsets verified against image4_validate_property_callback found at:
  iBSS VA 0x70075D10 (file 0x9D10), LLB VA 0x700760D8 (file 0xA0D8)

Usage:
  python3 patch_fw.py [--firmware-dir PATH] [--dry-run] [--verify-only]
"""

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# =============================================================================
# Tool paths
# =============================================================================
PYIMG4 = os.environ.get("PYIMG4", shutil.which("pyimg4") or
         os.path.expanduser("~/Library/Python/3.9/bin/pyimg4"))
IMG4TOOL = os.environ.get("IMG4TOOL", shutil.which("img4tool") or "/usr/local/bin/img4tool")

# =============================================================================
# ARM64 instruction encodings
# =============================================================================
NOP        = 0xD503201F  # NOP
MOV_X0_0   = 0xD2800000  # MOV X0, #0

# =============================================================================
# Patch definitions
# =============================================================================
# Each patch is: (offset, value, description)
# value is either an int (4-byte ARM64 instruction) or bytes/str (string patch)

IBSS_PATCHES = [
    # image4_validate_property_callback epilogue: B.NE → NOP, MOV X0, X22 → MOV X0, #0
    (0x9D10, NOP,      "image4_validate_property_callback: NOP B.NE (was 0x540009E1)"),
    (0x9D14, MOV_X0_0, "image4_validate_property_callback: MOV X0, #0 (was MOV X0, X22)"),
]

IBEC_PATCHES = [
    # image4_validate_property_callback
    (0x9D10, NOP,      "image4_validate_property_callback: NOP B.NE (was 0x540009E1)"),
    (0x9D14, MOV_X0_0, "image4_validate_property_callback: MOV X0, #0 (was MOV X0, X22)"),
    # boot-args: redirect ADRP+ADD to point to custom string at 0x24070
    (0x122D4, 0xD0000082, "boot-args: ADRP X2, #0x12000 → page of 0x24070"),
    (0x122D8, 0x9101C042, "boot-args: ADD X2, X2, #0x70 → offset to 0x24070"),
    (0x24070, b"serial=3 -v debug=0x2014e %s\x00", "boot-args: custom string"),
]

LLB_PATCHES = [
    # image4_validate_property_callback
    (0xA0D8, NOP,      "image4_validate_property_callback: NOP B.NE (was 0x54000A61)"),
    (0xA0DC, MOV_X0_0, "image4_validate_property_callback: MOV X0, #0 (was MOV X0, X22)"),
    # boot-args: redirect ADRP+ADD to custom string at 0x24990
    (0x12888, 0xD0000082, "boot-args: ADRP X2, #0x12000 → page of 0x24990"),
    (0x1288C, 0x91264042, "boot-args: ADD X2, X2, #0x990 → offset to 0x24990"),
    (0x24990, b"serial=3 -v debug=0x2014e %s\x00", "boot-args: custom string"),
    # SSV / rootfs bypass - allow loading edited rootfs (needed for snaputil -n)
    (0x2BFE8, 0x1400000B, "SSV: unconditional branch (was CBZ W0)"),
    (0x2BCA0, NOP,        "SSV: NOP conditional branch (was B.CC)"),
    (0x2C03C, 0x17FFFF6A, "SSV: unconditional branch (was CBZ W0)"),
    (0x2FCEC, NOP,        "SSV: NOP conditional branch (was CBZ X8)"),
    (0x2FEE8, 0x14000009, "SSV: unconditional branch (was CBZ W0)"),
    # bypass panic in unknown check
    (0x1AEE4, NOP,        "NOP panic branch (was CBNZ W0)"),
]

TXM_PATCHES = [
    # Trustcache bypass: replace BL to validation functions with MOV X0, #0
    # Allows running binaries not registered in trustcache
    # Trace: sub_FFFFFFF01702B018 → sub_FFFFFFF0170306E4 → ... → sub_FFFFFFF01702EC70
    (0x2C1F8, MOV_X0_0, "trustcache: MOV X0, #0 (was BL sub_FFFFFFF01702EC70)"),
    (0x2BEF4, MOV_X0_0, "trustcache: MOV X0, #0 (was BL validation func)"),
    (0x2C060, MOV_X0_0, "trustcache: MOV X0, #0 (was BL validation func)"),
]

KERNEL_PATCHES = [
    # SSV (Signed System Volume) bypass - NOP branches that lead to panics
    (0x2476964, NOP, "_apfs_vfsop_mount: NOP (prevent 'Failed to find root snapshot' panic)"),
    (0x23CFDE4, NOP, "_authapfs_seal_is_broken: NOP (prevent 'root volume seal broken' panic)"),
    (0x0F6D960, NOP, "_bsd_init: NOP (prevent 'rootvp not authenticated' panic)"),
]

# =============================================================================
# Firmware file paths (relative to firmware restore directory)
# =============================================================================
FIRMWARE_FILES = {
    "iBSS": {
        "im4p": "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
        "fourcc": "ibss",
        "patches": IBSS_PATCHES,
        "tool": "img4tool",  # bootloaders use img4tool for repack
    },
    "iBEC": {
        "im4p": "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
        "fourcc": "ibec",
        "patches": IBEC_PATCHES,
        "tool": "img4tool",
    },
    "LLB": {
        "im4p": "Firmware/all_flash/LLB.vresearch101.RESEARCH_RELEASE.im4p",
        "fourcc": "illb",
        "patches": LLB_PATCHES,
        "tool": "img4tool",
    },
    "TXM": {
        "im4p": "Firmware/txm.iphoneos.research.im4p",
        "fourcc": "trxm",
        "patches": TXM_PATCHES,
        "tool": "pyimg4",  # TXM uses pyimg4 + PAYP preservation
        "lzfse": True,
        "preserve_payp": True,
    },
    "kernel": {
        "im4p": "kernelcache.research.vphone600",
        "fourcc": "krnl",
        "patches": KERNEL_PATCHES,
        "tool": "pyimg4",  # kernel uses pyimg4 + PAYP preservation
        "lzfse": True,
        "preserve_payp": True,
    },
}

# =============================================================================
# Expected original values at patch offsets (for verification)
# =============================================================================
EXPECTED_ORIGINALS = {
    "iBSS": {
        0x9D10: 0x540009E1,  # B.NE
        0x9D14: 0xAA1603E0,  # MOV X0, X22
    },
    "iBEC": {
        0x9D10: 0x540009E1,
        0x9D14: 0xAA1603E0,
        0x122D4: 0xF0000382,  # ADRP X2, ...
        0x122D8: 0x9121A842,  # ADD X2, X2, #0x86A
    },
    "LLB": {
        0xA0D8: 0x54000A61,  # B.NE
        0xA0DC: 0xAA1603E0,  # MOV X0, X22
        0x12888: 0xB00003A2,  # ADRP X2
        0x1288C: 0x913ED442,  # ADD X2, X2, ...
        0x2BFE8: 0x34000160,  # CBZ W0
        0x2BCA0: 0x54000AE2,  # B.CC
        0x2C03C: 0x34FFED40,  # CBZ W0
        0x2FCEC: 0xB4000348,  # CBZ X8
        0x2FEE8: 0x34000120,  # CBZ W0
        0x1AEE4: 0x350004C0,  # CBNZ W0
    },
    "TXM": {
        0x2C1F8: 0x97FFFA9E,  # BL
        0x2BEF4: 0x97FFFB5F,  # BL
        0x2C060: 0x97FFFB04,  # BL
    },
    "kernel": {
        0x2476964: 0x37281048,  # TBNZ
        0x23CFDE4: 0x37700160,  # TBNZ
        0x0F6D960: 0x35001340,  # CBNZ
    },
}


def read_u32(data, offset):
    """Read a little-endian 32-bit value."""
    return struct.unpack('<I', data[offset:offset+4])[0]


def write_u32(data, offset, value):
    """Write a little-endian 32-bit value."""
    struct.pack_into('<I', data, offset, value)


def sha256(data):
    """Compute SHA-256 hex digest."""
    return hashlib.sha256(data).hexdigest()


def run_cmd(cmd, check=True):
    """Run a shell command and return output."""
    print(f"  $ {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"  ERROR: {result.stderr.strip()}")
        sys.exit(1)
    return result


def verify_offsets(data, name):
    """Verify that original values at patch offsets match expectations."""
    expected = EXPECTED_ORIGINALS.get(name, {})
    ok = True
    for offset, expected_val in expected.items():
        actual = read_u32(data, offset)
        if actual == expected_val:
            print(f"    0x{offset:X}: 0x{actual:08X} (expected) OK")
        elif actual in (NOP, MOV_X0_0):
            print(f"    0x{offset:X}: 0x{actual:08X} (already patched)")
        else:
            print(f"    0x{offset:X}: 0x{actual:08X} != expected 0x{expected_val:08X} MISMATCH")
            ok = False
    return ok


def apply_patches(data, patches, name):
    """Apply patches to raw binary data. Returns patched bytearray."""
    data = bytearray(data)
    count = 0
    for offset, value, desc in patches:
        if isinstance(value, int):
            # 4-byte instruction patch
            old = read_u32(data, offset)
            write_u32(data, offset, value)
            new = read_u32(data, offset)
            print(f"    0x{offset:X}: 0x{old:08X} → 0x{new:08X}  ({desc})")
        elif isinstance(value, (bytes, str)):
            # String/data patch
            if isinstance(value, str):
                value = value.encode('utf-8') + b'\x00'
            old_bytes = bytes(data[offset:offset+len(value)])
            data[offset:offset+len(value)] = value
            print(f"    0x{offset:X}: {len(value)} bytes  ({desc})")
        count += 1
    print(f"  Applied {count} patches to {name}")
    return bytes(data)


def extract_raw(im4p_path, raw_path):
    """Extract raw binary from IM4P container."""
    run_cmd(f'{PYIMG4} im4p extract -i "{im4p_path}" -o "{raw_path}"')


def repack_img4tool(raw_path, im4p_path, fourcc):
    """Repack raw binary to IM4P using img4tool (for bootloaders)."""
    run_cmd(f'{IMG4TOOL} -c "{im4p_path}" -t {fourcc} "{raw_path}"')


def repack_pyimg4(raw_path, im4p_path, fourcc, lzfse=False):
    """Repack raw binary to IM4P using pyimg4 (for kernel/TXM)."""
    compress = " --lzfse" if lzfse else ""
    run_cmd(f'{PYIMG4} im4p create -i "{raw_path}" -o "{im4p_path}" -f {fourcc}{compress}')


def preserve_payp(original_im4p_path, new_im4p_path):
    """
    Preserve PAYP structure from original IM4P.
    The PAYP (payload properties) section must be appended to the new IM4P
    and the DER length field updated accordingly.
    """
    original_data = Path(original_im4p_path).read_bytes()
    payp_offset = original_data.rfind(b'PAYP')
    if payp_offset == -1:
        print("  WARNING: Could not find PAYP structure in original IM4P!")
        return False

    # PAYP data starts 10 bytes before the 'PAYP' tag (DER header)
    payp_data = original_data[payp_offset - 10:]
    payp_sz = len(payp_data)
    print(f"  PAYP structure: {payp_sz} bytes (offset {payp_offset - 10} in original)")

    # Append PAYP to new IM4P
    with open(new_im4p_path, 'ab') as f:
        f.write(payp_data)

    # Update DER sequence length (bytes 2-5 of the IM4P file)
    im4p_data = bytearray(Path(new_im4p_path).read_bytes())
    old_len = int.from_bytes(im4p_data[2:5], 'big')
    new_len = old_len + payp_sz
    im4p_data[2:5] = new_len.to_bytes(3, 'big')
    Path(new_im4p_path).write_bytes(bytes(im4p_data))

    print(f"  Updated DER length: {old_len} → {new_len} (+{payp_sz})")
    return True


def process_component(name, config, fw_dir, tmp_dir, dry_run=False, verify_only=False):
    """Process a single firmware component: extract, verify, patch, repack."""
    print(f"\n{'='*60}")
    print(f"[{name}]")
    print(f"{'='*60}")

    im4p_rel = config["im4p"]
    im4p_path = os.path.join(fw_dir, im4p_rel)
    bak_path = im4p_path + ".bak"
    raw_path = os.path.join(tmp_dir, f"{name}.raw")
    fourcc = config["fourcc"]
    patches = config["patches"]

    # Check IM4P exists
    if not os.path.exists(im4p_path):
        print(f"  ERROR: {im4p_path} not found!")
        return False

    # Create backup
    if not os.path.exists(bak_path):
        print(f"  Creating backup: {os.path.basename(bak_path)}")
        if not dry_run:
            shutil.copy2(im4p_path, bak_path)
    else:
        print(f"  Backup already exists: {os.path.basename(bak_path)}")

    # Extract raw from backup (always from original)
    print(f"  Extracting raw binary from backup...")
    if not dry_run:
        extract_raw(bak_path, raw_path)

    # Read raw data
    if dry_run:
        if os.path.exists(raw_path):
            raw_data = Path(raw_path).read_bytes()
        else:
            print(f"  DRY RUN: would extract and patch {name}")
            return True
    else:
        raw_data = Path(raw_path).read_bytes()

    print(f"  Raw binary: {len(raw_data)} bytes, SHA256: {sha256(raw_data)[:16]}...")

    # Verify original values
    print(f"  Verifying original instruction values:")
    if not verify_offsets(raw_data, name):
        print(f"  WARNING: Some offsets don't match expected values!")
        print(f"  This firmware may be a different build. Proceed with caution.")

    if verify_only:
        return True

    # Apply patches
    print(f"  Applying patches:")
    patched_data = apply_patches(raw_data, patches, name)
    print(f"  Patched SHA256: {sha256(patched_data)[:16]}...")

    if dry_run:
        print(f"  DRY RUN: would write patched binary and repack")
        return True

    # Write patched raw
    Path(raw_path).write_bytes(patched_data)

    # Repack to IM4P
    print(f"  Repacking to IM4P (fourcc={fourcc})...")
    tool = config.get("tool", "img4tool")

    if tool == "img4tool":
        repack_img4tool(raw_path, im4p_path, fourcc)
    elif tool == "pyimg4":
        lzfse = config.get("lzfse", False)
        repack_pyimg4(raw_path, im4p_path, fourcc, lzfse=lzfse)

    # Preserve PAYP if needed
    if config.get("preserve_payp", False):
        print(f"  Preserving PAYP structure...")
        if not preserve_payp(bak_path, im4p_path):
            print(f"  ERROR: PAYP preservation failed!")
            return False

    # Verify output
    output_size = os.path.getsize(im4p_path)
    backup_size = os.path.getsize(bak_path)
    print(f"  Output: {output_size} bytes (backup: {backup_size} bytes)")
    print(f"  [{name}] DONE")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Patch vphone600ap firmware binaries for virtual iPhone boot.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Components patched:
  iBSS   - Signature verification bypass (image4_validate_property_callback → return 0)
  iBEC   - Signature bypass + boot-args (serial=3 -v debug=0x2014e)
  LLB    - Signature bypass + boot-args + SSV/rootfs bypass
  TXM    - Trustcache bypass (allow unsigned binaries)
  kernel - SSV bypass (prevent boot panics on unsigned root volume)

All offsets are for cloudOS/iOS 23B85 build.
""")
    parser.add_argument("--firmware-dir", "-d",
                        default=None,
                        help="Path to firmware restore directory (default: auto-detect)")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Show what would be done without modifying files")
    parser.add_argument("--verify-only", "-v", action="store_true",
                        help="Only verify offsets match expected values, don't patch")
    parser.add_argument("--component", "-c", nargs="+",
                        choices=list(FIRMWARE_FILES.keys()) + ["all"],
                        default=["all"],
                        help="Components to patch (default: all)")
    args = parser.parse_args()

    # Find firmware directory
    if args.firmware_dir:
        fw_dir = args.firmware_dir
    else:
        # Auto-detect relative to script location
        script_dir = Path(__file__).parent.resolve()
        candidates = [
            script_dir.parent / "firmwares" / "firmware_patched" / "iPhone17,3_26.1_23B85_Restore",
            Path.cwd() / "firmwares" / "firmware_patched" / "iPhone17,3_26.1_23B85_Restore",
            Path.cwd() / "iPhone17,3_26.1_23B85_Restore",
        ]
        fw_dir = None
        for c in candidates:
            if c.exists():
                fw_dir = str(c)
                break
        if not fw_dir:
            print("ERROR: Could not find firmware directory. Use --firmware-dir to specify.")
            sys.exit(1)

    print(f"Firmware directory: {fw_dir}")

    # Check tools
    for tool_name, tool_path in [("pyimg4", PYIMG4), ("img4tool", IMG4TOOL)]:
        if not tool_path or not os.path.exists(tool_path):
            print(f"ERROR: {tool_name} not found at {tool_path}")
            print(f"Set {tool_name.upper()} environment variable or install it.")
            sys.exit(1)
        print(f"  {tool_name}: {tool_path}")

    # Create temp directory for raw binaries
    tmp_dir = os.path.join(os.path.dirname(fw_dir), "patch_tmp")
    os.makedirs(tmp_dir, exist_ok=True)
    print(f"  Temp dir: {tmp_dir}")

    # Determine which components to patch
    components = list(FIRMWARE_FILES.keys()) if "all" in args.component else args.component

    if args.dry_run:
        print("\n*** DRY RUN - no files will be modified ***")
    if args.verify_only:
        print("\n*** VERIFY ONLY - checking offsets ***")

    # Process each component
    results = {}
    for name in components:
        config = FIRMWARE_FILES[name]
        ok = process_component(name, config, fw_dir, tmp_dir,
                               dry_run=args.dry_run,
                               verify_only=args.verify_only)
        results[name] = ok

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    for name, ok in results.items():
        status = "OK" if ok else "FAILED"
        print(f"  {name:8s}: {status}")

    if all(results.values()):
        print("\nAll components processed successfully.")
        if not args.dry_run and not args.verify_only:
            print(f"Patched firmware is in: {fw_dir}")
            print(f"Backups saved with .bak extension.")
    else:
        print("\nSome components failed. Check output above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
