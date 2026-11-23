//
//  DisplayManager.swift
//  NotchNerd
//
//  The Displays tab's engine (a BetterDisplay replacement): every online display with its modes,
//  brightness, image adjustments, color profile and arrangement.
//
//  - Brightness is "combined" like BetterDisplay's: the top 75 % of the slider is hardware brightness
//    (BrightnessManager for the built-in panel, DDC for externals), the bottom 25 % dims further in
//    software through the gamma table. Monitors without DDC get the whole range in software.
//  - Image adjustments (warmth, gamma) share that gamma table, so one `applyGamma` owns it.
//  - Per-display settings (adjustments, protected mode) are saved by display UUID, so they survive
//    reconnects; gamma resets when NotchNerd quits and is re-applied on launch.
//  - Configuration protection: if macOS changes a protected display's mode, it is put back.
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation

struct DisplayMode: Identifiable, Hashable {
    let mode: CGDisplayMode
    var id: String { "\(width)x\(height)@\(Int(refresh.rounded()))-\(hiDPI)" }
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

struct DisplayAdjustments: Equatable {
    var dim: Double = 1       // 0.2...1, software dimming (1 = off)
    var warmth: Double = 0    // -1 (cool) ... 1 (warm)
    var gamma: Double = 1     // 0.6...1.6

    var isDefault: Bool { dim >= 0.999 && abs(warmth) < 0.01 && abs(gamma - 1) < 0.01 }

    init() {}
    init(_ dict: [String: Double]) {
        dim = dict["dim"] ?? 1; warmth = dict["warmth"] ?? 0; gamma = dict["gamma"] ?? 1
    }
    var dict: [String: Double] { ["dim": dim, "warmth": warmth, "gamma": gamma] }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var uuid: String
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
    var adjustments: DisplayAdjustments
    var isProtected: Bool
    var profileName: String?
    var hasNotch: Bool
    /// The virtual HiDPI display this monitor mirrors onto (VirtualHiDPI.swift), if on.
    var virtualID: CGDirectDisplayID?
    /// The monitor itself offers HiDPI modes (no virtual display needed).
    var nativeHiDPI: Bool

    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.isMain == b.isMain && a.mirrorOf == b.mirrorOf
            && a.current == b.current && a.brightness == b.brightness && a.contrast == b.contrast
            && a.volume == b.volume && a.hasDDC == b.hasDDC && a.adjustments == b.adjustments
            && a.isProtected == b.isProtected && a.profileName == b.profileName && a.modes.count == b.modes.count
            && a.virtualID == b.virtualID
    }

