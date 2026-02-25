import ArgumentParser
import Foundation
import Virtualization
import AppKit

@main
struct VPhoneCLI: AsyncParsableCommand {
  static var configuration = CommandConfiguration(
    commandName: "vphone-cli",
    abstract: "Boot a virtual iPhone (PV=3) in DFU mode",
    discussion: """
      Creates a Virtualization.framework VM with platform version 3 (vphone)
      and boots it into DFU mode for firmware loading via irecovery.

      Requires:
        - macOS 15+ (Sequoia or later)
        - SIP/AMFI disabled
        - Signed with vphone entitlements (done automatically by wrapper script)

      Example:
        vphone-cli --rom firmware/rom.bin --disk firmware/disk.img --serial
      """
  )

  @Option(help: "Path to the AVPBooter / ROM binary")
  var rom: String

  @Option(help: "Path to the disk image")
  var disk: String

  @Option(help: "Path to NVRAM storage (created/overwritten)")
  var nvram: String = "nvram.bin"

  @Option(help: "Number of CPU cores")
  var cpu: Int = 4

  @Option(help: "Memory size in MB")
  var memory: Int = 4096

  @Flag(help: "Allocate a PTY for serial console")
  var serial: Bool = false

  @Option(help: "Path to an existing serial device")
  var serialPath: String? = nil

  @Option(help: "GDB debug stub port")
  var gdbPort: Int = 8000

  @Flag(help: "Stop VM on guest panic")
  var stopOnPanic: Bool = false

  @Flag(help: "Stop VM on fatal error")
  var stopOnFatalError: Bool = false

  @Flag(help: "Skip SEP coprocessor setup")
  var skipSep: Bool = false

  @Option(help: "Path to SEP storage file (created if missing)")
  var sepStorage: String? = nil

  @Option(help: "Path to SEP ROM binary")
  var sepRom: String? = nil

  @Flag(help: "Run without GUI (headless)")
  var noGraphics: Bool = false

  @MainActor
  mutating func run() async throws {
    let romURL = URL(fileURLWithPath: rom)
    guard FileManager.default.fileExists(atPath: romURL.path) else {
      throw VPhoneError.romNotFound(rom)
    }

    let diskURL = URL(fileURLWithPath: disk)
    let nvramURL = URL(fileURLWithPath: nvram)

    print("=== vphone-cli ===")
    print("ROM   : \(rom)")
    print("Disk  : \(disk)")
    print("NVRAM : \(nvram)")
    print("CPU   : \(cpu)")
    print("Memory: \(memory) MB")
    print("GDB   : localhost:\(gdbPort)")
    let sepStorageURL = sepStorage.map { URL(fileURLWithPath: $0) }
    let sepRomURL = sepRom.map { URL(fileURLWithPath: $0) }

    print("SEP   : \(skipSep ? "skipped" : "enabled")")
    if !skipSep {
      print("  storage: \(sepStorage ?? "(auto)")")
      if let r = sepRom { print("  rom    : \(r)") }
    }
    print("")

    let options = VPhoneVM.Options(
      romURL: romURL,
      nvramURL: nvramURL,
      diskURL: diskURL,
      cpuCount: cpu,
      memorySize: UInt64(memory) * 1024 * 1024,
      skipSEP: skipSep,
      sepStorageURL: sepStorageURL,
      sepRomURL: sepRomURL,
      serial: serial,
      serialPath: serialPath,
      gdbPort: gdbPort,
      stopOnPanic: stopOnPanic,
      stopOnFatalError: stopOnFatalError
    )

    let vm = try VPhoneVM(options: options)

    // Handle Ctrl+C
    signal(SIGINT, SIG_IGN)
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT)
    sigintSrc.setEventHandler {
      print("\n[vphone] SIGINT — shutting down")
      Foundation.exit(0)
    }
    sigintSrc.activate()

    // Start DFU
    try await vm.startDFU(stopOnPanic: stopOnPanic, stopOnFatalError: stopOnFatalError)

    if noGraphics {
      // Headless: just wait
      NSApplication.shared.setActivationPolicy(.prohibited)
      await vm.waitUntilStopped()
    } else {
      // GUI: run app event loop
      await vm.waitUntilStopped()
    }
  }
}
