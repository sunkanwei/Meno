import Darwin
import Foundation
import IOKit
import OSLog

struct PhilipsInputControl: Sendable {
  private static let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "SoftKVM")
  let displayController: DisplayHardwareController

  func select(_ input: PhilipsInput) async throws {
    try await confirm(input, allowWrite: true, timeout: .seconds(4))
  }

  func verify(_ input: PhilipsInput) async throws {
    try await confirm(input, allowWrite: false, timeout: .seconds(1))
  }

  private func confirm(
    _ input: PhilipsInput,
    allowWrite: Bool,
    timeout: Duration
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var sent = false
    var lastFailure = "未能读取当前输入"
    repeat {
      try Task.checkCancellation()
      do {
        let location = try await displayController.philipsDisplayLocation()
        let transport = try PhilipsDDCTransport(location: location)
        let current = try transport.readInput()
        if current == input.rawValue {
          Self.logger.info("Philips input verified: \(input.title, privacy: .public)")
          return
        }
        let currentTitle = PhilipsInput(rawValue: current)?.title ?? String(format: "0x%02X", current)
        lastFailure = "显示器当前仍报告 \(currentTitle)"
        if allowWrite, !sent {
          try Task.checkCancellation()
          try transport.send(PhilipsInputPacket.request(input))
          sent = true
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastFailure = error.localizedDescription
      }
      try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(250)), deadline))
    } while clock.now < deadline

    throw DisplayControlError.verification("飞利浦未确认切到 \(input.title)：\(lastFailure)")
  }
}

// The Apple Silicon HDMI transport and timing follow waydabber/m1ddc (MIT).
private final class PhilipsDDCTransport {
  private typealias CreateService =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  private typealias WriteI2C =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer?, UInt32) -> IOReturn
  private typealias ReadI2C =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

  private let library: UnsafeMutableRawPointer
  private let service: Unmanaged<CFTypeRef>
  private let chipAddress: UInt32
  private let write: WriteI2C
  private let read: ReadI2C

  init(location: String) throws {
    let proxy = try Self.copyExternalProxy(location: location)
    defer { IOObjectRelease(proxy) }

    guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    else {
      throw DisplayControlError.privateAPI("无法载入 HDMI 控制接口")
    }
    guard let create = dlsym(library, "IOAVServiceCreateWithService"),
      let write = dlsym(library, "IOAVServiceWriteI2C"),
      let read = dlsym(library, "IOAVServiceReadI2C"),
      let service = unsafeBitCast(create, to: CreateService.self)(kCFAllocatorDefault, proxy)
    else {
      dlclose(library)
      throw DisplayControlError.privateAPI("HDMI 控制接口不可用")
    }

    self.library = library
    self.service = service
    self.write = unsafeBitCast(write, to: WriteI2C.self)
    self.read = unsafeBitCast(read, to: ReadI2C.self)
    var parent: io_registry_entry_t = 0
    if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
      defer { IOObjectRelease(parent) }
      chipAddress = Self.property("EPICProviderClass", on: parent) == "AppleDCPMCDP29XX"
        ? 0xB7 : 0x37
    } else {
      chipAddress = 0x37
    }
  }

  deinit {
    service.release()
    dlclose(library)
  }

  func readInput() throws -> UInt8 {
    try send(PhilipsInputPacket.request())
    Thread.sleep(forTimeInterval: chipAddress == 0xB7 ? 0.05 : 0.01)
    var reply = [UInt8](repeating: 0, count: 12)
    let result = reply.withUnsafeMutableBytes {
      read(service.takeUnretainedValue(), chipAddress, PhilipsInputPacket.dataAddress,
        $0.baseAddress, UInt32($0.count))
    }
    guard result == KERN_SUCCESS else {
      throw DisplayControlError.privateAPI("读取飞利浦输入源失败（\(result)）")
    }
    guard let input = PhilipsInputPacket.readback(reply) else {
      throw DisplayControlError.verification("未收到有效的飞利浦输入源回包")
    }
    return input
  }

  func send(_ message: [UInt8]) throws {
    for _ in 0..<2 {
      Thread.sleep(forTimeInterval: 0.01)
      let result = message.withUnsafeBytes {
        write(service.takeUnretainedValue(), chipAddress, PhilipsInputPacket.dataAddress,
          $0.baseAddress, UInt32($0.count))
      }
      guard result == KERN_SUCCESS else {
        throw DisplayControlError.privateAPI("飞利浦 HDMI 控制指令发送失败（\(result)）")
      }
    }
  }

  private static func copyExternalProxy(location: String) throws -> io_service_t {
    let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
    guard adapter != 0 else {
      throw DisplayControlError.privateAPI("飞利浦的 HDMI 适配器暂不可用")
    }
    defer { IOObjectRelease(adapter) }
    let edid = IORegistryEntrySearchCFProperty(
      adapter, kIOServicePlane, "EDID UUID" as CFString, kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively)
    ) as? String
    guard edid?.uppercased() == FixedDisplayConfiguration.philipsEDIDUUID,
      let controller = location.split(separator: "/").dropLast().last?
        .split(separator: "@").first
    else {
      throw DisplayControlError.privateAPI("无法识别飞利浦的 HDMI 适配器")
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
    ) == KERN_SUCCESS
    else {
      throw DisplayControlError.privateAPI("无法枚举 HDMI 控制接口")
    }
    defer { IOObjectRelease(iterator) }

    // The framebuffer and its DCP service share the display controller's name.
    let providerPrefix = "\(controller):dcpav-service-epic:"
    var match: io_service_t = 0
    while case let entry = IOIteratorNext(iterator), entry != 0 {
      guard property("Location", on: entry) == "External",
        providerName(of: entry)?.hasPrefix(providerPrefix) == true
      else {
        IOObjectRelease(entry)
        continue
      }
      guard match == 0 else {
        IOObjectRelease(entry)
        IOObjectRelease(match)
        throw DisplayControlError.privateAPI("飞利浦对应多个外接 HDMI 控制接口")
      }
      match = entry
    }
    guard match != 0 else {
      throw DisplayControlError.privateAPI("找不到飞利浦的外接 HDMI 控制接口")
    }
    return match
  }

  private static func providerName(of proxy: io_service_t) -> String? {
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(parent) }
    var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
    guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return nil }
    return name.withUnsafeBufferPointer { buffer in
      buffer.baseAddress.flatMap { String(validatingCString: $0) }
    }
  }

  private static func property(_ name: String, on entry: io_registry_entry_t) -> String? {
    IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}
