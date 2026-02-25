# vma2pwn prepare.sh reference
Source: https://github.com/nick-botticelli/vma2pwn/blob/main/prepare.sh

## Components patched:
- iBSS, iBEC, LLB, iBoot - bootloader chain
- Kernelcache
- Restore Ramdisk (restored_external, asr_ramdisk)
- AVPBooter

## Process: img4 extract -> bspatch43 patch -> img4tool repack -> ldid sign
