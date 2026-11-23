//
//  DisplayTabView.swift
//  NotchNerd
//
//  The Displays tab: one card per screen. Brightness for every display (built-in via DisplayServices,
//  external via DDC, software dimming as fallback), resolutions including HiDPI and hidden modes,
//  mirroring and "make main". External monitors that answer DDC also get contrast, volume and input.
//  Engine: DisplayManager.swift / DDC.swift.
//

import Defaults
import SwiftUI

let displayNotchSize: CGSize = .init(width: openNotchSize.width, height: 300)

struct DisplayTabView: View {
    @ObservedObject private var manager = DisplayManager.shared
    @ObservedObject private var builtInBrightness = BrightnessManager.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(manager.displays) { display in
                    card(display)
                }
                if let message = manager.message {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .onAppear { manager.reload() }
    }

    private func card(_ d: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(d.name).font(.callout.weight(.medium)).lineLimit(1)
                if d.isMain { badge("Main") }
                if d.mirrorOf != nil { badge("Mirroring") }
                Spacer()
                resolutionMenu(d)
                arrangementMenu(d)
            }

            sliderRow(symbol: "sun.max", value: brightnessBinding(d))
                .help(d.isBuiltIn ? "Brightness" : d.hasDDC ? "Brightness (DDC)" : "Brightness (software dimming; this monitor didn't answer DDC)")

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

            if d.isBuiltIn || d.hasDDC {
                // Dim below the panel's minimum (great at night).
                sliderRow(symbol: "moon", value: Binding(
                    get: { d.dim }, set: { manager.setDim($0, for: d.id) }), range: 0.2...1)
                    .help("Dim below the lowest brightness (software)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func brightnessBinding(_ d: DisplayInfo) -> Binding<Double> {
        if d.isBuiltIn {
            return Binding(get: { Double(builtInBrightness.rawBrightness) },
                           set: { manager.setBrightness($0, for: d.id) })
        }
        if d.hasDDC {
            return Binding(get: { d.brightness ?? 0.5 }, set: { manager.setBrightness($0, for: d.id) })
        }
        return Binding(get: { d.dim }, set: { manager.setDim($0, for: d.id) })
    }

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

    private func resolutionMenu(_ d: DisplayInfo) -> some View {
        Menu {
            let hidpi = d.modes.filter(\.hiDPI)
            let lowres = d.modes.filter { !$0.hiDPI }
            if !hidpi.isEmpty {
                Section("HiDPI (sharp)") { modeButtons(hidpi, d) }
            }
            Section(hidpi.isEmpty ? "Resolutions" : "Native pixels and low resolution") { modeButtons(lowres, d) }
        } label: {
            Text(d.current.map { "\($0.width)×\($0.height)" } ?? "Resolution")
                .font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

    private func arrangementMenu(_ d: DisplayInfo) -> some View {
        Menu {
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
}

// MARK: - Settings → Displays

struct DisplaySettings: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .displayTabEnabled) { Text("Show the Displays tab in the notch") }
            } header: {
                Text("Displays")
            } footer: {
                Text("Brightness, resolution (including HiDPI and hidden modes), mirroring and the main display for every screen. External monitors that support DDC also get contrast, volume and input switching; ones that don't are dimmed in software.")
                    .font(.caption).foregroundStyle(.secondary)
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
