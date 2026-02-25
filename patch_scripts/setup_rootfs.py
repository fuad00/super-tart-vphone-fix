#!/usr/bin/env python3
"""
setup_rootfs.py - Modify virtual iPhone rootfs via SSH ramdisk.

After booting the SSH ramdisk (boot_rd.sh), this script connects over SSH
and sets up the rootfs for normal boot: installs Cryptex, patches system
binaries, installs launch daemons, and optionally adds GPU Metal support.

Prerequisites:
  - VM booted with SSH ramdisk (boot_rd.sh)
  - iproxy running: iproxy 2222 22 &
  - Tools: sshpass, ipsw, aea, ldid, plutil (on host)
  - Files:
    - signcert.p12            (code signing identity)
    - jb/iosbinpack64.tar     (jailbreak binary pack)
    - jb/LaunchDaemons/       (bash.plist, dropbear.plist, trollvnc.plist)
  - IPSW firmware directory with Cryptex DMGs

Steps:
  1. Mount rootfs read-write, rename snapshot
  2. Decrypt and install Cryptex (SystemOS + AppOS)
  3. Create dyld cache symlinks
  4. Patch seputil (hardcode AA.gl gigalocker filename)
  5. Rename gigalocker to AA.gl
  6. Patch launchd_cache_loader (NOP secure cache check)
  7. Install iosbinpack64
  8. Install launch daemons + modify launchd.plist
  9. Install AppleParavirtGPUMetalIOGPUFamily.bundle from PCC (optional)
  10. Halt device

Usage:
  python3 setup_rootfs.py [--firmware-dir PATH] [--pcc-gpu-bundle PATH]
"""

import argparse
import glob
import os
import plistlib
import struct
import subprocess
import shutil
import sys
import tempfile
from pathlib import Path

# =============================================================================
# Paths
# =============================================================================
SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent
BIN_DIR = REPO_ROOT / "bin"

# Default firmware directories
DEFAULT_FW_DIR = (REPO_ROOT / "firmwares" / "firmware_patched"
                  / "iPhone17,3_26.1_23B85_Restore")
DEFAULT_PCC_DIR = (REPO_ROOT / "firmwares" / "firmware_patched" / "pcc_extracted")

# Tool paths (prefer bin/ then system)
def _find_tool(name, env_var, fallback=None):
    """Find a tool: env var > bin/ > PATH > fallback."""
    if env_var and os.environ.get(env_var):
        return os.environ[env_var]
    bin_path = str(BIN_DIR / name)
    if os.path.exists(bin_path):
        return bin_path
    found = shutil.which(name)
    if found:
        return found
    return fallback or name

SSHPASS = _find_tool("sshpass", "SSHPASS")
IPSW = _find_tool("ipsw", "IPSW")
LDID = _find_tool("ldid", "LDID")
PLUTIL = _find_tool("plutil", "PLUTIL", "/usr/bin/plutil")

# SSH connection settings
SSH_HOST = "root@127.0.0.1"
SSH_PORT = "2222"
SSH_PASS = "alpine"


def set_ssh_port(port):
    """Update the SSH port used for all connections."""
    global SSH_PORT
    SSH_PORT = port


# Signing certificate (optional; adhoc signing is used if not found,
# which is sufficient since TXM trustcache bypass is in effect)
SIGNCERT = os.environ.get("SIGNCERT", str(REPO_ROOT / "signcert.p12"))

# Cryptex file names within the IPSW restore directory
CRYPTEX_SYSTEM_AEA = "043-54303-126.dmg.aea"
CRYPTEX_APP_DMG = "043-54062-129.dmg"

# Patch offsets
SEPUTIL_PATCH_OFFSET = 0x1B3F1    # "AA" string for gigalocker filename
LAUNCHD_CACHE_PATCH_OFFSET = 0xB58  # NOP the secure cache check

