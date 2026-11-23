//
//  DisplayTabView.swift
//  NotchNerd
//
//  The Displays tab: one card per screen with a combined brightness slider (hardware, then software
//  dimming below it), a resolution slider over the HiDPI sizes, and an Adjust panel (warmth, gamma).
//  The ⋯ menu holds hide-the-notch, keep-these-settings, color profile, mirror and make-main.
//  External monitors that answer DDC also get contrast, volume and input. Engine: DisplayManager.swift.
//

import Defaults
import SwiftUI

let displayNotchSize: CGSize = .init(width: openNotchSize.width, height: 300)

struct DisplayTabView: View {
    @ObservedObject private var manager = DisplayManager.shared
    @ObservedObject private var builtInBrightness = BrightnessManager.shared
    @State private var adjusting: Set<CGDirectDisplayID> = []
    /// Slider position while dragging, so the label follows before the mode is applied on release.
    @State private var draggingResolution: [CGDirectDisplayID: Double] = [:]
    @State private var profiles: [ColorProfiles.Profile] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                presetsBar
                ForEach(manager.displays) { display in
                    card(display)
                }
                if let message = manager.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .onAppear {
            manager.reload()
            if profiles.isEmpty { profiles = ColorProfiles.all() }
        }
        // macOS handles the brightness keys itself unless NotchNerd's HUD replacement is on, so the
        // slider wouldn't hear about them: re-read the built-in panel's brightness while this tab shows.
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            if manager.displays.contains(where: \.isBuiltIn) { BrightnessManager.shared.refresh() }
        }
    }

    private func card(_ d: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(d.name).font(.callout.weight(.medium)).lineLimit(1)
                if d.isMain { badge("Main") }
                if d.mirrorOf != nil { badge("Mirroring") }
                if d.isProtected { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Settings are kept") }
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        if adjusting.contains(d.id) { adjusting.remove(d.id) } else { adjusting.insert(d.id) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(adjusting.contains(d.id) || !d.adjustments.isDefault ? .white : .gray)
                }
                .buttonStyle(.plain)
                .help("Image adjustments")
                moreMenu(d)
            }

            // Combined brightness: hardware above the split, software dimming below it.
            sliderRow(symbol: "sun.max", value: Binding(
                get: { d.isBuiltIn ? manager.combinedBuiltIn(builtInBrightness.rawBrightness, d) : manager.combined(d) },
                set: { manager.setCombined($0, for: d.id) }))
                .help(d.isBuiltIn || d.hasDDC ? "Brightness (the lowest quarter dims in software)" : "Brightness (software; this monitor didn't answer DDC)")

            resolutionRow(d)

            if !d.isBuiltIn && d.hasDDC {
                HStack(spacing: 14) {
                    if d.contrast != nil {
                        sliderRow(symbol: "circle.lefthalf.filled", value: Binding(
                            get: { d.contrast ?? 0.5 }, set: { manager.setContrast($0, for: d.id) }))
                    }
                    if d.volume != nil {
                        sliderRow(symbol: "speaker.wave.2", value: Binding(
                            get: { d.volume ?? 0.5 }, set: { manager.setVolume($0, for: d.id) }))
                    }
                    inputMenu(d)
                }
            }

            if adjusting.contains(d.id) {
                HStack(spacing: 14) {
                    sliderRow(symbol: "thermometer.medium", value: Binding(
                        get: { d.adjustments.warmth }, set: { manager.setWarmth($0, for: d.id) }), range: -1...1)
                        .help("Warmth: left is cooler, right is warmer")
                    sliderRow(symbol: "circle.bottomrighthalf.pattern.checkered", value: Binding(
                        get: { 2.2 - d.adjustments.gamma }, set: { manager.setGamma(2.2 - $0, for: d.id) }), range: 0.6...1.6)
                        .help("Gamma: right lifts shadows")
                    Button("Reset") { manager.resetAdjustments(for: d.id) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(d.adjustments.isDefault ? .gray : .white)
                        .disabled(d.adjustments.isDefault)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    // MARK: Presets

    @Default(.displayPresets) private var presets

    private var presetsBar: some View {
        HStack(spacing: 8) {
            Menu {
                if presets.isEmpty { Text("No presets yet") }
                ForEach(presets) { preset in
                    Button(preset.name) { manager.apply(preset) }
                }
                Divider()
                Button("Save current setup") { manager.saveCurrentPreset() }
                Button("Rename or delete…") { SettingsWindowController.shared.showWindow() }
            } label: {
                Label("Presets", systemImage: "rectangle.stack")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: Resolution

    @ViewBuilder
    private func resolutionRow(_ d: DisplayInfo) -> some View {
        let modes = d.sliderModes
        if modes.count > 1 {
            let currentIndex = Double(modes.firstIndex { $0.width == d.current?.width } ?? 0)
            let shown = Int((draggingResolution[d.id] ?? currentIndex).rounded())
            let label = modes[min(max(shown, 0), modes.count - 1)]
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                Slider(value: Binding(
                    get: { draggingResolution[d.id] ?? currentIndex },
                    set: { draggingResolution[d.id] = $0 }),
                       in: 0...Double(modes.count - 1), step: 1) { editing in
                    guard !editing, let v = draggingResolution[d.id] else { return }
                    let target = modes[Int(v.rounded())]
                    draggingResolution[d.id] = nil
                    if target != d.current { manager.setMode(target, for: d.id) }
                }
                .controlSize(.small)
                .tint(.white)
                resolutionMenu(d, title: "\(label.width)×\(label.height)")
            }
        } else {
            HStack {
                Spacer()
                resolutionMenu(d, title: d.current.map { "\($0.width)×\($0.height)" } ?? "Resolution")
            }
        }
    }

    private func resolutionMenu(_ d: DisplayInfo, title: String) -> some View {
        Menu {
            let hidpi = d.modes.filter(\.hiDPI)
            let lowres = d.modes.filter { !$0.hiDPI }
            if !hidpi.isEmpty {
                Section("HiDPI (sharp)") { modeButtons(hidpi, d) }
            }
            Section(hidpi.isEmpty ? "Resolutions" : "Native pixels and low resolution") { modeButtons(lowres, d) }
        } label: {
            Text(title).font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("All resolutions and refresh rates")
    }

    @ViewBuilder
    private func modeButtons(_ modes: [DisplayMode], _ d: DisplayInfo) -> some View {
        ForEach(modes) { mode in
            Button {
                manager.setMode(mode, for: d.id)
            } label: {
                if mode == d.current { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
            }
        }
    }

    // MARK: Menus

    private func moreMenu(_ d: DisplayInfo) -> some View {
        Menu {
            if let notch = manager.notchToggleMode(d) {
                Button(notch.hides ? "Hide the notch" : "Show the notch") { manager.setMode(notch.mode, for: d.id) }
            }
            if !d.isBuiltIn && !d.nativeHiDPI || d.virtualID != nil {
                Toggle("Sharper text (HiDPI)", isOn: Binding(
                    get: { d.virtualID != nil }, set: { manager.setVirtualHiDPI($0, for: d.id) }))
            }
            Toggle("Keep these settings", isOn: Binding(
                get: { d.isProtected }, set: { manager.setProtected($0, for: d.id) }))
            Menu("Color profile") {
                Button("Factory default") { manager.setProfile(nil, for: d.id) }
                Divider()
                ForEach(profiles) { profile in
                    Button {
                        manager.setProfile(profile, for: d.id)
                    } label: {
                        if profile.name == d.profileName { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                    }
                }
            }
            Divider()
            if !d.isMain { Button("Make main display") { manager.makeMain(d.id) } }
            if manager.displays.count > 1 {
                Button(d.mirrorOf == nil ? "Mirror main display" : "Stop mirroring") { manager.toggleMirror(d.id) }
            }
            Button("Displays settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func inputMenu(_ d: DisplayInfo) -> some View {
        Menu {
            ForEach(DisplayManager.inputs, id: \.1) { input in
                Button(input.0) { manager.setInput(input.1, for: d.id) }
            }
        } label: {
            Image(systemName: "rectangle.connected.to.line.below")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch input")
    }

    // MARK: Pieces

    private func sliderRow(symbol: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(.white)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
}

extension DisplayManager {
    /// The built-in display's combined value, read from BrightnessManager's published brightness so
    /// the slider follows the keyboard keys live.
    func combinedBuiltIn(_ raw: Float, _ d: DisplayInfo) -> Double {
        if d.adjustments.dim < 0.999 { return (d.adjustments.dim - 0.2) / 0.8 * Self.dimSplit }
        return Self.dimSplit + (1 - Self.dimSplit) * Double(raw)
    }
}

// MARK: - Settings → Displays

struct DisplaySettings: View {
    @Default(.displayPresets) var presets

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .displayTabEnabled) { Text("Show the Displays tab in the notch") }
                Defaults.Toggle(key: .displayBrightnessSync) { Text("External displays follow the built-in brightness") }
                Defaults.Toggle(key: .displayKeysControlExternal) { Text("Brightness keys adjust the display under the pointer") }
            } header: {
                Text("Displays")
            } footer: {
                Text("Brightness, resolution (including HiDPI and hidden modes), warmth and gamma, color profiles, mirroring and the main display for every screen. External monitors that support DDC also get contrast, volume and input switching; ones that don't are dimmed in software. \"Keep these settings\" in a display's ⋯ menu puts its resolution back if macOS changes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if presets.isEmpty {
                    Text("Save one from the Displays tab: Presets, then Save current setup.").foregroundStyle(.secondary)
                }
                ForEach($presets) { $preset in
                    HStack {
                        TextField("Name", text: $preset.name)
                        Button(role: .destructive) { presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Presets")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Settings → Calendar → Meeting countdown

struct MeetingChipSettings: View {
    @Default(.meetingChipLeadMinutes) var lead
    @Default(.meetingNotesApp) var notesApp

    var body: some View {
        Section {
            Defaults.Toggle(key: .meetingChipEnabled) { Text("Show the next meeting in the closed notch") }
            Stepper("Start counting down \(lead) min before", value: $lead, in: 5...180, step: 5)
            Defaults.Toggle(key: .meetingOpenNotesApp) { Text("Open my notes app when a meeting starts") }
            TextField("Notes app", text: $notesApp, prompt: Text("Granola"))
        } header: {
            Text("Meeting countdown")
        } footer: {
            Text("Shows \"Title · in 20m\" before a meeting and \"Title · 12m left\" during it, so you can hide your meeting app's menu-bar item. Only events with other people or a call link count.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
