//
//  NotchNerdViewCoordinator.swift
//  NotchNerd
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import OpenIslandCore
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class NotchNerdViewCoordinator: ObservableObject {
    static let shared = NotchNerdViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""

        bindAgentNotifications()

        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                // Check the APP's own AX trust — the event tap runs in-app, so the app (not the
                // helper) must hold the grant. Routing this through the XPC helper checked the
                // wrong process and force-disabled the HUD every launch (Phase 5.5 / c53ccfe).
                let authorized = MediaKeyInterceptor.shared.isAccessibilityTrusted(prompt: false)
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    // MARK: - Agent notifications (in-notch auto-pop)

    /// The currently-popped agent notification, if the notch was opened *by* one.
    @Published private(set) var agentNotification: AgentNotification?
    private var agentNotificationCollapseTask: Task<Void, Never>?
    private var agentNotificationCancellables: Set<AnyCancellable> = []
    private static let agentNotificationCollapseDelay: TimeInterval = 10

    /// Subscribe to AgentBridgeManager's notification signals. Called once from init.
    private func bindAgentNotifications() {
        let agent = AgentBridgeManager.shared
        agent.notificationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.presentAgentNotification(note) }
            .store(in: &agentNotificationCancellables)
        agent.notificationDismissPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] sid in self?.dismissAgentNotification(for: sid) }
            .store(in: &agentNotificationCancellables)
        // A persistent (permission/question) pop self-closes once its session stops being actionable.
        agent.$actionableSession
            .receive(on: RunLoop.main)
            .sink { [weak self] actionable in self?.reconcileAgentNotification(actionable: actionable) }
            .store(in: &agentNotificationCancellables)
    }

    private func presentAgentNotification(_ note: AgentNotification) {
        guard Defaults[.agentNotificationsEnabled] else { return }
        // Suppress if the user is already looking at the session's terminal (best-effort, cheap).
        if isSessionTerminalFrontmost(note.sessionID) { return }
        // Preserve-on-hover: don't replace a different card the pointer is currently inside.
        if let current = agentNotification, current.sessionID != note.sessionID,
           AgentNotchHover.isPointerInside { return }

        AgentNotificationSound.playNotification()   // self-gated on agentSoundEnabled / muted

        agentNotification = note
        // Do NOT switch currentView here — that would hijack an already-open notch's tab (e.g. yank
        // the user out of the Notes editor). ContentView selects .agent only when it actually opens
        // the notch from a closed state. The closed-notch indicator is driven by attentionCount.
        if Defaults[.agentAutoOpenNotch] {
            NotificationCenter.default.post(name: .agentNotificationOpenRequested, object: note)
        }
        armAgentCollapse(note)
    }

    /// Called by ContentView whenever the notch closes (any path) so a finished pop doesn't leave
    /// stale notification state behind (which could suppress a later pop via the preserve-on-hover guard).
    func notchDidClose() {
        agentNotificationCollapseTask?.cancel()
        agentNotificationCollapseTask = nil
        agentNotification = nil
    }

    private func armAgentCollapse(_ note: AgentNotification) {
        agentNotificationCollapseTask?.cancel()
        agentNotificationCollapseTask = nil
        guard note.autoDismisses else { return }   // only completion notices auto-collapse
        agentNotificationCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.agentNotificationCollapseDelay))
            guard let self, !Task.isCancelled else { return }
            if AgentNotchHover.isPointerInside { return }   // defer while hovered
            self.requestAgentNotificationClose()
        }
    }

    func dismissAgentNotification(for sessionID: String) {
        guard agentNotification?.sessionID == sessionID else { return }
        requestAgentNotificationClose()
    }

    private func reconcileAgentNotification(actionable: AgentSession?) {
        guard let note = agentNotification, !note.autoDismisses else { return }
        if actionable?.id != note.sessionID { requestAgentNotificationClose() }
    }

    private func requestAgentNotificationClose() {
        agentNotificationCollapseTask?.cancel()
        agentNotificationCollapseTask = nil
        agentNotification = nil
        NotificationCenter.default.post(name: .agentNotificationCloseRequested, object: nil)
    }

    /// Best-effort: is the session's terminal already the frontmost app? (Ghostty-only, cheap —
    /// no ps/AX.) Used to suppress a pop when the user is already looking at the session.
    private func isSessionTerminalFrontmost(_ sessionID: String) -> Bool {
        guard Defaults[.agentSuppressWhenFrontmost] else { return false }
        guard let session = AgentBridgeManager.shared.sessions.first(where: { $0.id == sessionID }),
              let target = session.jumpTarget,
              let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        let app = target.terminalApp.lowercased()
        let isGhostty = app.contains("ghostty") || app.contains("mitchellh")
        return isGhostty && frontBundle == GhosttyJumpService.bundleIdentifier
    }

    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}

extension Notification.Name {
    static let agentNotificationOpenRequested = Notification.Name("agentNotificationOpenRequested")
    static let agentNotificationCloseRequested = Notification.Name("agentNotificationCloseRequested")
}

/// Set by ContentView.handleHover so the coordinator can defer auto-collapse / preserve on hover.
/// Mirrors the NotepadNotchFocus pattern.
enum AgentNotchHover {
    static var isPointerInside = false
}
