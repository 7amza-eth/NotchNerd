//
//  DisplayManager.swift
//  NotchNerd
//
//  The Displays tab's engine (a BetterDisplay replacement): every online display with its modes,
//  brightness, and arrangement. Resolutions include the hidden low-res duplicates and HiDPI modes
//  (kCGDisplayShowDuplicateLowResolutionModes). Brightness goes through BrightnessManager for the
//  built-in panel, DDC for external monitors, and a gamma-table dimmer as a fallback or below zero.
//

import AppKit
import CoreGraphics
import Defaults
import Foundation

struct DisplayMode: Identifiable, Hashable {
    let mode: CGDisplayMode
    var id: String { "\(width)x\(height)@\(Int(refresh))-\(hiDPI)" }
    var width: Int { mode.width }
    var height: Int { mode.height }
    var pixelWidth: Int { mode.pixelWidth }
    var refresh: Double { mode.refreshRate }
    var hiDPI: Bool { mode.pixelWidth > mode.width }

    var label: String {
        var s = "\(width) × \(height)"
        if hiDPI { s += "  HiDPI" }
        if refresh > 0 { s += "  \(Int(refresh.rounded())) Hz" }
        return s
    }

    static func == (a: DisplayMode, b: DisplayMode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var isMain: Bool
    var mirrorOf: CGDirectDisplayID?
    var current: DisplayMode?
    var modes: [DisplayMode]
    /// 0...1 hardware brightness (built-in, or DDC). nil = unknown/unsupported.
    var brightness: Double?
    var contrast: Double?
    var volume: Double?
    var hasDDC: Bool
    /// 0.2...1 software dim factor (1 = off).
    var dim: Double

    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.isMain == b.isMain && a.mirrorOf == b.mirrorOf
            && a.current == b.current && a.brightness == b.brightness && a.contrast == b.contrast
            && a.volume == b.volume && a.hasDDC == b.hasDDC && a.dim == b.dim && a.modes.count == b.modes.count
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var displays: [DisplayInfo] = []
    @Published var message: String?

    private var ddc: [CGDirectDisplayID: DDCChannel] = [:]
    private var dims: [CGDirectDisplayID: Double] = [:]
    private let queue = DispatchQueue(label: "notchnerd.display.ddc", qos: .userInitiated)
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayManager.shared.reload() }
        }, nil)
        reload()
    }

    // MARK: Reading

    func reload() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        if Set(ddc.keys) != Set(externals) { ddc = DDCChannel.channels(for: externals) }

        displays = ids.map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let mirror = CGDisplayMirrorsDisplay(id)
            var info = DisplayInfo(
                id: id,
                name: Self.name(for: id),
                isBuiltIn: builtIn,
                isMain: CGDisplayIsMain(id) != 0,
                mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
                current: CGDisplayCopyDisplayMode(id).map(DisplayMode.init),
                modes: Self.modes(for: id),
                brightness: builtIn ? Double(BrightnessManager.shared.rawBrightness) : displays.first { $0.id == id }?.brightness,
                contrast: displays.first { $0.id == id }?.contrast,
                volume: displays.first { $0.id == id }?.volume,
                hasDDC: ddc[id] != nil,
                dim: dims[id] ?? 1)
            if builtIn { info.hasDDC = false }
            return info
        }
        .sorted { ($0.isBuiltIn ? 0 : 1, $0.id) < ($1.isBuiltIn ? 0 : 1, $1.id) }

        if displays.contains(where: \.isBuiltIn) { BrightnessManager.shared.refresh() }
        readDDCValues()
    }

    private func readDDCValues() {
        for (id, channel) in ddc {
            queue.async {
                let b = channel.read(.brightness)
                let c = channel.read(.contrast)
                let v = channel.read(.volume)
                DispatchQueue.main.async {
                    guard let i = self.displays.firstIndex(where: { $0.id == id }) else { return }
                    self.displays[i].hasDDC = b != nil
                    self.displays[i].brightness = b.map { Double($0.current) / Double($0.max) }
                    self.displays[i].contrast = c.map { Double($0.current) / Double($0.max) }
                    self.displays[i].volume = v.map { Double($0.current) / Double($0.max) }
                }
            }
        }
    }

    static func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    static func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        var seen = Set<String>()
        return all.filter { $0.isUsableForDesktopGUI() }
            .map(DisplayMode.init)
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.width, $0.hiDPI ? 1 : 0, $0.refresh) > ($1.width, $1.hiDPI ? 1 : 0, $1.refresh) }
    }

    // MARK: Brightness, contrast, volume

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].brightness = value
        if displays[i].isBuiltIn {
            BrightnessManager.shared.setAbsolute(value: Float(value))
        } else if let channel = ddc[id], displays[i].hasDDC {
            debouncedWrite(channel, .brightness, value, key: "b\(id)")
        } else {
            // No DDC (adapter or monitor blocks it): fall back to software dimming.
            setDim(max(0.2, value), for: id)
        }
    }

    func setContrast(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }), let channel = ddc[id] else { return }
        displays[i].contrast = value
        debouncedWrite(channel, .contrast, value, key: "c\(id)")
    }

    func setVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }), let channel = ddc[id] else { return }
        displays[i].volume = value
        debouncedWrite(channel, .volume, value, key: "v\(id)")
    }

    /// Common MCCS input codes. Monitors vary; these cover most.
    static let inputs: [(String, Int)] = [("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10), ("HDMI 1", 0x11),
                                          ("HDMI 2", 0x12), ("USB-C", 0x1B), ("Thunderbolt", 0x19)]

    func setInput(_ code: Int, for id: CGDirectDisplayID) {
        guard let channel = ddc[id] else { return }
        queue.async { channel.write(.input, code) }
    }

    /// Writes the latest value 60 ms after the slider stops, so a drag doesn't flood the I2C bus.
    private func debouncedWrite(_ channel: DDCChannel, _ code: VCP, _ value: Double, key: String) {
        pendingWrites[key]?.cancel()
        let item = DispatchWorkItem {
            let maxValue = channel.read(code)?.max ?? 100
            channel.write(code, Int((value * Double(maxValue)).rounded()))
        }
        pendingWrites[key] = item
        queue.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    /// Software dimming through the gamma table. 1 = normal. Resets when NotchNerd quits.
    func setDim(_ factor: Double, for id: CGDirectDisplayID) {
        let f = Float(min(1, max(0.2, factor)))
        dims[id] = Double(f)
        if let i = displays.firstIndex(where: { $0.id == id }) { displays[i].dim = Double(f) }
        if f >= 0.999 {
            CGDisplayRestoreColorSyncSettings()
            // Restoring resets every display; re-apply the others.
            for (other, d) in dims where other != id && d < 0.999 {
                CGSetDisplayTransferByFormula(other, 0, Float(d), 1, 0, Float(d), 1, 0, Float(d), 1)
            }
        } else {
            CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
        }
    }

    // MARK: Modes and arrangement

    func setMode(_ mode: DisplayMode, for id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, mode.mode, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        message = err == .success ? nil : "Couldn't switch to \(mode.label)"
        reload()
    }

    /// Mirror `id` onto the main display, or stop mirroring.
    func toggleMirror(_ id: CGDirectDisplayID) {
        guard let info = displays.first(where: { $0.id == id }) else { return }
        let target: CGDirectDisplayID
        if info.mirrorOf != nil {
            target = kCGNullDirectDisplay
        } else {
            guard let main = displays.first(where: { $0.isMain && $0.id != id }) ?? displays.first(where: { $0.id != id }) else { return }
            target = main.id
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, id, target)
        CGCompleteDisplayConfiguration(config, .permanently)
        reload()
    }

    /// Makes `id` the main display (menu bar and Dock) by moving it to the origin.
    func makeMain(_ id: CGDirectDisplayID) {
        let origin = CGDisplayBounds(id).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for d in displays where d.mirrorOf == nil {
            let b = CGDisplayBounds(d.id).origin
            CGConfigureDisplayOrigin(config, d.id, Int32(b.x - origin.x), Int32(b.y - origin.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
        reload()
    }
}