# TrollVNC plist from OEM
TROLLVNC_PLIST = REPO_ROOT / "oems" / "TrollVNC" / "layout" / "Library" / "LaunchDaemons" / "com.82flex.trollvnc.plist"


# =============================================================================
# SSH helpers
# =============================================================================
def ssh_opts():
    return "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"


def remote_cmd(cmd, check=True):
    """Execute a command on the device via SSH."""
    full_cmd = (f'{SSHPASS} -p "{SSH_PASS}" ssh {ssh_opts()} '
                f'-p {SSH_PORT} {SSH_HOST} "{cmd}"')
    print(f"    [ssh] {cmd}")
    result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"           {result.stdout.strip()}")
    if check and result.returncode != 0:
        if result.stderr.strip():
            print(f"           STDERR: {result.stderr.strip()}")
        print(f"    ERROR: Remote command failed (exit {result.returncode})")
        return None
    return result.stdout.strip()


def scp_to_device(local_path, remote_path):
    """Copy a file to the device via SCP."""
    cmd = (f'{SSHPASS} -p "{SSH_PASS}" scp -q {ssh_opts()} '
           f'-P {SSH_PORT} "{local_path}" "{SSH_HOST}:{remote_path}"')
    print(f"    [scp] {os.path.basename(local_path)} → {remote_path}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"    ERROR: SCP failed: {result.stderr.strip()}")
        return False
    return True


def scp_to_device_recursive(local_path, remote_path):
    """Copy a directory recursively to the device."""
    cmd = (f'{SSHPASS} -p "{SSH_PASS}" scp -q -r {ssh_opts()} '
           f'-P {SSH_PORT} "{local_path}" "{SSH_HOST}:{remote_path}"')
    print(f"    [scp] {os.path.basename(local_path)}/. → {remote_path}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"    ERROR: SCP failed: {result.stderr.strip()}")
        return False
    return True


def scp_from_device(remote_path, local_path):
    """Copy a file from the device via SCP."""
    cmd = (f'{SSHPASS} -p "{SSH_PASS}" scp -q {ssh_opts()} '
           f'-P {SSH_PORT} "{SSH_HOST}:{remote_path}" "{local_path}"')
    print(f"    [scp] {remote_path} → {os.path.basename(local_path)}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"    ERROR: SCP failed: {result.stderr.strip()}")
        return False
    return True


def check_remote_file_exists(path):
    """Check if a file exists on the remote device."""
    result = remote_cmd(f'/bin/test -e "{path}"', check=False)
    return result is not None


def run_local(cmd, check=True):
    """Run a local shell command."""
    print(f"  $ {cmd}")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"  ERROR: {result.stderr.strip()}")
        sys.exit(1)
    return result


# =============================================================================
# Patch helpers
# =============================================================================
def patch_binary_bytes(filepath, offset, data):
    """Patch bytes at a specific offset in a binary file."""
    with open(filepath, "r+b") as f:
        f.seek(offset)
        old = f.read(len(data))
        f.seek(offset)
        f.write(data)
    return old


def patch_binary_u32(filepath, offset, value):
    """Patch a 32-bit value at a specific offset."""
    return patch_binary_bytes(filepath, offset, struct.pack('<I', value))


# =============================================================================
# LaunchDaemon plist generators
# =============================================================================
def make_bash_plist():
    """Generate bash LaunchDaemon plist."""
    return {
        "Label": "com.vphone.bash",
        "ProgramArguments": ["/iosbinpack64/bin/bash"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardErrorPath": "/tmp/bash-stderr.log",
        "StandardOutPath": "/tmp/bash-stdout.log",
    }


def make_dropbear_plist():
    """Generate dropbear SSH LaunchDaemon plist."""
    return {
        "Label": "com.vphone.dropbear",
        "ProgramArguments": [
            "/iosbinpack64/usr/local/bin/dropbear",
            "--shell", "/iosbinpack64/bin/bash",
            "-R", "-p", "22", "-F",
        ],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardErrorPath": "/tmp/dropbear-stderr.log",
        "StandardOutPath": "/tmp/dropbear-stdout.log",
    }


# =============================================================================
# Step implementations
# =============================================================================
def step_verify_ssh():
    """Verify SSH connection to the device."""
    print("\n" + "=" * 60)
    print("[Step 0] Verifying SSH connection")
    print("=" * 60)

    result = remote_cmd("/bin/echo connected", check=False)
    if result is None or "connected" not in (result or ""):
        print("  ERROR: Cannot connect to device via SSH!")
        print("  Make sure:")
        print("    1. VM is booted with SSH ramdisk (boot_rd.sh)")
        print("    2. iproxy is running: iproxy 2222 22 &")
        print(f"    3. SSH is accessible at {SSH_HOST}:{SSH_PORT}")
        sys.exit(1)
    print("  SSH connection OK")


def step_mount_rootfs():
    """Mount rootfs read-write and rename snapshot."""
    print("\n" + "=" * 60)
    print("[Step 1] Mounting rootfs and renaming snapshot")
    print("=" * 60)

    remote_cmd("/sbin/mount_apfs -o rw /dev/disk1s1 /mnt1")

    # Get snapshot name
    snap_output = remote_cmd("/usr/bin/snaputil -l /mnt1")
    if not snap_output:
        print("  WARNING: Could not list snapshots. Rootfs may already be modified.")
        return

    # Find the com.apple.os.update snapshot
    snap_name = None
    for line in snap_output.splitlines():
        line = line.strip()
        if line.startswith("com.apple.os.update-"):
            snap_name = line
            break

    if snap_name:
        print(f"  Renaming snapshot: {snap_name} → orig-fs")
        remote_cmd(f'/usr/bin/snaputil -n "{snap_name}" orig-fs /mnt1')
    else:
        print("  No com.apple.os.update snapshot found (may already be renamed)")

    remote_cmd("/sbin/umount /mnt1", check=False)


def step_install_cryptex(fw_dir, work_dir):
    """Decrypt and install Cryptex partitions."""
    print("\n" + "=" * 60)
    print("[Step 2] Installing Cryptex (SystemOS + AppOS)")
    print("=" * 60)

    cryptex_sys_aea = os.path.join(fw_dir, CRYPTEX_SYSTEM_AEA)
    cryptex_app_dmg_src = os.path.join(fw_dir, CRYPTEX_APP_DMG)
    cryptex_sys_dmg = os.path.join(work_dir, "CryptexSystemOS.dmg")
    cryptex_app_dmg = os.path.join(work_dir, "CryptexAppOS.dmg")
    mount_sys = os.path.join(work_dir, "CryptexSystemOS")
    mount_app = os.path.join(work_dir, "CryptexAppOS")

    # 2a. Decrypt SystemOS AEA
    if not os.path.exists(cryptex_sys_dmg):
        print("\n  [2a] Decrypting CryptexSystemOS AEA...")
        if not os.path.exists(cryptex_sys_aea):
            print(f"    ERROR: {cryptex_sys_aea} not found!")
            sys.exit(1)

        key_result = run_local(f'{IPSW} fw aea --key "{cryptex_sys_aea}"', check=True)
        key = key_result.stdout.strip()
        print(f"    AEA key: {key[:32]}...")
        run_local(f'aea decrypt -i "{cryptex_sys_aea}" -o "{cryptex_sys_dmg}" -key-value \'{key}\'')
    else:
        print("  CryptexSystemOS.dmg already exists, skipping decrypt")

    # 2b. Copy AppOS DMG
    if not os.path.exists(cryptex_app_dmg):
        print("\n  [2b] Copying CryptexAppOS DMG...")
        shutil.copy2(cryptex_app_dmg_src, cryptex_app_dmg)
    else:
        print("  CryptexAppOS.dmg already exists")

    # 2c. Mount Cryptex DMGs
    print("\n  [2c] Mounting Cryptex DMGs...")
    os.makedirs(mount_sys, exist_ok=True)
    os.makedirs(mount_app, exist_ok=True)
    run_local(f'sudo hdiutil attach -mountpoint "{mount_sys}" "{cryptex_sys_dmg}" -owners off')
    run_local(f'sudo hdiutil attach -mountpoint "{mount_app}" "{cryptex_app_dmg}" -owners off')

    # 2d. Prepare device directories
    print("\n  [2d] Preparing device Cryptex directories...")
    remote_cmd("/sbin/mount_apfs -o rw /dev/disk1s1 /mnt1")

    remote_cmd("/bin/rm -rf /mnt1/System/Cryptexes/App")
    remote_cmd("/bin/rm -rf /mnt1/System/Cryptexes/OS")
    remote_cmd("/bin/mkdir -p /mnt1/System/Cryptexes/App")
    remote_cmd("/bin/chmod 0755 /mnt1/System/Cryptexes/App")
    remote_cmd("/bin/mkdir -p /mnt1/System/Cryptexes/OS")
    remote_cmd("/bin/chmod 0755 /mnt1/System/Cryptexes/OS")

    # 2e. Copy Cryptex files to device
    print("\n  [2e] Copying Cryptex files to device (this will take several minutes)...")
    scp_to_device_recursive(f"{mount_sys}/.", "/mnt1/System/Cryptexes/OS")
    scp_to_device_recursive(f"{mount_app}/.", "/mnt1/System/Cryptexes/App")

    # 2f. Create dyld cache symlinks
    print("\n  [2f] Creating dyld cache symlinks...")
    remote_cmd("/bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld "
               "/mnt1/System/Library/Caches/com.apple.dyld")
    remote_cmd("/bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld "
               "/mnt1/System/DriverKit/System/Library/dyld")

    # Cleanup mounts
    print("\n  Unmounting Cryptex DMGs...")
    run_local(f'sudo hdiutil detach -force "{mount_sys}"', check=False)
    run_local(f'sudo hdiutil detach -force "{mount_app}"', check=False)


def step_patch_seputil(work_dir):
    """Patch seputil to hardcode AA.gl gigalocker filename."""
    print("\n" + "=" * 60)
    print("[Step 3] Patching seputil (gigalocker → AA.gl)")
    print("=" * 60)

    local_seputil = os.path.join(work_dir, "seputil")

    # Backup on device if needed
    if not check_remote_file_exists("/mnt1/usr/libexec/seputil.bak"):
        print("  Creating backup...")
        remote_cmd("/bin/cp /mnt1/usr/libexec/seputil /mnt1/usr/libexec/seputil.bak")

    # Download from device (always from backup)
    scp_from_device("/mnt1/usr/libexec/seputil.bak", local_seputil)

    # Patch: write "AA" at the gigalocker lookup offset
    print(f"  Patching offset 0x{SEPUTIL_PATCH_OFFSET:X} with 'AA'...")
    patch_binary_bytes(local_seputil, SEPUTIL_PATCH_OFFSET, b"AA")

    # Re-sign (adhoc is sufficient with TXM trustcache bypass)
    print("  Re-signing seputil...")
    run_local(f'{LDID} -S -Icom.apple.seputil "{local_seputil}"')

    # Upload patched binary
    scp_to_device(local_seputil, "/mnt1/usr/libexec/seputil")
    remote_cmd("/bin/chmod 0755 /mnt1/usr/libexec/seputil")

    # Rename gigalocker on device
    print("  Renaming gigalocker to AA.gl...")
    remote_cmd("/sbin/mount_apfs -o rw /dev/disk1s3 /mnt3", check=False)
    remote_cmd("/bin/mv /mnt3/*.gl /mnt3/AA.gl", check=False)

    os.remove(local_seputil)


def step_patch_launchd_cache_loader(work_dir):
    """Patch launchd_cache_loader to enable unsecure cache mode."""
    print("\n" + "=" * 60)
    print("[Step 4] Patching launchd_cache_loader")
    print("=" * 60)

    local_lcl = os.path.join(work_dir, "launchd_cache_loader")

    # Backup on device if needed
    if not check_remote_file_exists("/mnt1/usr/libexec/launchd_cache_loader.bak"):
        print("  Creating backup...")
        remote_cmd("/bin/cp /mnt1/usr/libexec/launchd_cache_loader "
                   "/mnt1/usr/libexec/launchd_cache_loader.bak")

    # Download from device (always from backup)
    scp_from_device("/mnt1/usr/libexec/launchd_cache_loader.bak", local_lcl)

    # Patch: NOP the secure cache check at offset 0xB58
    NOP = 0xD503201F
    print(f"  Patching offset 0x{LAUNCHD_CACHE_PATCH_OFFSET:X} with NOP...")
    patch_binary_u32(local_lcl, LAUNCHD_CACHE_PATCH_OFFSET, NOP)

    # Re-sign (adhoc is sufficient with TXM trustcache bypass)
    print("  Re-signing launchd_cache_loader...")
    run_local(f'{LDID} -S -Icom.apple.launchd_cache_loader "{local_lcl}"')

    # Upload patched binary
    scp_to_device(local_lcl, "/mnt1/usr/libexec/launchd_cache_loader")
    remote_cmd("/bin/chmod 0755 /mnt1/usr/libexec/launchd_cache_loader")

    os.remove(local_lcl)


def step_install_iosbinpack(jb_dir):
    """Install iosbinpack64 jailbreak binaries."""
    print("\n" + "=" * 60)
    print("[Step 5] Installing iosbinpack64")
    print("=" * 60)

    tar_path = os.path.join(jb_dir, "iosbinpack64.tar")
    if not os.path.exists(tar_path):
        print(f"  ERROR: {tar_path} not found!")
        print("  Download iosbinpack64 and place it at jb/iosbinpack64.tar")
        sys.exit(1)

    print("  Uploading iosbinpack64.tar to device...")
    scp_to_device(tar_path, "/mnt1/iosbinpack64.tar")

    print("  Extracting on device...")
    remote_cmd("/usr/bin/tar --preserve-permissions --no-overwrite-dir "
               "-xvf /mnt1/iosbinpack64.tar -C /mnt1")
    remote_cmd("/bin/rm /mnt1/iosbinpack64.tar")


def step_install_launch_daemons(jb_dir, work_dir):
    """Install launch daemons for bash, dropbear, and trollvnc."""
    print("\n" + "=" * 60)
    print("[Step 6] Installing launch daemons")
    print("=" * 60)

    ld_dir = os.path.join(jb_dir, "LaunchDaemons")
    os.makedirs(ld_dir, exist_ok=True)

    # Generate plists if they don't exist
    plists = {}

    # bash.plist
    bash_plist_path = os.path.join(ld_dir, "bash.plist")
    if not os.path.exists(bash_plist_path):
        print("  Generating bash.plist...")
        with open(bash_plist_path, 'wb') as f:
            plistlib.dump(make_bash_plist(), f, sort_keys=False)
    plists["bash.plist"] = bash_plist_path

    # dropbear.plist
    dropbear_plist_path = os.path.join(ld_dir, "dropbear.plist")
    if not os.path.exists(dropbear_plist_path):
        print("  Generating dropbear.plist...")
        with open(dropbear_plist_path, 'wb') as f:
            plistlib.dump(make_dropbear_plist(), f, sort_keys=False)
    plists["dropbear.plist"] = dropbear_plist_path

    # trollvnc.plist (from TrollVNC OEM)
    trollvnc_plist_path = os.path.join(ld_dir, "trollvnc.plist")
    if not os.path.exists(trollvnc_plist_path):
        if os.path.exists(str(TROLLVNC_PLIST)):
            print("  Copying trollvnc.plist from TrollVNC...")
            shutil.copy2(str(TROLLVNC_PLIST), trollvnc_plist_path)
        else:
            print(f"  WARNING: TrollVNC plist not found at {TROLLVNC_PLIST}")
            print("  Skipping trollvnc daemon installation")
    if os.path.exists(trollvnc_plist_path):
        plists["trollvnc.plist"] = trollvnc_plist_path

    # 6a. Upload plists to device
    print("\n  [6a] Uploading launch daemon plists...")
    for name, path in plists.items():
        scp_to_device(path, f"/mnt1/System/Library/LaunchDaemons/{name}")
        remote_cmd(f"/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/{name}")

    # 6b. Modify launchd.plist to inject our daemons
    print("\n  [6b] Modifying launchd.plist...")
    local_launchd_plist = os.path.join(work_dir, "launchd.plist")

    # Backup on device if needed
    if not check_remote_file_exists("/mnt1/System/Library/xpc/launchd.plist.bak"):
        print("    Creating backup...")
        remote_cmd("/bin/cp /mnt1/System/Library/xpc/launchd.plist "
                   "/mnt1/System/Library/xpc/launchd.plist.bak")

    # Download launchd.plist (always from backup)
    scp_from_device("/mnt1/System/Library/xpc/launchd.plist.bak", local_launchd_plist)

    # Convert to XML for editing
    run_local(f'{PLUTIL} -convert xml1 "{local_launchd_plist}"')

    # Load and inject each daemon
    with open(local_launchd_plist, 'rb') as f:
        launchd_data = plistlib.load(f)

    for name, path in plists.items():
        insert_key = f"/System/Library/LaunchDaemons/{name}"
        print(f"    Injecting {insert_key}...")
        with open(path, 'rb') as f:
            daemon_data = plistlib.load(f)
        launchd_data.setdefault('LaunchDaemons', {})[insert_key] = daemon_data

    with open(local_launchd_plist, 'wb') as f:
        plistlib.dump(launchd_data, f, sort_keys=False)

    # Upload modified launchd.plist
    scp_to_device(local_launchd_plist, "/mnt1/System/Library/xpc/launchd.plist")
    remote_cmd("/bin/chmod 0644 /mnt1/System/Library/xpc/launchd.plist")

    os.remove(local_launchd_plist)


def step_install_gpu_metal(gpu_bundle_path):
    """Install AppleParavirtGPUMetalIOGPUFamily.bundle from PCC."""
    print("\n" + "=" * 60)
    print("[Step 7] Installing GPU Metal support")
    print("=" * 60)

    if not gpu_bundle_path:
        print("  Skipped (no --pcc-gpu-bundle specified)")
        print("  To enable Metal GPU support, provide the path to:")
        print("    AppleParavirtGPUMetalIOGPUFamily.bundle")
        print("  from a mounted PCC SystemOS DMG at:")
        print("    /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        return

    if not os.path.isdir(gpu_bundle_path):
        print(f"  ERROR: GPU bundle not found at {gpu_bundle_path}")
        return

    print(f"  Source: {gpu_bundle_path}")
    print("  Uploading to /mnt1/System/Library/Extensions/...")
    remote_cmd("/bin/mkdir -p /mnt1/System/Library/Extensions")
    scp_to_device_recursive(
        gpu_bundle_path,
        "/mnt1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
    )

    print("  GPU Metal bundle installed.")
    print("  NOTE: You may also need libAppleParavirtCompilerPluginIOGPUFamily.dylib")
    print("  from the PCC dyld_shared_cache (requires manual extraction).")


def step_halt():
    """Halt the device."""
    print("\n" + "=" * 60)
    print("[Step 8] Halting device")
    print("=" * 60)

    remote_cmd("/sbin/halt", check=False)
    print("  Device halting. Wait for it to shut down completely before rebooting.")


# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="Set up virtual iPhone rootfs via SSH ramdisk.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
After this script completes, the device will halt.
Reboot using boot_rd.sh (but with normal kernel, not ramdisk) or
use idevicerestore to restore normally, then boot with tart.

For GPU Metal support, mount the PCC SystemOS and pass:
  --pcc-gpu-bundle /path/to/mounted/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle
""")
    parser.add_argument("--firmware-dir", "-d",
                        default=str(DEFAULT_FW_DIR),
                        help="Path to extracted IPSW restore directory")
    parser.add_argument("--jb-dir", "-j",
                        default=str(REPO_ROOT / "jb"),
                        help="Path to jailbreak files directory (default: jb/)")
    parser.add_argument("--work-dir", "-w",
                        default=None,
                        help="Working directory for temp files")
    parser.add_argument("--pcc-gpu-bundle",
                        default=None,
                        help="Path to AppleParavirtGPUMetalIOGPUFamily.bundle from PCC")
    parser.add_argument("--skip-cryptex", action="store_true",
                        help="Skip Cryptex installation")
    parser.add_argument("--skip-patches", action="store_true",
                        help="Skip seputil/launchd_cache_loader patching")
    parser.add_argument("--skip-iosbinpack", action="store_true",
                        help="Skip iosbinpack64 installation")
    parser.add_argument("--skip-daemons", action="store_true",
                        help="Skip launch daemon installation")
    parser.add_argument("--no-halt", action="store_true",
                        help="Don't halt the device when done")
    parser.add_argument("--ssh-port", default=SSH_PORT,
                        help="SSH port (default: 2222)")
    args = parser.parse_args()

    set_ssh_port(args.ssh_port)

    fw_dir = args.firmware_dir
    jb_dir = args.jb_dir
    work_dir = args.work_dir or os.path.join(
        os.path.dirname(fw_dir), "rootfs_work")

    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(jb_dir, exist_ok=True)

    print(f"Firmware directory: {fw_dir}")
    print(f"JB directory:       {jb_dir}")
    print(f"Work directory:     {work_dir}")

    # Check tools
    for name, path in [("sshpass", SSHPASS), ("ldid", LDID), ("plutil", PLUTIL)]:
        if not shutil.which(path) and not os.path.exists(path):
            print(f"ERROR: {name} not found at {path}")
            sys.exit(1)

    if not args.skip_cryptex:
        if not shutil.which(IPSW) and not os.path.exists(IPSW):
            print(f"ERROR: ipsw not found at {IPSW}")
            sys.exit(1)

    # Step 0: Verify SSH
    step_verify_ssh()

    # Step 1: Mount rootfs
    step_mount_rootfs()

    # Step 2: Install Cryptex
    if not args.skip_cryptex:
        step_install_cryptex(fw_dir, work_dir)

    # Step 3: Patch seputil
    if not args.skip_patches:
        step_patch_seputil(work_dir)

    # Step 4: Patch launchd_cache_loader
    if not args.skip_patches:
        step_patch_launchd_cache_loader(work_dir)

    # Step 5: Install iosbinpack64
    if not args.skip_iosbinpack:
        step_install_iosbinpack(jb_dir)

    # Step 6: Install launch daemons
    if not args.skip_daemons:
        step_install_launch_daemons(jb_dir, work_dir)

    # Step 7: GPU Metal
    step_install_gpu_metal(args.pcc_gpu_bundle)

    # Step 8: Halt
    if not args.no_halt:
        step_halt()

    print("\n" + "=" * 60)
    print("DONE - Rootfs setup complete")
    print("=" * 60)
    print()
    if not args.no_halt:
        print("Device is halting. After shutdown, boot normally with tart.")
    print("First boot services: bash, dropbear (SSH), trollvnc")
    print()
    print("After normal boot, connect via:")
    print("  iproxy 2222 22 &")
    print("  ssh root@127.0.0.1 -p2222  (password: alpine)")


if __name__ == "__main__":
    main()
