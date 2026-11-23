//
//  VirtualHiDPI.swift
//  NotchNerd
//
//  HiDPI ("sharper text") for monitors that don't offer HiDPI modes, the way BetterDisplay does it:
//  create a virtual display at twice the monitor's pixel size with HiDPI modes, then mirror the real
//  monitor onto it. macOS renders the desktop at 2x and scales it down onto the panel.
//
//  The virtual display exists only while its CGVirtualDisplay object is alive, so NotchNerd holds them
//  here and re-creates them at launch for the monitors in Defaults[.displayVirtualHiDPI].
//  Virtual displays carry vendor `VirtualHiDPI.vendorID`, which DisplayManager uses to hide them from
//  the list and fold their modes into the physical monitor's card.
//

import CoreGraphics
import Foundation

@MainActor
final class VirtualHiDPI {
    static let shared = VirtualHiDPI()
    static let vendorID: UInt32 = 0x4E4E   // "NN"

    /// physical display UUID → virtual display
    private var virtuals: [String: CGVirtualDisplay] = [:]

    private init() {}

    func virtualID(forPhysical uuid: String) -> CGDirectDisplayID? {
        virtuals[uuid]?.displayID
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID
    }

    /// Creates the virtual display for `physical` and mirrors the monitor onto it. Returns the
    /// virtual display ID, or nil if macOS refused.
    @discardableResult
    func enable(physical: CGDirectDisplayID, uuid: String, name: String) -> CGDirectDisplayID? {
        if let existing = virtuals[uuid] { return existing.displayID }

        // The panel's native pixel size: the largest mode's pixels.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(physical, options) as? [CGDisplayMode]) ?? []
        guard let native = modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else { return nil }
        let w = native.pixelWidth, h = native.pixelHeight
        let refresh = max(30, native.refreshRate.rounded() == 0 ? 60 : native.refreshRate)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "\(name) (HiDPI)"
        descriptor.maxPixelsWide = UInt32(w * 2)
        descriptor.maxPixelsHigh = UInt32(h * 2)
        let mm = CGDisplayScreenSize(physical)
        descriptor.sizeInMillimeters = mm.width > 0 ? mm : CGSize(width: 600, height: 340)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = UInt32(truncatingIfNeeded: CGDisplayModelNumber(physical))
        descriptor.serialNum = UInt32(truncatingIfNeeded: CGDisplaySerialNumber(physical) &+ 1)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        // "Looks like" sizes from native down to about half, keeping the aspect ratio. With hiDPI on,
        // each is offered at 2x pixels.
        let scales: [Double] = [1, 0.9, 0.85, 0.8, 0.75, 0.7, 0.667, 0.6, 0.5]
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = scales.map { s in
            let mw = UInt32((Double(w) * s / 2).rounded() * 2)
            let mh = UInt32((Double(h) * s / 2).rounded() * 2)
            return CGVirtualDisplayMode(width: mw, height: mh, refreshRate: refresh)
        }
        guard display.apply(settings) else { return nil }
        virtuals[uuid] = display

        // Give macOS a moment to bring the new display online, then mirror the monitor onto it.
        let vid = display.displayID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayMirrorOfDisplay(config, physical, vid)
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        return vid
    }

    /// Stops mirroring and removes the virtual display.
    func disable(physical: CGDirectDisplayID, uuid: String) {
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success {
            CGConfigureDisplayMirrorOfDisplay(config, physical, kCGNullDirectDisplay)
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        virtuals[uuid] = nil   // releasing the object removes the display
    }
}

#if DEBUG
extension VirtualHiDPI {
    /// Dev check (`-debugVirtualProbe YES`): creates a 1920×1080 HiDPI virtual display without
    /// mirroring anything, writes the modes macOS reports to /tmp/notchnerd-virtual-probe.txt, and
    /// removes it after 4 s.
    func debugProbe() {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "NotchNerd probe"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        var log = ""
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            try? "create failed".write(toFile: "/tmp/notchnerd-virtual-probe.txt", atomically: true, encoding: .utf8)
            return
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
                          CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60)]
        log += "apply=\(display.apply(settings)) id=\(display.displayID)\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode]) ?? []
            log += "virtual=\(Self.isVirtual(display.displayID)) modes=\(modes.count)\n"
            for m in modes { log += "  \(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight)\n" }
            try? log.write(toFile: "/tmp/notchnerd-virtual-probe.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = display }   // keep alive, then release
        }
    }
}
#endif
