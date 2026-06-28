//
//  AutomationInfoView.swift
//  NotchNerd
//
//  Heads-up for the macOS Automation (Apple Events) consent prompt. Unlike Camera/Calendar/
//  Reminders/Accessibility, Automation has no clean up-front request API — macOS shows the
//  "wants to control…" dialog just-in-time, the first time the app sends an Apple Event to a
//  concrete target (Spotify, Apple Music, Terminal). So this step explains what's coming rather
//  than requesting anything. The optional deep-link runs in-app (the app is the process that
//  sends the Apple Events).
//

import AppKit
import SwiftUI

struct AutomationInfoView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "gearshape.2")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 56)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 32)

            Text("About the Automation prompt")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("To control your music (Spotify or Apple Music) and to jump to the terminal running a Claude Code session, NotchNerd asks those apps to act on your behalf using macOS Automation (Apple Events). The first time it does, macOS shows a “NotchNerd wants to control…” prompt — click OK to allow it. You can change this anytime in System Settings → Privacy & Security → Automation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.secondary)
                Text("NotchNerd only sends play/pause-style commands and window-focus requests. It never reads your data inside those apps.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 10) {
                Button("Open Automation Settings…") { openAutomationSettings() }
                    .buttonStyle(.bordered)
                Button("Got it") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    AutomationInfoView(onContinue: { })
}
