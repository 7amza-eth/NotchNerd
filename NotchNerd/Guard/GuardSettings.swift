//
//  GuardSettings.swift
//  NotchNerd
//
//  Settings → Guard: the on/off switch and the first-run setup, in order
//  (face model, camera, face, then the optional face unlock and iMessage alerts).
//

import Defaults
import PresenceKit
import SwiftUI

struct GuardSettings: View {
    @ObservedObject private var manager = GuardManager.shared
    @Default(.guardEnabled) private var enabled
    @State private var switching = false
    @State private var alertTo = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { on in
                    switching = true
                    Task { await manager.setEnabled(on); switching = false }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guard this Mac while I'm away")
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(switching || (!enabled && !manager.setupComplete))
            } header: {
                Text("Guard")
            } footer: {
                Text("When you've been idle for 10 seconds, Guard checks the camera for your face. If you're gone, a frosted cover goes up and lifts when you sit back down. Someone else at the Mac, a photo of you, or typing while you're away locks the Mac and saves photos. Turning Guard off or quitting NotchNerd needs Touch ID. Frames are never saved unless there's an intruder, and nothing leaves this Mac except the optional iMessage alert.")
            }

            Section {
                step(1, "Face model", done: manager.modelState == .ready) { modelControl }
                step(2, "Camera access", done: manager.cameraAllowed) {
                    Button("Allow camera") { Task { await manager.requestCamera() } }
                }
                step(3, "Your face", done: manager.faceEnrolled) {
                    Button(manager.enrolling ? "Look at the notch…" : "Set up face") { manager.enroll() }
                        .disabled(manager.modelState != .ready || !manager.cameraAllowed || manager.enrolling)
                }
                if manager.faceEnrolled {
                    HStack {
                        Text("Redo face setup").foregroundStyle(.secondary)
                        Spacer()
                        Button("Set up again") { manager.enroll() }.disabled(manager.enrolling)
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Guard uses InsightFace's MobileFaceNet model (w600k_mbf). InsightFace's pretrained models are licensed for non-commercial research use only, so NotchNerd doesn't include them: the button downloads the 13 MB model from InsightFace's own GitHub release, checks it, and converts it to Core ML on this Mac. By downloading it you agree to InsightFace's terms.")
            }

            Section {
                Toggle("Unlock the lock screen when it sees me", isOn: Binding(get: { manager.config.faceUnlock }, set: { manager.setFaceUnlock($0) }))
                Toggle("Require a blink at the lock screen", isOn: configBinding(\.lockScreenBlink))
                    .disabled(!manager.config.faceUnlock)
                HStack {
                    Text("Mac password")
                    Spacer()
                    if manager.passwordStored {
                        Text("Stored in your keychain").foregroundStyle(.secondary)
                        Button("Remove") { Task { await manager.removePassword() } }
                    } else {
                        Button("Store password…") { manager.setUpPassword() }
                    }
                }
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if manager.accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { manager.requestAccessibility() }
                    }
                }
            } header: {
                Text("Face unlock (optional)")
            } footer: {
                Text("To unlock, Guard types your Mac password at the lock screen, and only there. The password is checked against your account, kept in your login keychain, and released by Touch ID once each time NotchNerd starts. Typing it needs Accessibility. Face unlock switches itself off after an intruder until you type your password yourself. While it's on, the notch stays on the lock screen to show the Face ID glyph.")
            }
            .disabled(!manager.faceEnrolled)

            Section {
                HStack {
                    TextField("Phone number or Apple ID email", text: $alertTo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAlert)
                    Button("Save", action: saveAlert).disabled(alertTo == manager.config.alertTo)
                }
                HStack {
                    Button("Show intruder photos") { NSWorkspace.shared.open(manager.intruderPhotos) }
                    Spacer()
                }
            } header: {
                Text("Intruder alerts (optional)")
            } footer: {
                Text("Intruder photos are always saved on this Mac. With a number or email here, Guard also sends them over iMessage from the Messages app (macOS asks once to let NotchNerd control Messages).")
            }

            if let last = manager.lastEvent {
                Section { Text(last).foregroundStyle(.secondary) } header: { Text("Last event") }
            }
        }
        .onAppear {
            manager.refresh()
            alertTo = manager.config.alertTo
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refresh()
        }
    }

    private var statusLine: String {
        if !manager.setupComplete { return "Finish setup below to turn it on" }
        if !enabled { return "Off" }
        return manager.isRunning ? "Watching while you're away" : "Starting…"
    }

    @ViewBuilder
    private var modelControl: some View {
        switch manager.modelState {
        case .missing:
            Button("Download (13 MB)") { Task { await manager.installModel() } }
        case .installing(let p):
            HStack {
                ProgressView(value: p).frame(width: 120)
                Text(p < 1 ? "Downloading" : "Converting").foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()
        case .failed(let message):
            HStack {
                Text(message).foregroundStyle(.red).lineLimit(2)
                Button("Try again") { Task { await manager.installModel() } }
            }
        }
    }

    private func step<Control: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(title)
            Spacer()
            if done { Text("Done").foregroundStyle(.secondary) } else { control() }
        }
    }

    private func configBinding(_ key: WritableKeyPath<GuardConfig, Bool>) -> Binding<Bool> {
        Binding(get: { manager.config[keyPath: key] }, set: { var c = manager.config; c[keyPath: key] = $0; manager.config = c })
    }

    private func saveAlert() {
        var c = manager.config
        c.alertTo = alertTo.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.config = c
        alertTo = c.alertTo
    }
}
