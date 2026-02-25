# Agents

This repository documents the process of building a virtual iPhone using the VPHONE600AP component from Apple's PCC (Private Cloud Compute) firmware.

## Repository Structure

- `oems/` — Git submodules of upstream dependencies (super-tart, libirecovery, img4tool, etc.)
- `patch_oems/` — Patched OEM source files for building custom binaries (output to `bin/`)
- `bin/` — Built binaries from patched OEMs (gitignored)
- `contents/` — Writeup images and supplementary files referenced by README
- `document-snippets/` — External reference documents and guides
- `patch_scripts/` — Python scripts and raw binaries for firmware patching (gitignored)
- `firmwares/` — Firmware IPSW files and extracted/patched firmware trees (gitignored)
- `checkpoints/` — Tarball snapshots of intermediate build stages (gitignored)

## Workflow

1. Extract firmware components from IPSW using tools in `oems/`
2. Patch bootchain (AVPBooter, iBSS, iBEC, LLB, TXM, kernel) to bypass signature verification
3. Build patched IM4P images and restore via idevicerestore in DFU mode
4. Use SSH Ramdisk to inject Cryptex, trustcache, and launch daemons
5. Patch GPU Metal support by porting AppleParavirtGPUMetalIOGPUFamily from PCC

## Key Tools

- `img4tool` / `img4lib` — IM4P pack/unpack
- `pyimg4` — Python IM4P/IMG4 manipulation
- `idevicerestore` / `libirecovery` — Firmware restore and DFU communication
- `trustcache` — Trustcache generation
- `super-tart` — Modified tart VM with DFU/serial/GDB support
- `SSHRD_Script` — SSH Ramdisk for rootfs modification
- `TrollVNC` — VNC server for touch interaction
