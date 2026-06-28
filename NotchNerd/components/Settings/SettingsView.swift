//
//  SettingsView.swift
//  NotchNerd
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AVFoundation
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI
import SwiftUIIntrospect

// MARK: - Tab model (single source of truth for the sidebar + the detail switch)

enum SettingsTab: String, CaseIterable, Identifiable {
    // General group
    case general, appearance
    // Notch features group
    case media, calendar, shelf, notepad, webcam, huds, battery, agent
    // Advanced group
    case shortcuts, advanced
    // Meta
    case about

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case general = "General"
        case features = "Notch features"
        case advanced = "Advanced"
    }

    /// The grouped tabs shown under section headers (About is pinned separately, ungrouped).
    var group: Group? {
        switch self {
        case .general, .appearance: return .general
        case .media, .calendar, .shelf, .notepad, .webcam, .huds, .battery, .agent: return .features
        case .shortcuts, .advanced: return .advanced
        case .about: return nil
        }
    }

    var label: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .media: return "Media"
        case .calendar: return "Calendar"
        case .shelf: return "Shelf"
        case .notepad: return "Notepad"
        case .webcam: return "Webcam"
        case .huds: return "HUDs"
        case .battery: return "Battery"
        case .agent: return "Agent"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "paintbrush"
        case .media: return "play.laptopcomputer"
        case .calendar: return "calendar"
        case .shelf: return "books.vertical"
        case .notepad: return "note.text"
        case .webcam: return "web.camera"
        case .huds: return "dial.medium.fill"
        case .battery: return "battery.100.bolt"
        case .agent: return "sparkles"
        case .shortcuts: return "keyboard"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsSelectedTab") private var selectedTab: String = SettingsTab.general.rawValue
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    private var currentTab: SettingsTab { SettingsTab(rawValue: selectedTab) ?? .general }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(SettingsTab.allCases.filter { $0.group == group }) { tab in
                            NavigationLink(value: tab.rawValue) {
                                Label(tab.label, systemImage: tab.symbol)
                            }
                        }
                    }
                }
                // About pinned at the bottom, ungrouped (platform convention).
                NavigationLink(value: SettingsTab.about.rawValue) {
                    Label(SettingsTab.about.label, systemImage: SettingsTab.about.symbol)
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(210)
        } detail: {
            Group {
                detailView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            // Recompute .effectiveAccent across the tree. The selected tab is @AppStorage-backed, so it
            // survives this rebuild (it no longer snaps back to General).
            accentColorUpdateTrigger = UUID()
        }
    }

    @ViewBuilder private var detailView: some View {
        switch currentTab {
        case .general: GeneralSettings()
        case .appearance: Appearance()
        case .media: Media()
        case .calendar: CalendarSettings()
        case .huds: HUD()
        case .battery: Battery()
        case .shelf: Shelf()
        case .notepad: NotepadSettings()
        case .webcam: WebcamSettings()
        case .agent: AgentSettings()
        case .shortcuts: Shortcuts()
        case .advanced: Advanced()
        case .about:
            if let controller = updaterController {
                About(updaterController: controller)
            } else {
                About(updaterController: SPUStandardUpdaterController(
                    startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
            }
        }
    }
}

struct GeneralSettings: View {
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @EnvironmentObject var vm: NotchNerdViewModel
    @ObservedObject var coordinator = NotchNerdViewCoordinator.shared

    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.enableGestures) var enableGestures
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.menubarIcon) var menubarIcon

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Show menu bar icon")
                }
                LaunchAtLogin.Toggle("Launch at login")
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(
                        name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens = NSScreen.screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return (uuid, screen.localizedName)
                    }
                }
                .disabled(showOnAllDisplays)

                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                .onChange(of: automaticallySwitchDisplay) {
                    NotificationCenter.default.post(
                        name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                }
                .disabled(showOnAllDisplays)
            } header: {
                Text("System features")
            } footer: {
                if !menubarIcon {
                    Text("With the menu-bar icon hidden, open Settings from the in-notch gear (Appearance → “Show settings icon in notch”). Hiding both also hides the Notepad menu item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(
                    selection: $notchHeightMode,
                    label: Text("Notch height on notch displays")
                ) {
                    Text("Match real notch height").tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menu bar height").tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height").tag(WindowHeightMode.custom)
                }
                .onChange(of: notchHeightMode) {
                    switch notchHeightMode {
                    case .matchRealNotchSize: notchHeight = 38
                    case .matchMenuBar: notchHeight = 44
                    case .custom: notchHeight = 38
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom height (notch displays) — \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menu bar height").tag(WindowHeightMode.matchMenuBar)
                    Text("Match real notch height").tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height").tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar: nonNotchHeight = 24
                    case .matchRealNotchSize: nonNotchHeight = 32
                    case .custom: nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom height (non-notch displays) — \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch sizing")
            }

            NotchBehaviour()

            gestureControls()

            Section {
                Button("Replay feature tour…") {
                    NotificationCenter.default.post(name: .featureTourRequested, object: nil)
                }
            } header: {
                Text("Help")
            }
        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("General")
    }

    @ViewBuilder
    func gestureControls() -> some View {
        Section {
            Defaults.Toggle(key: .enableGestures) {
                Text("Enable gestures")
            }
            if enableGestures {
                Defaults.Toggle(key: .closeGestureEnabled) {
                    Text("Close gesture")
                }
                Slider(value: $gestureSensitivity, in: 100...300, step: 100) {
                    HStack {
                        Text("Gesture sensitivity")
                        Spacer()
                        Text(
                            Defaults[.gestureSensitivity] == 100
                                ? "High" : Defaults[.gestureSensitivity] == 200 ? "Medium" : "Low"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Gesture control")
                customBadge(text: "Beta")
            }
        } footer: {
            Text("Two-finger swipe down on the notch to open and swipe up to close. Handy when “Open notch on hover” is off.")
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            Defaults.Toggle(key: .enableHaptics) {
                Text("Enable haptic feedback")
            }
            Defaults.Toggle(key: .extendHoverArea) {
                Text("Extend hover area")
            }
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Hover delay")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
            }
        } header: {
            Text("Notch behavior")
        }
    }
}

struct Battery: View {
    @Default(.showBatteryIndicator) var showBatteryIndicator
    @Default(.showPowerStatusNotifications) var showPowerStatusNotifications

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                .disabled(!showBatteryIndicator)
            } header: {
                Text("Battery indicator")
            }
            Section {
                Defaults.Toggle(key: .showPowerStatusNotifications) {
                    Text("Show power status notifications")
                }
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
                .disabled(!showPowerStatusNotifications)
            } header: {
                Text("Power & charging")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Battery")
    }
}

struct HUD: View {
    @EnvironmentObject var vm: NotchNerdViewModel
    @Default(.inlineHUD) var inlineHUD
    @Default(.enableGradient) var enableGradient
    @Default(.optionKeyAction) var optionKeyAction
    @Default(.hudReplacement) var hudReplacement
    @Default(.showOpenNotchHUD) var showOpenNotchHUD
    @ObservedObject var coordinator = NotchNerdViewCoordinator.shared
    @State private var accessibilityAuthorized = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replace system HUD")
                            .font(.headline)
                        Text("Replaces the standard macOS volume, display brightness, and keyboard brightness HUDs with a custom design.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 40)
                    Defaults.Toggle("", key: .hudReplacement)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                        .disabled(!accessibilityAuthorized)
                }

                if !accessibilityAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accessibility access is required to replace the system HUD.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Request Accessibility") {
                            MediaKeyInterceptor.shared.requestAccessibilityAuthorization()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                Picker("Option key behavior", selection: $optionKeyAction) {
                    ForEach(OptionKeyAction.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                Defaults.Toggle(key: .enableGradient) {
                    Text("Use gradient progress bar")
                }
                Defaults.Toggle(key: .systemEventIndicatorShadow) {
                    Text("Enable glowing effect")
                }
                Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                    Text("Tint progress bar with accent color")
                }
            } header: {
                Text("Appearance")
            }
            .disabled(!hudReplacement)

            Section {
                Defaults.Toggle(key: .showOpenNotchHUD) {
                    Text("Show HUD in open notch")
                }
                Defaults.Toggle(key: .showOpenNotchHUDPercentage) {
                    Text("Show percentage in open notch")
                }
                .disabled(!showOpenNotchHUD)
            } header: {
                HStack {
                    Text("Open notch")
                    customBadge(text: "Beta")
                }
            }
            .disabled(!hudReplacement)

            Section {
                Defaults.Toggle(key: .inlineHUD) {
                    Text("Use inline HUD")
                }
                .onChange(of: inlineHUD) {
                    if inlineHUD {
                        withAnimation {
                            Defaults[.systemEventIndicatorShadow] = false
                            Defaults[.enableGradient] = false
                        }
                    }
                }
                Defaults.Toggle(key: .showClosedNotchHUDPercentage) {
                    Text("Show percentage in closed notch")
                }
            } header: {
                Text("Closed notch")
            }
            .disabled(!hudReplacement)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("HUDs")
        .task {
            // Read the APP's own AX trust — the event tap runs in-app, so the app (not the helper)
            // holds the grant. The XPC path checked the wrong process, leaving this toggle stuck
            // disabled even after the user granted the app (Phase 5.5 / c53ccfe).
            accessibilityAuthorized = MediaKeyInterceptor.shared.isAccessibilityTrusted(prompt: false)
        }
        .onAppear {
            MediaKeyInterceptor.shared.startAccessibilityMonitoring()
        }
        .onDisappear {
            MediaKeyInterceptor.shared.stopAccessibilityMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                accessibilityAuthorized = granted
            }
        }
    }
}

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = NotchNerdViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.sliderColor) var sliderColor
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.customVisualizers) var customVisualizers
    @Default(.selectedVisualizer) var selectedVisualizer

    @State private var selectedListVisualizer: CustomVisualizer? = nil
    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0

    var body: some View {
        Form {
            Section {
                Picker("Music source", selection: $mediaController) {
                    ForEach(availableMediaControllers) { controller in
                        Text(controller.rawValue).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged, object: nil)
                }
            } header: {
                Text("Media source")
            } footer: {
                if MusicManager.shared.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link(
                            "https://github.com/pear-devs/pear-desktop",
                            destination: URL(string: "https://github.com/pear-devs/pear-desktop")!
                        )
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                } else {
                    Text("‘Now Playing’ was the only option on previous versions and works with all media apps.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                Toggle("Show music live activity", isOn: $coordinator.musicLiveActivityEnabled.animation())
                Group {
                    Toggle("Show sneak peek on playback changes", isOn: $enableSneakPeek)
                    Picker("Sneak peek style", selection: $sneakPeekStyles) {
                        ForEach(SneakPeekStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .disabled(!enableSneakPeek)
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker(
                        selection: $hideNotchOption,
                        label: HStack {
                            Text("Full screen behavior")
                            customBadge(text: "Beta")
                        }
                    ) {
                        Text("Hide for all apps").tag(HideNotchOption.always)
                        Text("Hide for media app only").tag(HideNotchOption.nowPlayingOnly)
                        Text("Never hide").tag(HideNotchOption.never)
                    }
                }
                .disabled(!coordinator.musicLiveActivityEnabled)
            } header: {
                Text("Live activity")
            } footer: {
                Text("Sneak peek briefly shows the title and artist under the notch when playback changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    HStack {
                        Text("Show lyrics below artist name")
                        customBadge(text: "Beta")
                    }
                }
            } header: {
                Text("Media controls")
            } footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Colored spectrogram")
                }
                Defaults.Toggle("Player tinting", key: .playerColorTinting)
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Blur effect behind album art")
                }
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.rawValue)
                    }
                }
            } header: {
                Text("Player appearance")
            }

            visualizerSection()
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Media")
    }

    @ViewBuilder
    private func visualizerSection() -> some View {
        Section {
            Toggle("Use spectrogram visualizer", isOn: $useMusicVisualizer.animation())
            if !useMusicVisualizer {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(url: visualizer.url, speed: visualizer.speed, loopMode: .loop)
                                .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.effectiveAccent)
                                    .padding(.trailing, 8)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer == visualizer ? Color.effectiveAccent.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tapping a row makes it the active visualizer (and highlights it).
                            selectedListVisualizer = visualizer
                            selectedVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""; url = ""; speed = 1.0
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if let visualizer = selectedListVisualizer,
                               let idx = customVisualizers.firstIndex(of: visualizer) {
                                selectedListVisualizer = nil
                                customVisualizers.remove(at: idx)
                                if visualizer == selectedVisualizer, let first = customVisualizers.first {
                                    selectedVisualizer = first
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("No custom visualizer")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) { addVisualizerSheet() }
            }
        } header: {
            HStack(spacing: 0) {
                Text("Music visualizer")
                if !customVisualizers.isEmpty {
                    Text(" — \(customVisualizers.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Off shows your custom Lottie animations instead of the spectrogram. Tap an animation to select it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func addVisualizerSheet() -> some View {
        VStack(alignment: .leading) {
            Text("Add new visualizer")
                .font(.largeTitle.bold())
                .padding(.vertical)
            TextField("Name", text: $name)
            TextField("Lottie JSON URL", text: $url)
            HStack {
                Text("Speed")
                Spacer(minLength: 80)
                Text("\(speed, specifier: "%.1f")s")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Slider(value: $speed, in: 0...2, step: 0.1)
            }
            .padding(.vertical)
            HStack {
                Button {
                    isPresented.toggle()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity, alignment: .center)
                }
                Button {
                    // Guard the URL — a malformed string previously crashed via force-unwrap.
                    guard let parsed = URL(string: url) else { return }
                    let visualizer = CustomVisualizer(UUID: UUID(), name: name, url: parsed, speed: speed)
                    if !customVisualizers.contains(visualizer) {
                        customVisualizers.append(visualizer)
                    }
                    isPresented.toggle()
                } label: {
                    Text("Add").frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .disabled(URL(string: url) == nil || name.isEmpty)
            }
        }
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .controlSize(.extraLarge)
        .padding()
    }

    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showCalendar) {
                    Text("Show calendar & reminders")
                }
                Group {
                    Defaults.Toggle(key: .hideAllDayEvents) {
                        Text("Hide all-day events")
                    }
                    Defaults.Toggle(key: .autoScrollToNextEvent) {
                        Text("Auto-scroll to next event")
                    }
                    Defaults.Toggle(key: .showFullEventTitles) {
                        Text("Always show full event titles")
                    }
                    Defaults.Toggle(key: .hideCompletedReminders) {
                        Text("Hide completed reminders")
                    }
                }
                .disabled(!showCalendar)
            } header: {
                Text("Calendar & reminders")
            }

            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    permissionRow(
                        message: "NotchNerd needs Calendar access to show your events.",
                        denied: calendarManager.calendarAuthorizationStatus == .denied
                            || calendarManager.calendarAuthorizationStatus == .restricted,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                } else {
                    List {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            calendarToggle(calendar)
                        }
                    }
                }
            }

            Section(header: Text("Reminder lists")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    permissionRow(
                        message: "NotchNerd needs Reminders access to show your reminders.",
                        denied: calendarManager.reminderAuthorizationStatus == .denied
                            || calendarManager.reminderAuthorizationStatus == .restricted,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                } else {
                    List {
                        ForEach(calendarManager.reminderLists, id: \.id) { calendar in
                            calendarToggle(calendar)
                        }
                    }
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Calendar")
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }

    @ViewBuilder
    private func calendarToggle(_ calendar: CalendarModel) -> some View {
        Toggle(
            isOn: Binding(
                get: { calendarManager.getCalendarSelected(calendar) },
                set: { isSelected in
                    Task { await calendarManager.setCalendarSelected(calendar, isSelected: isSelected) }
                }
            )
        ) {
            Text(calendar.title)
        }
        .accentColor(lighterColor(from: calendar.color))
        .disabled(!showCalendar)
    }

    @ViewBuilder
    private func permissionRow(message: String, denied: Bool, settingsURL: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(denied ? "\(message) Access was denied — turn it on in System Settings." : message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Button("Open System Settings") {
                if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.vertical, 4)
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    return Color(red: Double(lighten(r)), green: Double(lighten(g)), blue: Double(lighten(b)), opacity: Double(a))
}

struct NotepadSettings: View {
    @Default(.notepadFloatStrategy) var floatStrategy

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .notepadTabEnabled) {
                    Text("Show the Notes tab in the notch")
                }
            } header: {
                Text("Notepad")
            } footer: {
                Text("An always-open scratchpad. The Notes tab takes keyboard focus without activating the app, so it never interrupts what you're doing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("Toggle Notepad:", name: .toggleNotepad)
                Picker("Floating window", selection: $floatStrategy) {
                    Text("Float over everything (incl. full screen)").tag(NotepadFloatStrategy.cgsSpace)
                    Text("Normal floating window").tag(NotepadFloatStrategy.floating)
                }
            } header: {
                Text("Floating window")
            } footer: {
                Text("Pop the notepad out into a floating window with the hotkey or the menu-bar item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Notepad")
    }
}

struct WebcamSettings: View {
    @Default(.mirrorShape) var mirrorShape

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("Enable webcam mirror")
                }
                .disabled(!checkVideoInput())
                Picker("Mirror shape", selection: $mirrorShape) {
                    Text("Circle").tag(MirrorShapeEnum.circle)
                    Text("Rectangle").tag(MirrorShapeEnum.rectangle)
                }
                Defaults.Toggle(key: .showNotHumanFace) {
                    Text("Show face animation while inactive")
                }
            } header: {
                Text("Webcam mirror")
            } footer: {
                if !checkVideoInput() {
                    Text("No camera detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A quick mirror in the notch to check your appearance. Nothing is recorded or stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Webcam")
    }

    func checkVideoInput() -> Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController

    private let repoURL = "https://github.com/7amza-eth/NotchNerd"

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName])
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unknown")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { showBuildNumber.toggle() }
                    }
                } header: {
                    Text("Version info")
                } footer: {
                    Text("Tap the version to reveal the build number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                UpdaterSettingsView(updater: updaterController.updater)

                Section {
                    HStack(spacing: 30) {
                        Spacer(minLength: 0)
                        Button {
                            if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
                        } label: {
                            VStack(spacing: 5) {
                                Image("Github")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18)
                                Text("GitHub")
                            }
                            .contentShape(Rectangle())
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            VStack(spacing: 0) {
                Divider()
                Text("NotchNerd — a fork of boring.notch + Open Island, made with 🫶🏻")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView(updater: updaterController.updater)
        }
        .navigationTitle("About")
    }
}

struct Shelf: View {

    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    @Default(.shelfEnabled) var shelfEnabled: Bool
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    init() {
        Task { await QuickShareService.shared.discoverAvailableProviders() }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .shelfEnabled) {
                    Text("Enable shelf")
                }
                Group {
                    Defaults.Toggle(key: .openShelfByDefault) {
                        Text("Open shelf by default if items are present")
                    }
                    Defaults.Toggle(key: .expandedDragDetection) {
                        Text("Larger drop target around the notch")
                    }
                    .onChange(of: expandedDragDetection) {
                        NotificationCenter.default.post(
                            name: Notification.Name.expandedDragDetectionChanged, object: nil)
                    }
                    Defaults.Toggle(key: .copyOnDrag) {
                        Text("Copy items on drag")
                    }
                    Defaults.Toggle(key: .autoRemoveShelfItems) {
                        Text("Remove from shelf after dragging")
                    }
                }
                .disabled(!shelfEnabled)
            } header: {
                Text("Shelf behavior")
            } footer: {
                Text("Drag files onto the notch to stash them; drag out, AirDrop, or share. The larger drop target makes the notch easier to hit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if quickShareService.availableProviders.isEmpty {
                    HStack {
                        Text("Quick Share service")
                        Spacer()
                        Text("Discovering…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Quick Share service", selection: $quickShareProvider) {
                        ForEach(quickShareService.availableProviders, id: \.id) { provider in
                            HStack {
                                Group {
                                    if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                                        Image(nsImage: nsImg).resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                                .frame(width: 16, height: 16)
                                .foregroundColor(.accentColor)
                                Text(provider.id)
                            }
                            .tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Quick Share")
            } footer: {
                Text("Choose which service shares files dropped on the shelf. Click the shelf's share button to pick files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shelf")
    }
}

struct Appearance: View {
    @ObservedObject var coordinator = NotchNerdViewCoordinator.shared
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData

    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil

    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Accent color", selection: $useCustomAccentColor) {
                        Text("System").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !useCustomAccentColor {
                        HStack(spacing: 12) {
                            AccentCircleButton(isSelected: true, color: .accentColor, isSystemDefault: true) {}
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Using system accent")
                                    .font(.body)
                                Text("Your macOS system accent color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Color presets")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(
                                        isSelected: selectedPresetColor == preset,
                                        color: preset.color,
                                        isMulticolor: false
                                    ) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                    }
                                }
                                Spacer()
                            }
                            Divider().padding(.vertical, 4)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pick a color")
                                        .font(.body)
                                    Text("Choose any color")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle().fill(customAccentColor).frame(width: 32, height: 32)
                                        if selectedPresetColor == nil {
                                            Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent color")
            } footer: {
                Text("Choose your system accent color or pick your own.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .onAppear { initializeAccentColorState() }

            Section {
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Scale notch corners with size")
                }
            } header: {
                Text("Window look")
            }

            Section {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Show settings icon in notch")
                }
                Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
            } header: {
                Text("Notch tab strip")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Appearance")
        .onAppear { loadCustomColor() }
    }

    private func forceUiUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }

    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }

    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }

    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01
            && abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01
            && abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }

    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil
        } else {
            loadCustomColor()
        }
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 32, height: 32)
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1).frame(width: 32, height: 32)
                if isSelected {
                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2).frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? "Use your macOS system accent color" : "")
    }
}

