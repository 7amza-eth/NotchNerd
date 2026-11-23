//
//  DDC.swift
//  NotchNerd
//
//  DDC/CI for external monitors on Apple Silicon: brightness, contrast, volume, input. Talks to the
//  monitor over the IOAVService I2C channel (private IOKit symbols, the same path MonitorControl and
//  m1ddc use). Built-in displays don't speak DDC; they go through BrightnessManager instead.
//
//  Mapping services to displays: each external "DCPAVServiceProxy" is matched to a CGDirectDisplayID
//  by order (both sorted). That's right for one external monitor, best effort for several.
//

import CoreGraphics
import Foundation
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62
    case mute = 0x8D
}

final class DDCChannel {
    private let service: CFTypeRef
    private let lock = NSLock()
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    init(service: CFTypeRef) { self.service = service }

    /// Reads (current, max). nil when the monitor doesn't answer (DDC off, or an adapter that blocks it).
    func read(_ code: VCP) -> (current: Int, max: Int)? {
        lock.lock(); defer { lock.unlock() }
        var packet: [UInt8] = [0x82, 0x01, code.rawValue, 0]
        packet[3] = Self.checksum(seed: 0x6E ^ UInt8(Self.dataAddress), packet[0..<3])
        for _ in 0..<3 {
            var out = packet
            guard IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &out, UInt32(out.count)) == KERN_SUCCESS else {
                usleep(20_000); continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, Self.chipAddress, 0, &reply, UInt32(reply.count)) == KERN_SUCCESS else {
                usleep(20_000); continue
            }
            // reply: [src, len, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk]
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { usleep(20_000); continue }
            let maxValue = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            return (current, max(maxValue, 1))
        }
        return nil
    }

    @discardableResult
    func write(_ code: VCP, _ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = UInt16(clamping: max(0, value))
        var packet: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = Self.checksum(seed: 0x6E ^ UInt8(Self.dataAddress), packet[0..<5])
        var ok = false
        // Monitors drop the odd packet; send twice like MonitorControl does.
        for _ in 0..<2 {
            var out = packet
            if IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &out, UInt32(out.count)) == KERN_SUCCESS { ok = true }
            usleep(10_000)
        }
        return ok
    }

    private static func checksum(seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// One channel per external display, keyed by display ID.
    static func channels(for externalDisplays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCChannel] {
        var services: [CFTypeRef] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(av)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        for (display, service) in zip(externalDisplays.sorted(), services) {
            result[display] = DDCChannel(service: service)
        }
        return result
    }
}