    /// Modes for the resolution slider: HiDPI sizes at the current refresh rate, one per width,
    /// smallest first; all sizes when the display has no HiDPI modes.
    var sliderModes: [DisplayMode] {
        let refresh = current?.refresh ?? 0
        let wantHiDPI = modes.contains(where: \.hiDPI)
        let candidates = modes.filter { $0.hiDPI == wantHiDPI && abs($0.refresh - refresh) < 1 }
        // One per width: the current mode at that width, else the tallest (the full-screen one, not
        // the notch-hiding 16:10 cut).
        let byWidth = Dictionary(grouping: candidates, by: \.width).compactMap { _, group in
            group.first { $0 == current } ?? group.max { $0.height < $1.height }
        }
        return byWidth.sorted { $0.width < $1.width }
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var displays: [DisplayInfo] = []
    @Published var message: String?

    private var ddc: [CGDirectDisplayID: DDCChannel] = [:]
    private let queue = DispatchQueue(label: "notchnerd.display.ddc", qos: .userInitiated)
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var started = false
    private var syncCancellable: AnyCancellable?
    private var syncTimer: Timer?
    private var restoring = false

    /// Where the combined slider switches from software dimming to hardware brightness.
    static let dimSplit = 0.25

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayManager.shared.displaysChanged() }
        }, nil)
        reload()
        // Bring back virtual HiDPI for monitors that had it on.
        for d in displays where !d.isBuiltIn && Defaults[.displayVirtualHiDPI].contains(d.uuid) {
            VirtualHiDPI.shared.enable(physical: d.id, uuid: d.uuid, name: d.name)
        }
        reapplyAllGamma()
        // Externals follow the built-in panel when brightness sync is on.
        syncCancellable = BrightnessManager.shared.$rawBrightness
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                // The brightness keys went up from the bottom: drop the software dimming so the
                // panel and the combined slider agree again.
                if value > 0.02, let b = self.displays.first(where: \.isBuiltIn), b.adjustments.dim < 0.999 {
                    self.setDim(1, for: b.id)
                }
                self.followBuiltIn(Double(value))
            }
        // With sync on and an external connected, watch the built-in panel even while the tab is
        // closed (macOS handles the keys itself unless NotchNerd's HUD replacement is on).
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let m = DisplayManager.shared
                if Defaults[.displayBrightnessSync], m.displays.contains(where: { !$0.isBuiltIn }) {
                    BrightnessManager.shared.refresh()
                }
            }
        }
    }

    private func displaysChanged() {
        reload()
        reapplyAllGamma()
        enforceProtection()
    }

    // MARK: Reading

    func reload() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let online = Set(ids)
        // Virtual HiDPI displays are folded into the monitor they serve.
        ids = ids.filter { !VirtualHiDPI.isVirtual($0) }

        let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        if Set(ddc.keys) != Set(externals) { ddc = DDCChannel.channels(for: externals) }
        let saved = Defaults[.displayAdjustments]
        let protected = Defaults[.displayProtectedModes]

        displays = ids.map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let mirror = CGDisplayMirrorsDisplay(id)
            let uuid = Self.uuid(for: id)
            let previous = displays.first { $0.id == id }
            let vid = VirtualHiDPI.shared.virtualID(forPhysical: uuid).flatMap { online.contains($0) ? $0 : nil }
            let ownModes = Self.modes(for: id)
            return DisplayInfo(
                id: id,
                uuid: uuid,
                name: Self.name(for: id),
                isBuiltIn: builtIn,
                isMain: CGDisplayIsMain(id) != 0,
                mirrorOf: mirror == kCGNullDirectDisplay || mirror == vid ? nil : mirror,
                current: CGDisplayCopyDisplayMode(vid ?? id).map(DisplayMode.init),
                modes: vid.map(Self.modes(for:)) ?? ownModes,
                brightness: builtIn ? Double(BrightnessManager.shared.rawBrightness) : previous?.brightness,
                contrast: previous?.contrast,
                volume: previous?.volume,
                hasDDC: !builtIn && (previous?.hasDDC ?? (ddc[id] != nil)),
                adjustments: saved[uuid].map(DisplayAdjustments.init) ?? DisplayAdjustments(),
                isProtected: protected[uuid] != nil,
                profileName: ColorProfiles.currentName(for: id),
                hasNotch: builtIn && Self.screen(for: id).map { $0.safeAreaInsets.top > 0 } ?? false,
                virtualID: vid,
                nativeHiDPI: ownModes.contains(where: \.hiDPI))
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

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func name(for id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
    }

    static func uuid(for id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "id-\(id)" }
        return (CFUUIDCreateString(nil, u) as String?) ?? "id-\(id)"
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

    /// The display under the mouse pointer.
    func displayUnderPointer() -> DisplayInfo? {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return displays.first { $0.id == n.uint32Value }
    }

    // MARK: Combined brightness

    /// 0...1 position of the combined slider for a display.
    func combined(_ d: DisplayInfo) -> Double {
        let dim = d.adjustments.dim
        let hardware = d.isBuiltIn ? Double(BrightnessManager.shared.rawBrightness) : d.brightness
        guard d.isBuiltIn || d.hasDDC, let hw = hardware else {
            return (dim - 0.2) / 0.8   // software only: the whole range is dimming
        }
        if dim < 0.999 { return (dim - 0.2) / 0.8 * Self.dimSplit }
        return Self.dimSplit + (1 - Self.dimSplit) * hw
    }

    func setCombined(_ value: Double, for id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }) else { return }
        let v = min(1, max(0, value))
        if !(d.isBuiltIn || d.hasDDC) {
            setDim(0.2 + 0.8 * v, for: id)
            return
        }
        if v < Self.dimSplit {
            setHardware(0, for: id)
            setDim(0.2 + 0.8 * (v / Self.dimSplit), for: id)
        } else {
            if d.adjustments.dim < 0.999 { setDim(1, for: id) }
            setHardware((v - Self.dimSplit) / (1 - Self.dimSplit), for: id)
        }
    }

    /// Brightness keys on an external display: step the combined value. Returns the new value, or
    /// nil when the display isn't an external one we control.
    func stepExternal(_ id: CGDirectDisplayID, by delta: Double) -> Double? {
        guard let d = displays.first(where: { $0.id == id }), !d.isBuiltIn else { return nil }
        let next = min(1, max(0, combined(d) + delta))
        setCombined(next, for: id)
        return next
    }

    private func followBuiltIn(_ value: Double) {
        guard Defaults[.displayBrightnessSync] else { return }
        for d in displays where !d.isBuiltIn {
            setCombined(Self.dimSplit + (1 - Self.dimSplit) * value, for: d.id)
        }
    }

    private func setHardware(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].brightness = value
        if displays[i].isBuiltIn {
            BrightnessManager.shared.setAbsolute(value: Float(value))
        } else if let channel = ddc[id] {
            debouncedWrite(channel, .brightness, value, key: "b\(id)")
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

    // MARK: Image adjustments (gamma table)

    func setDim(_ factor: Double, for id: CGDirectDisplayID) {
        updateAdjustments(id) { $0.dim = min(1, max(0.2, factor)) }
    }

    func setWarmth(_ value: Double, for id: CGDirectDisplayID) {
        updateAdjustments(id) { $0.warmth = min(1, max(-1, value)) }
    }

    func setGamma(_ value: Double, for id: CGDirectDisplayID) {
        updateAdjustments(id) { $0.gamma = min(1.6, max(0.6, value)) }
    }

    func resetAdjustments(for id: CGDirectDisplayID) {
        updateAdjustments(id) { $0 = DisplayAdjustments() }
    }

    private func updateAdjustments(_ id: CGDirectDisplayID, _ change: (inout DisplayAdjustments) -> Void) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        change(&displays[i].adjustments)
        var saved = Defaults[.displayAdjustments]
        saved[displays[i].uuid] = displays[i].adjustments.isDefault ? nil : displays[i].adjustments.dict
        Defaults[.displayAdjustments] = saved
        if displays[i].adjustments.isDefault { reapplyAllGamma() } else { applyGamma(displays[i]) }
    }

    private func applyGamma(_ d: DisplayInfo) {
        let a = d.adjustments
        let w = a.warmth
        // Warm lowers blue (and a little green); cool lowers red.
        let r = w < 0 ? 1 + 0.3 * w : 1
        let g = 1 - 0.08 * abs(w)
        let b = w > 0 ? 1 - 0.35 * w : 1
        let gm = Float(a.gamma)
        CGSetDisplayTransferByFormula(d.id, 0, Float(a.dim * r), gm, 0, Float(a.dim * g), gm, 0, Float(a.dim * b), gm)
    }

    /// Restores every display's ColorSync curves, then re-applies the ones with adjustments.
    private func reapplyAllGamma() {
        CGDisplayRestoreColorSyncSettings()
        for d in displays where !d.adjustments.isDefault { applyGamma(d) }
    }

    // MARK: Color profiles

    func setProfile(_ profile: ColorProfiles.Profile?, for id: CGDirectDisplayID) {
        ColorProfiles.set(profile?.url, for: id)
        // ColorSync swaps the curves; our adjustments sit on top, so put them back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.reload()
            self.reapplyAllGamma()
        }
    }

    // MARK: Modes and arrangement

    func setMode(_ mode: DisplayMode, for id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, (displays.first { $0.id == id }?.virtualID ?? id), mode.mode, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        message = err == .success ? nil : "Couldn't switch to \(mode.label)"
        // A protected display keeps whatever the user picks here.
        if let d = displays.first(where: { $0.id == id }), d.isProtected {
            Defaults[.displayProtectedModes][d.uuid] = mode.id
        }
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
        let target = displays.first { $0.id == id }?.virtualID ?? id
        let origin = CGDisplayBounds(target).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for d in displays where d.mirrorOf == nil {
            let did = d.virtualID ?? d.id
            let b = CGDisplayBounds(did).origin
            CGConfigureDisplayOrigin(config, did, Int32(b.x - origin.x), Int32(b.y - origin.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
        reload()
    }

    // MARK: Hide the notch

    /// The mode that hides (or shows again) the notch on the built-in display: same width, refresh
    /// and HiDPI, height cut to 16:10 so the menu bar sits below the camera housing.
    func notchToggleMode(_ d: DisplayInfo) -> (mode: DisplayMode, hides: Bool)? {
        guard d.hasNotch, let c = d.current else { return nil }
        let peers = d.modes.filter { $0.width == c.width && $0.hiDPI == c.hiDPI && abs($0.refresh - c.refresh) < 1 }
        let notchless = Int(Double(c.width) / 1.6)
        if c.height > notchless + 2 {
            guard let hide = peers.filter({ $0.height < c.height }).min(by: { abs($0.height - notchless) < abs($1.height - notchless) }) else { return nil }
            return (hide, true)
        }
        guard let show = peers.filter({ $0.height > c.height }).max(by: { $0.height < $1.height }) else { return nil }
        return (show, false)
    }

    // MARK: Configuration protection

    func setProtected(_ on: Bool, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].isProtected = on
        Defaults[.displayProtectedModes][displays[i].uuid] = on ? displays[i].current?.id : nil
    }

    /// Puts a protected display's mode back if something else changed it.
    private func enforceProtection() {
        guard !restoring else { return }
        let protected = Defaults[.displayProtectedModes]
        for d in displays {
            guard let want = protected[d.uuid], d.current?.id != want,
                  let mode = d.modes.first(where: { $0.id == want }) else { continue }
            restoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.setMode(mode, for: d.id)
                self.message = "Kept \(d.name) at \(mode.width) × \(mode.height)"
                self.restoring = false
            }
        }
    }
}

// MARK: - Virtual HiDPI

@MainActor
extension DisplayManager {
    func setVirtualHiDPI(_ on: Bool, for id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }), !d.isBuiltIn else { return }
        var enabled = Defaults[.displayVirtualHiDPI]
        if on {
            guard VirtualHiDPI.shared.enable(physical: d.id, uuid: d.uuid, name: d.name) != nil else {
                message = "macOS didn't create the HiDPI display for \(d.name)"
                return
            }
            enabled.insert(d.uuid)
            message = "Turning on HiDPI for \(d.name)…"
        } else {
            VirtualHiDPI.shared.disable(physical: d.id, uuid: d.uuid)
            enabled.remove(d.uuid)
            message = nil
        }
        Defaults[.displayVirtualHiDPI] = enabled
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reload() }
    }
}
