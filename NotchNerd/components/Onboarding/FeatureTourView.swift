//
//  FeatureTourView.swift
//  NotchNerd
//
//  A short, skippable, re-runnable feature tour shown after first-run setup (and on demand from
//  the menu-bar item / Settings). It teaches the core features with inline SwiftUI mock visuals —
//  it deliberately does NOT drive the live notch (which is a non-key, click-through SkyLight window
//  outside the Notes tab), so it has zero side effects on notch focus/state. Educational only: it
//  never enables the agent monitor — that consent lives solely in the wizard's agent step / Settings.
//

import SwiftUI

struct FeatureTourView: View {
    /// Dismiss the tour (close the onboarding window). Used by both "Finish" and "Skip tour".
    let onFinish: () -> Void

    @State private var index = 0

    private struct TourCard {
        let title: String
        let message: String
        var symbol: String = "sparkles"
        var showsAgentMock: Bool = false
        var footnote: String? = nil
    }

    private let cards: [TourCard] = [
        TourCard(
            title: "A 60-second tour",
            message: "NotchNerd lives in your notch. Here's a quick look at what it does. You can skip now and replay this anytime from the menu-bar icon.",
            symbol: "sparkles"
        ),
        TourCard(
            title: "Your notch, alive",
            message: "Play something and the notch shows the album art and a live visualizer. Hover or click it to open; swipe up to close. It's a click-through overlay, so it stays out of your way until you want it.",
            symbol: "music.note"
        ),
        TourCard(
            title: "Everything in one place",
            message: "Open the notch for the Home tab — music controls, your calendar, and a webcam mirror. Drag files onto it to stash them on the Shelf. The tabs along the top switch between them.",
            symbol: "square.grid.2x2"
        ),
        TourCard(
            title: "Watch Claude Code work",
            message: "When enabled, the Agent tab tracks your Claude Code sessions live. Watch the ✦ sparkle: a **purple ✦** means Claude is working, an **orange ✦** means Claude needs you — a permission or a question. The closed notch shows it too: a **dot** while it's cooking, **\"N need you\"** when it's waiting on you.",
            showsAgentMock: true,
            footnote: "Enable it on the setup screen, or anytime in **Settings → Agent**."
        ),
        TourCard(
            title: "An always-open notepad",
            message: "The Notes tab is a scratchpad that's always a click away. Type right in the notch — one of the few places the notch takes your keyboard — or pop it out into a floating window. Everything autosaves.",
            symbol: "note.text"
        ),
        TourCard(
            title: "Cleaner system HUDs",
            message: "If you granted Accessibility, NotchNerd replaces the stock volume, brightness, and media pop-ups with sleek overlays that animate from the notch. You can turn this off anytime in Settings → HUD.",
            symbol: "speaker.wave.2"
        ),
        TourCard(
            title: "You're ready",
            message: "That's the tour. Replay it anytime from the menu-bar icon, and fine-tune everything in Settings.",
            symbol: "checkmark.circle"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip tour") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal], 16)

            Spacer(minLength: 0)

            cardView(cards[index])
                .id(index)
                .transition(.opacity)
                .padding(.horizontal, 28)

            Spacer(minLength: 0)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    @ViewBuilder private func cardView(_ card: TourCard) -> some View {
        VStack(spacing: 18) {
            if card.showsAgentMock {
                agentStatusMock
            } else {
                Image(systemName: card.symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 54)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
            }

            Text(card.title)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(.init(card.message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let footnote = card.footnote {
                Text(.init(footnote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentStatusMock: some View {
        HStack(spacing: 32) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, options: .repeating)
                Text("working").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
                Text("needs you").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.effectiveAccent : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            HStack {
                if index > 0 {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.3)) { index -= 1 } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Spacer()
                Button(index == cards.count - 1 ? "Finish" : "Next") {
                    if index == cards.count - 1 {
                        onFinish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) { index += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

#Preview {
    FeatureTourView(onFinish: { })
        .frame(width: 400, height: 600)
}
