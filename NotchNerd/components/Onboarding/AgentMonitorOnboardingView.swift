//
//  AgentMonitorOnboardingView.swift
//  NotchNerd
//
//  First-run consent + one-tap enable for the Claude Code agent monitor. This is the SINGLE
//  enable surface in onboarding (the feature tour is educational only). The agent stays OFF by
//  default: only "Turn on monitoring" enables it, and `agentEnabled` is flipped true ONLY on a
//  confirmed hook install — a failed install never enables (roll-back-on-failure), so there is
//  nothing to undo. "Not now" performs zero writes.
//

import Defaults
import SwiftUI

struct AgentMonitorOnboardingView: View {
    /// Advance to the next onboarding step (called by "Continue", "Not now", and "Skip for now").
    let onContinue: () -> Void

    @ObservedObject private var agent = AgentBridgeManager.shared

    private enum Phase: Equatable {
        case offer
        case installing
        case installed
        case failed(String)
    }

    @State private var phase: Phase = .offer
    /// Bumped on each enable attempt; drives the timeout `.task` and supersedes stale timeouts.
    @State private var installToken = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 50)
                .foregroundStyle(.purple)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.top, 28)

            Text("Watch your Claude Code sessions")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("NotchNerd's headline feature lives in the notch: a live monitor for Claude Code. See which sessions are running, get a heads-up the moment one needs your approval or asks a question, and jump straight to its terminal — without leaving what you're doing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        reassurance("eye", "Observe-only. It watches Claude Code through its own hooks. NotchNerd never calls the Anthropic API and stores no credentials.")
                        reassurance("lock.laptopcomputer", "Local. Everything stays on this Mac.")
                        reassurance("power", "Off by default. You're choosing to turn it on now, and you can turn it back off anytime in Settings → Agent.")
                    }

                    Text("Turning it on adds a few managed entries to ~/.claude/settings.json and copies a small helper into Application Support, so Claude Code can report session status to the notch. Your existing settings are backed up first, and it's fully reversible — \"Remove hooks\" in Settings → Agent restores everything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Once it's on, the notch will briefly pop open when a session needs you (with an optional sound). You can tune or silence that in Settings → Agent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
            }
            .frame(maxHeight: 270)

            statusAndButtons
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onChange(of: agent.hookInstallState) { _, newState in
            resolve(from: newState)
        }
        .task(id: installToken) {
            guard installToken != 0 else { return }   // 0 == no install in flight
            // Backstop poll. installHooks() resets state to a transient value before its async work,
            // so onChange already delivers the result reliably — but poll too, so a missed republish
            // or a slow (>a few seconds) install resolves instead of hanging. resolve() no-ops unless
            // we're still .installing, so onChange and this poll race harmlessly.
            for _ in 0..<60 {                          // ~30s cap
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard phase == .installing else { return }
                switch agent.hookInstallState {
                case .installed, .failed:
                    resolve(from: agent.hookInstallState)
                    return
                case .notInstalled, .unknown:
                    continue                            // still settling; keep waiting
                }
            }
            if phase == .installing {
                phase = .failed("Couldn't confirm the install. You can try again, or do it later in Settings → Agent.")
            }
        }
    }

    @ViewBuilder private var statusAndButtons: some View {
        switch phase {
        case .offer:
            VStack(spacing: 8) {
                Button(action: enable) {
                    Text("Turn on monitoring").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Enables monitoring and installs the Claude Code hooks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Not now") { onContinue() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing hooks…").foregroundStyle(.secondary)
            }
            .frame(height: 64)

        case .installed:
            VStack(spacing: 10) {
                Label("Monitoring is on. Claude Code hooks installed.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }

        case let .failed(message):
            VStack(spacing: 10) {
                Label("Couldn't install the Claude Code hooks", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Monitoring stays off — repair it anytime from Settings → Agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Try again") { enable() }
                        .buttonStyle(.borderedProminent)
                    Button("Skip for now") { onContinue() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func reassurance(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.purple)
                .frame(width: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Enable flow (roll-back-on-failure: agentEnabled flips true ONLY on a confirmed install)

    private func enable() {
        // Already installed earlier (e.g. via Settings → Agent, or a prior run): just enable + start.
        if agent.hookInstallState == .installed {
            enableAndStart()
            phase = .installed
            return
        }

        installToken += 1
        phase = .installing
        // installHooks() returns false ONLY on the SYNCHRONOUS missing-helper failure (it sets the
        // specific .failed message first). Surface it immediately on every attempt — including a
        // "Try again", where the identical .failed value wouldn't trip onChange. The async outcome is
        // handled by onChange(resolve) + the .task backstop.
        if !agent.installHooks() {
            if case let .failed(message) = agent.hookInstallState {
                phase = .failed(message)
            } else {
                phase = .failed("Agent hook helper not found in the app bundle.")
            }
        }
    }

    /// Resolve the installing phase from a hook-install state. No-op unless we're mid-install.
    private func resolve(from state: HookInstallState) {
        guard phase == .installing else { return }
        switch state {
        case .installed:
            enableAndStart()
            phase = .installed
        case let .failed(message):
            phase = .failed(message)     // agentEnabled left false — nothing to roll back
        case .notInstalled, .unknown:
            break                        // transient mid-install; keep the spinner
        }
    }

    private func enableAndStart() {
        Defaults[.agentEnabled] = true   // start() guards on this, so set it first
        agent.start()
    }
}
