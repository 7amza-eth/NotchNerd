//
//  DisplayPresets.swift
//  NotchNerd
//
//  Named snapshots of the display setup ("Desk", "Laptop only"): per display (by UUID) the mode,
//  combined brightness, image adjustments and whether it's main, plus virtual HiDPI on/off. Saving
//  happens from the Displays tab (auto-named after the screens); renaming and deleting in
//  Settings → Displays, where the window can take typing.
//

import Defaults
import Foundation

struct DisplayPreset: Codable, Hashable, Identifiable, Defaults.Serializable {
    struct Entry: Codable, Hashable {
        var modeID: String?
        var brightness: Double?
        var dim: Double
        var warmth: Double
        var gamma: Double
        var isMain: Bool
        var virtualHiDPI: Bool?
    }

    var id = UUID()
    var name: String
    var entries: [String: Entry]   // display UUID → settings
}

@MainActor
extension DisplayManager {
    /// Saves the current setup under a name made from the screens ("Laptop only", "DELL UP3218K + Laptop").
    @discardableResult
    func saveCurrentPreset() -> DisplayPreset {
        var entries: [String: DisplayPreset.Entry] = [:]
        for d in displays {
            entries[d.uuid] = DisplayPreset.Entry(
                modeID: d.current?.id,
                brightness: d.isBuiltIn || d.hasDDC ? combinedValue(d) : nil,
                dim: d.adjustments.dim, warmth: d.adjustments.warmth, gamma: d.adjustments.gamma,
                isMain: d.isMain,
                virtualHiDPI: d.isBuiltIn ? nil : d.virtualID != nil)
        }
        let externals = displays.filter { !$0.isBuiltIn }.map(\.name)
        var base = externals.isEmpty ? "Laptop only" : externals.joined(separator: " + ")
        if !externals.isEmpty && displays.contains(where: \.isBuiltIn) { base += " + Laptop" }
        var name = base
        var n = 2
        let existing = Set(Defaults[.displayPresets].map(\.name))
        while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
        let preset = DisplayPreset(name: name, entries: entries)
        Defaults[.displayPresets].append(preset)
        message = "Saved \u{201C}\(name)\u{201D}"
        return preset
    }

    /// Applies what it can: displays in the preset that aren't connected are skipped.
    func apply(_ preset: DisplayPreset) {
        var applied = 0
        for d in displays {
            guard let e = preset.entries[d.uuid] else { continue }
            applied += 1
            if let wantVirtual = e.virtualHiDPI, wantVirtual != (d.virtualID != nil) {
                setVirtualHiDPI(wantVirtual, for: d.id)
            }
            setWarmth(e.warmth, for: d.id)
            setGamma(e.gamma, for: d.id)
            if let b = e.brightness { setCombined(b, for: d.id) } else { setDim(e.dim, for: d.id) }
        }
        // Modes after HiDPI changes settle, then the main display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.reload()
            for d in self.displays {
                guard let e = preset.entries[d.uuid] else { continue }
                if let want = e.modeID, d.current?.id != want, let mode = d.modes.first(where: { $0.id == want }) {
                    self.setMode(mode, for: d.id)
                }
            }
            if let main = self.displays.first(where: { preset.entries[$0.uuid]?.isMain == true }), !main.isMain {
                self.makeMain(main.id)
            }
            self.message = applied == 0 ? "None of \u{201C}\(preset.name)\u{201D}'s screens are connected" : "Applied \u{201C}\(preset.name)\u{201D}"
        }
    }

    func deletePreset(_ preset: DisplayPreset) {
        Defaults[.displayPresets].removeAll { $0.id == preset.id }
    }

    func renamePreset(_ preset: DisplayPreset, to name: String) {
        guard let i = Defaults[.displayPresets].firstIndex(where: { $0.id == preset.id }) else { return }
        Defaults[.displayPresets][i].name = name
    }

    private func combinedValue(_ d: DisplayInfo) -> Double {
        d.isBuiltIn ? combinedBuiltIn(BrightnessManager.shared.rawBrightness, d) : combined(d)
    }
}
