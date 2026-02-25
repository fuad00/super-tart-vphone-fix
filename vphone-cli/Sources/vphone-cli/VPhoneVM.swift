import Foundation
import Virtualization
import VPhoneObjC

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
class VPhoneVM: NSObject, VZVirtualMachineDelegate {
  let virtualMachine: VZVirtualMachine
  private var done = false

  struct Options {
    var romURL: URL
    var nvramURL: URL
    var diskURL: URL
    var cpuCount: Int = 4
    var memorySize: UInt64 = 4 * 1024 * 1024 * 1024
    var skipSEP: Bool = true
    var serial: Bool = false
    var serialPath: String? = nil
    var gdbPort: Int = 8000
    var stopOnPanic: Bool = false
    var stopOnFatalError: Bool = false
  }

  init(options: Options) throws {
    // --- Hardware model (PV=3) ---
    let hwModel = try VPhoneHardware.createModel()
    print("[vphone] PV=3 hardware model: isSupported = true")

    // --- Platform ---
    let platform = VZMacPlatformConfiguration()
    platform.machineIdentifier = VZMacMachineIdentifier()
    platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
      creatingStorageAt: options.nvramURL,
      hardwareModel: hwModel,
      options: .allowOverwrite
    )
    platform.hardwareModel = hwModel
    VPhoneDisableProductionMode(platform)

    // --- Boot loader with custom ROM ---
    let bootloader = VZMacOSBootLoader()
    VPhoneSetBootLoaderROMURL(bootloader, options.romURL)

    // --- VM Configuration ---
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootloader
    config.platform = platform
    config.cpuCount = max(options.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    config.memorySize = max(options.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

    // Display
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [
      VZMacGraphicsDisplayConfiguration(widthInPixels: 1024, heightInPixels: 768, pixelsPerInch: 72)
    ]
    config.graphicsDevices = [gfx]

    // Audio (null speaker — DFU doesn't need audio)
    let sound = VZVirtioSoundDeviceConfiguration()
    sound.streams = [VZVirtioSoundDeviceOutputStreamConfiguration()]
    config.audioDevices = [sound]

    // Input
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    // Storage
    if FileManager.default.fileExists(atPath: options.diskURL.path) {
      let attachment = try VZDiskImageStorageDeviceAttachment(url: options.diskURL, readOnly: false)
      config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
    }

    // Entropy
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    // Network (shared NAT)
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [net]

    // Serial port
    if options.serial {
      if let port = Self.makeSerialPort() {
        config.serialPorts = [port]
      }
    } else if let path = options.serialPath {
      if let port = Self.makeSerialPort(path: path) {
        config.serialPorts = [port]
      }
    }

    // GDB debug stub
    VPhoneSetGDBDebugStub(config, options.gdbPort)

    // Panic device
    VPhoneSetPanicDevice(config)

    // Coprocessors
    if options.skipSEP {
      print("[vphone] SKIP_SEP=1 — no coprocessor")
    } else {
      print("[vphone] SEP not yet implemented, continuing without")
    }

    // Validate
    try config.validate()
    print("[vphone] Configuration validated")

    virtualMachine = VZVirtualMachine(configuration: config)
    super.init()
    virtualMachine.delegate = self
  }

  // MARK: - DFU start

  @MainActor
  func startDFU(stopOnPanic: Bool, stopOnFatalError: Bool) async throws {
    let opts = VZMacOSVirtualMachineStartOptions()
    VPhoneConfigureStartOptions(opts, stopOnPanic, stopOnFatalError)
    print("[vphone] Starting DFU...")
    try await virtualMachine.start(options: opts)
    print("[vphone] VM started in DFU mode — connect with irecovery")
  }

  // MARK: - Wait

  func waitUntilStopped() async {
    while !done {
      try? await Task.sleep(nanoseconds: 500_000_000)
    }
  }

  // MARK: - Delegate

  func guestDidStop(_ vm: VZVirtualMachine) {
    print("[vphone] Guest stopped")
    done = true
  }

  func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
    print("[vphone] Stopped with error: \(error)")
    done = true
  }

  func virtualMachine(_ vm: VZVirtualMachine, networkDevice: VZNetworkDevice,
                       attachmentWasDisconnectedWithError error: Error) {
    print("[vphone] Network error: \(error)")
  }

  // MARK: - PTY helpers

  private static func makeSerialPort() -> VZSerialPortConfiguration? {
    var ttyFD: Int32 = -1
    var sfd: Int32 = -1
    let path = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
    defer { path.deallocate() }

    guard openpty(&ttyFD, &sfd, path, nil, nil) >= 0 else {
      perror("openpty"); return nil
    }
    close(sfd)

    let flags = fcntl(ttyFD, F_GETFL)
    guard flags >= 0 else { perror("fcntl"); return nil }
    guard fcntl(ttyFD, F_SETFL, flags | O_NONBLOCK) >= 0 else { perror("fcntl"); return nil }

    var t = termios()
    tcgetattr(ttyFD, &t)
    cfsetispeed(&t, speed_t(B115200))
    cfsetospeed(&t, speed_t(B115200))
    tcsetattr(ttyFD, TCSANOW, &t)

    print("[vphone] PTY: \(String(cString: path))")

    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: FileHandle(fileDescriptor: ttyFD),
      fileHandleForWriting: FileHandle(fileDescriptor: ttyFD)
    )
    return port
  }

  private static func makeSerialPort(path: String) -> VZSerialPortConfiguration? {
    guard let r = FileHandle(forReadingAtPath: path),
          let w = FileHandle(forWritingAtPath: path) else {
      print("[vphone] Cannot open serial path: \(path)")
      return nil
    }
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: r, fileHandleForWriting: w)
    return port
  }
}

// MARK: - Errors

enum VPhoneError: Error, CustomStringConvertible {
  case hardwareModelNotSupported
  case romNotFound(String)

  var description: String {
    switch self {
    case .hardwareModelNotSupported:
      return """
        PV=3 hardware model not supported. Check:
          1. macOS >= 15.0 (Sequoia)
          2. Signed with com.apple.private.virtualization + \
        com.apple.private.virtualization.security-research
          3. SIP/AMFI disabled
        """
    case .romNotFound(let p):
      return "ROM not found: \(p)"
    }
  }
}
