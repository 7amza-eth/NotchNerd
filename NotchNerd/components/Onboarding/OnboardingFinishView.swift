//
//  OnboardingFinishView.swift
//  NotchNerd
//
//  Created by Alexander on 2025-06-23.
//


import SwiftUI

struct OnboardingFinishView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    let onStartTour: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundColor(.effectiveAccent)
                .padding()

            Text("You're all set")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("NotchNerd is live in your notch. Hover the notch to open it — you'll find music, the shelf, calendar, your notepad, and (if you turned it on) your Claude Code sessions. Click the menu-bar icon anytime for settings.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()

            VStack(spacing: 12) {
                Button(action: onStartTour) {
                    Label("See what NotchNerd can do", systemImage: "play.circle")
                        .controlSize(.large)
                }
                .controlSize(.large)

                Button(action: onOpenSettings) {
                    Label("Customize in Settings", systemImage: "gear")
                        .controlSize(.large)
                }
                .controlSize(.large)

                Button("Finish", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

#Preview {
    OnboardingFinishView(onFinish: { }, onOpenSettings: { }, onStartTour: { })
}