struct Advanced: View {
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .hideTitleBar) {
                    Text("Hide title bar")
                }
                Defaults.Toggle(key: .showOnLockScreen) {
                    Text("Show notch on lock screen")
                }
                Defaults.Toggle(key: .hideFromScreenRecording) {
                    Text("Hide from screen recording")
                }
            } header: {
                Text("Window behavior")
            }

            Section {
                Button("Reset all settings to defaults…", role: .destructive) {
                    showResetConfirm = true
                }
                .confirmationDialog("Reset all settings?", isPresented: $showResetConfirm) {
                    Button("Reset and restart", role: .destructive) {
                        if let id = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(forName: id)
                        }
                        ApplicationRelauncher.restart()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Restores every NotchNerd setting to its default and restarts the app. Your notes and shelf files are not affected.")
                }
            } header: {
                Text("Maintenance")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Advanced")
    }
}

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open / close notch:", name: .toggleNotchOpen)
            } header: {
                Text("Notch")
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle sneak peek:", name: .toggleSneakPeek)
            } header: {
                Text("Media")
            } footer: {
                Text("Sneak peek shows the media title and artist under the notch for a few seconds.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle notepad:", name: .toggleNotepad)
            } header: {
                Text("Notepad")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shortcuts")
    }
}

func customBadge(text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

#Preview {
    HUD()
}
