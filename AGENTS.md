# Agents

This repository documents the process of building a virtual iPhone using the VPHONE600AP component from Apple's PCC (Private Cloud Compute) firmware. Based on cloudOS 23B85 (PCC) + iOS 26.1 23B85 (iPhone17,3) mixed firmware.

## Repository Structure

```
├── oems/                  # Git submodules (11 upstream deps)
├── patch_oems/            # Patched OEM sources → builds to bin/
├── bin/                   # Built binaries (gitignored, 11 tools)
├── contents/              # Writeup images, BuildManifest.plist, Restore.plist
├── document-snippets/     # Reference docs (AVPBooter patching, vma2pwn, IDA guide)
├── patch_scripts/         # Firmware patching scripts
│   ├── patch_fw.py        # Patch bootchain (iBSS/iBEC/LLB/TXM/kernel/AVPBooter)
│   ├── prepare_ramdisk.py # Build SSH ramdisk + sign IMG4 firmware
│   ├── setup_rootfs.py    # Install Cryptex, daemons, GPU via SSH
│   ├── boot_rd.sh         # Load IMG4 into DFU VM via irecovery
│   ├── find_patches.py    # Discover patch offsets with capstone disassembly
│   ├── find_image4_cb.py  # Find image4_validate_property_callback
│   └── raw/               # Extracted raw binaries for analysis (gitignored)
├── firmwares/             # IPSW files + firmware_patched/ tree (gitignored)
├── checkpoints/           # Tarball snapshots of build stages (gitignored)
├── setup_bin.sh           # Build all OEM tools from submodules
├── setup_download_fw.sh   # Download iPhone + PCC IPSW, mix firmware
├── setup_env.sh           # Environment setup (must be sourced)
└── requirements.txt       # Python deps (pyimg4, capstone)
```

## Checkpoints

Tarball snapshots of intermediate build stages. These are **not tracked in git** (gitignored). They must be created locally or obtained separately.

| Checkpoint | Size | Contents | Equivalent step |
|---|---|---|---|
| `01-mixed-firmware-unpatch.tar` | ~10 GB | `firmwares/firmware_patched/` after mixing iPhone + PCC components (before patching) | After `setup_download_fw.sh` |
| `02-raw-binaries-extracted.tar` | ~44 MB | `patch_scripts/raw/` — iBSS.raw, iBEC.raw, LLB.raw, txm.raw, kcache.raw, AVPBooter.raw | After extracting IM4P payloads |
| `03-firmware-patched.tar` | ~10 GB | `firmwares/firmware_patched/` after all patches applied | After `patch_fw.py` |
| `04-patches-verified-ida.tar` | ~44 MB | `patch_scripts/raw/` with IDA analysis databases | After verifying patches in IDA |

**To resume from a checkpoint:** extract the tarball to the repo root. For example:
- Checkpoint 03 → skip steps 1-4, go straight to `prepare_ramdisk.py`
- Checkpoint 01 → skip firmware download, start from `patch_fw.py`

## Gitignored Artifacts (require network or checkpoints)

These directories are gitignored and need to be populated before the workflow can run:

| Directory | How to populate | Network required |
|---|---|---|
| `bin/` | `bash setup_bin.sh` (builds from submodules) | Yes (submodule fetch, homebrew) |
| `.local/` | Built by `setup_bin.sh` (libgeneral, pkg-config) | Yes |
| `.venv/` | `setup_bin.sh` or `python3 -m venv .venv && pip install -r requirements.txt` | Yes (PyPI) |
| `firmwares/*.ipsw` | `bash setup_download_fw.sh` (~11 GB total) | Yes (Apple CDN) |
| `firmwares/firmware_patched/` | `bash setup_download_fw.sh` or extract checkpoint 01/03 | Yes (unless checkpoint) |
| `patch_scripts/raw/` | Extracted during patching or extract checkpoint 02/04 | No (local extraction) |
| `checkpoints/` | Created manually at each stage | No |

## Workflow

```
1. bash setup_bin.sh          # Build tools (requires network)
2. source setup_env.sh        # Activate environment
3. bash setup_download_fw.sh  # Download + mix firmware (requires network, ~11 GB)
4. cd patch_scripts
5. python3 patch_fw.py -d ../firmwares/firmware_patched/iPhone17,3_26.1_23B85_Restore
                              # Patch bootchain binaries
6. python3 prepare_ramdisk.py # Build SSH ramdisk + sign IMG4 (requires VM in DFU)
7. bash boot_rd.sh            # Boot ramdisk in VM via irecovery
8. python3 setup_rootfs.py    # Install Cryptex, daemons, GPU via SSH
```

**Host requirements:** macOS with SIP/AMFI disabled (super-tart uses private Virtualization.framework APIs).

## Firmware Downloads

No Apple binaries stored in repo. Downloaded from official Apple CDN:

- **iPhone IPSW** (~10 GB): `iPhone17,3_26.1_23B85_Restore.ipsw` — SystemVolume, Cryptex, RestoreRamDisk, TrustCaches
- **PCC IPSW** (~892 MB): `pcc_os_23B85.ipsw` — vphone/vresearch bootchain (iBSS, iBEC, LLB, kernel, TXM, DeviceTree, AGX, ANE)

## Patches Applied

| Binary | Patches | Purpose |
|---|---|---|
| AVPBooter | 1 | image4_validate_property_callback → return 0 |
| iBSS | 2 | Signature verification bypass |
| iBEC | 5 | Sig bypass + boot-args override (`serial=3 -v debug=0x2014e`) |
| LLB | 11 | Sig bypass + boot-args + SSV bypass (5 patches) |
| TXM | 3 | Trustcache bypass (allow unsigned binaries) |
| Kernel | 3 | SSV bypass (prevent boot panics on modified rootfs) |

ARM64 constants: NOP=`0xD503201F`, MOV X0,#0=`0xD2800000`

## Key Tools

- `img4tool` / `img4lib` (`img4`) — IM4P pack/unpack and IMG4 signing
- `pyimg4` — Python IM4P/IMG4 manipulation (preserves PAYP for TXM/kernel)
- `idevicerestore` / `libirecovery` (`irecovery`) — Firmware restore and DFU communication
- `trustcache` — Trustcache generation
- `super-tart` (`tart`) — Modified tart VM with DFU/serial/GDB support
- `SSHRD_Script` — SSH ramdisk components (`sshtars/ssh.tar`)
- `TrollVNC` — VNC server for touch interaction
- `ldid` — Code signing (re-sign binaries in ramdisk/rootfs)
- `sshpass` / `iproxy` — SSH automation through USB tunnel

## Binary Base Addresses (for IDA)

| Binary | Base Address |
|---|---|
| iBSS/iBEC/LLB | `0x7006C000` |
| AVPBooter | `0x100000` |
| TXM | `0xFFFFFFF017004000` (Mach-O) |
| Kernel | `0xFFFFFE0007004000` (Mach-O) |

## Submodules (oems/)

libgeneral, img4lib, img4tool, trustcache, libirecovery, idevicerestore, super-tart, SSHRD_Script, TrollVNC, security-pcc, vma2pwn
