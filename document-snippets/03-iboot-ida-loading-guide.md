# How to Load iBoot in IDA Pro (ARM64)

Source: User-provided guide (originally for iPhone 6,1 / iPhone 5s iBoot analysis)

## Context
- Originally written for iPhone6,1 (codename "6", actually iPhone 5s)
- macOS v10.13.1, IDA v7.0
- Firmware: iOS v11.0 15A372, iBoot.iphone6.RELEASE.bin
- Adapted for our use with vresearch101 iBoot binaries

## Steps

1. Drag the binary (e.g., `iBSS.raw`) into **IDA64** (the one with "64" on the icon).
2. Change **"Processor type"** to **"ARM Little-endian [ARM]"**, click **OK**.
3. IDA asks "Do you want to change the processor type to ARM?" → click **YES**.
4. IDA shows "Disassembly memory organization" → no changes needed, click **OK**.
5. IDA asks "Do you want to disassemble it as 64-bit code?" → click **YES**.
6. The iBoot is now loaded as Data at address 0. We need to **Rebase**.
7. At `ROM:0000000000000000`, press **"c"** key to convert data to code.
8. Look for the LDR instruction near the top — e.g., `LDR X1, =0x830000000` — this reveals the base address. For our binaries:
   - iBSS/iBEC: base = `0x7006C000`
   - LLB: base = `0x7006C000`
   - AVPBooter: base = `0x100000`
9. Rebase: **Edit → Segments → Rebase program...** → set base address accordingly.
10. Now let IDA re-analyze the binary.
11. Select all: **Edit → Select all**.
12. Press **"c"** to convert all data to code.
13. IDA shows a dialog → select **"Analyze"**.
14. IDA asks for confirmation → select **YES**.
15. Done. The binary should now be fully disassembled with correct addresses.

## Our Binary Base Addresses

| Binary | Base Address | Type |
|---|---|---|
| iBSS.raw | `0x7006C000` | iBoot bootloader |
| iBEC.raw | `0x7006C000` | iBoot bootloader |
| LLB.raw | `0x7006C000` | iBoot bootloader |
| AVPBooter.raw | `0x100000` | BootROM |
| txm.raw | `0xFFFFFFF017004000` | Mach-O (auto-detect) |
| kcache.raw | `0xFFFFFE0007004000` | Mach-O (auto-detect) |
