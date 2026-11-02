//
//  GuardManager.swift
//  NotchNerd
//
//  NotchNerd's side of Guard. The engine is PresenceKit (the NotchGuard package, MIT):
//  face matching, liveness, the away cover, lock-screen face unlock and intruder alerts. This owns
//  what's NotchNerd's: the on/off switch, first-run setup state, the face model install, and the
//  Touch ID gate on quitting NotchNerd or turning Guard off.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import PresenceKit

@MainActor
final class GuardManager: ObservableObject {
    static let shared = GuardManager()

    enum ModelState: Equatable { case missing, installing(Double), ready, failed(String) }

    @Published private(set) var modelState: ModelState = .missing
    @Published private(set) var faceEnrolled = false
    @Published private(set) var cameraAllowed = false
    @Published private(set) var passwordStored = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var isRunning = false
    @Published private(set) var enrolling = false
    @Published private(set) var lastEvent: String?

    private let engine = PresenceGuard.shared
    /// Set once Touch ID approved a quit, or when macOS is logging out / shutting down.
    private var quitApproved = false

    private init() {
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.presenter = GuardNotchModel.shared // HUD and face setup draw in NotchNerd's notch
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitApproved = true }
        }
        refresh()
    }

    var enabled: Bool { Defaults[.guardEnabled] }
    var setupComplete: Bool { modelState == .ready && cameraAllowed && faceEnrolled }
    /// The notch has to stay on the lock screen while face unlock can run there, so the Face ID HUD has a home.
    var wantsLockScreenNotch: Bool { enabled && engine.config.faceUnlock && passwordStored }

    func refresh() {
        if engine.modelInstalled { modelState = .ready } else if modelState == .ready { modelState = .missing }
        faceEnrolled = engine.faceEnrolled
        cameraAllowed = AVCaptureDeviceAuthorization.isAuthorized
        passwordStored = engine.passwordStored
        accessibilityGranted = engine.accessibilityGranted
        isRunning = engine.isRunning
    }

    // MARK: lifecycle

    /// Called from `applicationDidFinishLaunching`; a no-op unless Guard is on and set up.
    func startIfEnabled() {
        refresh()
        guard enabled, setupComplete, !enrolling else { return }
        engine.start()
        refresh()
    }

    func stopEngine() {
        engine.stop()
        refresh()
    }

    /// Turning Guard on needs setup done; turning it off needs Touch ID. Returns the resulting state.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        if on {
            refresh()
            guard setupComplete else { return false }
            Defaults[.guardEnabled] = true
            startIfEnabled()
            return true
        }
        guard enabled else { return false }
        guard await PresenceGuard.confirmOwner(reason: "turn off Guard") else { return true }
        Defaults[.guardEnabled] = false
        stopEngine()
        return false
    }

    // MARK: quit protection

    /// `applicationShouldTerminate`: with Guard on, quitting (or restarting) NotchNerd needs Touch ID,
    /// so someone at an unlocked Mac can't just quit it. Logout and shutdown pass straight through.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard enabled, !quitApproved else { return .terminateNow }
        Task { @MainActor in
            let ok = await PresenceGuard.confirmOwner(reason: "quit NotchNerd and stop Guard")
            quitApproved = ok
            if ok { engine.stop() }
            app.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    // MARK: setup

    func installModel() async {
        guard modelState != .ready else { return }
        modelState = .installing(0)
        do {
            try await engine.installModel { p in
                Task { @MainActor in
                    if case .installing = GuardManager.shared.modelState { GuardManager.shared.modelState = .installing(p) }
                }
            }
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
        refresh()
    }

    func requestCamera() async {
        cameraAllowed = await engine.cameraAccess()
    }

    /// Face setup in the notch. Guard stops while it runs (they share the camera) and resumes after.
    func enroll() {
        guard !enrolling else { return }
        enrolling = true
        engine.stop()
        engine.enroll { [weak self] ok in
            guard let self else { return }
            enrolling = false
            lastEvent = ok ? "Face set up" : "Face setup didn't finish"
            refresh()
            startIfEnabled()
        }
    }

    func setUpPassword() {
        engine.setUpPassword { [weak self] _ in self?.refresh() }
    }

    func removePassword() async {
        guard await PresenceGuard.confirmOwner(reason: "remove the face unlock password") else { return }
        engine.removePassword()
        refresh()
    }

    func requestAccessibility() {
        engine.requestAccessibility()
        // The grant lands in System Settings; pick it up when the user comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }

    var config: GuardConfig {
        get { engine.config }
        set { engine.config = newValue; objectWillChange.send() }
    }

    var intruderPhotos: URL { engine.intruderPhotos }

    /// Face unlock switched on while Guard runs: Touch ID releases the stored password to the monitor.
    func setFaceUnlock(_ on: Bool) {
        var c = config; c.faceUnlock = on; config = c
        if on, passwordStored, engine.isRunning, !engine.faceUnlockArmed {
            Task { _ = await engine.armFaceUnlock() }
        }
    }

    #if DEBUG
    /// `-guardNotchDemo YES`: plays the HUD states and a fake enrollment in the notch, no camera.
    func runNotchDemo() {
        let n = GuardNotchModel.shared
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            n.showHUD(.scanning("Looking for you")); try? await Task.sleep(for: .seconds(2))
            n.showHUD(.scanning("Turn your head left")); try? await Task.sleep(for: .seconds(1.5))
            n.showHUD(.scanning("Look up")); try? await Task.sleep(for: .seconds(1.5))
            n.showHUD(.success("Welcome back")); try? await Task.sleep(for: .seconds(1.5))
            n.showHUD(.failure("Not a real face")); try? await Task.sleep(for: .seconds(1.5))
            n.hideHUD(after: 0); try? await Task.sleep(for: .seconds(1.5))
            n.enrollmentBegan(session: AVCaptureSession())
            var fill = [Double](repeating: 0, count: 8)
            for k in 1...10 { try? await Task.sleep(for: .milliseconds(150)); n.enrollmentUpdated(prompt: "Look straight at the camera", sectorFill: fill, centerProgress: Double(k) / 10) }
            for s in 0..<8 {
                n.enrollmentUpdated(prompt: "Tilt your head to the \(["up", "top right", "right", "bottom right", "down", "bottom left", "left", "top left"][s])", sectorFill: fill, centerProgress: 1)
                for k in 1...4 { try? await Task.sleep(for: .milliseconds(250)); fill[s] = Double(k) / 4; n.enrollmentUpdated(prompt: n.prompt, sectorFill: fill, centerProgress: 1) }
            }
            n.enrollmentEnded(ok: true, message: "Face set up")
        }
    }
    #endif

    // MARK: events

    private func handle(_ event: GuardEvent) {
        switch event {
        case .away: lastEvent = "Covered at \(Date().formatted(date: .omitted, time: .shortened))"
        case .back: lastEvent = "You came back at \(Date().formatted(date: .omitted, time: .shortened))"
        case .faceUnlocked: lastEvent = "Unlocked with your face at \(Date().formatted(date: .omitted, time: .shortened))"
        case .intruder(let photos, let reason):
            lastEvent = "Intruder at \(Date().formatted(date: .omitted, time: .shortened)): \(reason) (\(photos.count) photos)"
        }
    }
}

enum AVCaptureDeviceAuthorization {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
}

/// PresenceKit's tuned settings (NotchNerd has its own `Config`).
typealias GuardConfig = PresenceKit.Config
