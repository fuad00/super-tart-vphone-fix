# super-tart vphone600ap writeup — script-first quickstart

This repo automates building a virtual iPhone using the vphone600ap PCC firmware mix. The fastest path is to run the scripts below in order.

## Prereqs

- macOS on Apple Silicon
- SIP/AMFI disabled (required by super-tart / private Virtualization.framework APIs)
- Homebrew dependencies installed (see `setup_bin.sh` header)

## Quickstart (full flow)

```bash
# 1) Build all tools (submodules, deps, venv, tart)
bash setup_bin.sh

# 2) Activate environment (adds PATH, TART_HOME, pyimg4, etc.)
source setup_env.sh

# 3) Download + mix firmware (large downloads)
bash setup_download_fw.sh

# 4) Patch bootchain binaries
cd patch_scripts
python3 patch_fw.py -d ../firmwares/firmware_patched/iPhone17,3_26.1_23B85_Restore

# 5) Build the SSH ramdisk + sign IMG4
python3 prepare_ramdisk.py

# 6) Start the VM in DFU mode (TART_HOME is isolated to .tart/)
cd ..
./vm_boot_dfu.sh vphone

# 7) Boot ramdisk via irecovery
cd patch_scripts
bash boot_rd.sh

# 8) Configure rootfs from the ramdisk (Cryptex, daemons, GPU)
python3 setup_rootfs.py
```

## Script reference

- `setup_bin.sh`
  - Builds OEM tools and installs them into `bin/`.
  - Patches `super-tart`'s `VM.swift` for vphone mode (gated by `VPHONE_MODE=1`).
  - Uses repo-local SwiftPM caches to build `tart` reliably.
- `setup_env.sh`
  - Must be sourced (not executed).
  - Sets `TART_HOME` to `.tart/` in the repo.
- `setup_download_fw.sh`
  - Downloads iPhone + PCC IPSWs and mixes firmware into a patched restore directory.
- `patch_scripts/patch_fw.py`
  - Patches bootchain binaries (iBSS/iBEC/LLB/TXM/kernel/AVPBooter).
- `patch_scripts/prepare_ramdisk.py`
  - Builds SSH ramdisk and signs IMG4 components.
- `vm_boot_dfu.sh`
  - Runs `tart` in DFU mode with isolated `TART_HOME`.
  - Exports `VPHONE_MODE=1` to enable vphone-specific VM config.
- `patch_scripts/boot_rd.sh`
  - Loads the IMG4 stack into DFU VM via `irecovery`.
- `patch_scripts/setup_rootfs.py`
  - Copies Cryptex and installs required daemons via SSH.

## Checkpoints (optional)

If you have a checkpoint tarball, extract it at repo root to skip parts of the workflow. See `AGENTS.md` for the exact mapping.

## Common pitfalls

- `tart` build fails: make sure to run `bash setup_bin.sh` (it now uses repo-local SwiftPM caches and disables SwiftPM sandbox).
- `tart` VMs appear in your home folder: ensure `source setup_env.sh` before running, or use `TART_HOME=...` explicitly.
- Missing tools in `bin/`: rerun `setup_bin.sh` after installing Homebrew deps.
