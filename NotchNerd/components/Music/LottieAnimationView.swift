//
//  LottieAnimationContainer.swift
//  NotchNerd
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import Foundation
import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    @Default(.selectedVisualizer) var selectedVisualizer
    var body: some View {
        let visualizer = selectedVisualizer ?? CustomVisualizer.builtInPresets.first
        if let visualizer {
            LottieView(url: visualizer.url, speed: visualizer.speed, loopMode: .loop)
        } else {
            LottieView(url: URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!, speed: 1.0, loopMode: .loop)
        }
    }
}

extension CustomVisualizer {
    /// Current preset-set version. Bump this whenever `builtInPresets` changes so existing users
    /// get the new animations seeded into their list (deduped by URL) on next launch.
    static let presetVersion = 2

    /// Bundled music-visualizer presets — verified-loading LottieFiles animations that actually
    /// look like music visualizers (equalizer bars / spectrum / soundwave), so they read well in the
    /// tiny notch slot. Seeded into the user's `customVisualizers` list; preview them live in
    /// Settings and keep the ones you like. The first is the default when nothing is selected.
    static let builtInPresets: [CustomVisualizer] = [
        // The canonical 4-bar "now playing" equalizer used across many music-player apps.
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0002-4000-8000-000000000001")!,
                         name: "Equalizer",
                         url: URL(string: "https://assets7.lottiefiles.com/packages/lf20_btTua7.json")!),
        // 18-bar audio spectrum.
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0002-4000-8000-000000000002")!,
                         name: "Spectrum",
                         url: URL(string: "https://assets5.lottiefiles.com/packages/lf20_usmfx6bp.json")!),
        // Small 3-bar sound bars.
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0002-4000-8000-000000000003")!,
                         name: "Sound Bars",
                         url: URL(string: "https://assets5.lottiefiles.com/packages/lf20_jJJl6i.json")!),
        // Restored from the original set (you deleted it before testing).
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000004")!,
                         name: "Visualizer 4",
                         url: URL(string: "https://assets.lottiefiles.com/packages/lf20_szlepvdh.json")!),
    ]

    /// URLs of the old v1 "random animation" presets — used to upgrade a stale selection to the
    /// real equalizer when re-seeding (without clobbering a user's own custom pick).
    private static let legacyRandomPresetURLs: Set<String> = [
        "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json",
        "https://assets.lottiefiles.com/packages/lf20_yAh844.json",
        "https://assets.lottiefiles.com/packages/lf20_jbrw3hcz.json",
        "https://assets.lottiefiles.com/packages/lf20_touohxv0.json",
    ]

    /// Seed new presets into the user's list once per `presetVersion`. Safe to call every launch.
    @MainActor static func seedBuiltInsIfNeeded() {
        guard Defaults[.visualizerPresetVersion] < presetVersion else { return }
        Defaults[.visualizerPresetVersion] = presetVersion

        var list = Defaults[.customVisualizers]
        let existing = Set(list.map(\.url))
        list.append(contentsOf: builtInPresets.filter { !existing.contains($0.url) })
        Defaults[.customVisualizers] = list

        // Default to the real equalizer — and upgrade an old random-preset selection to it too.
        let current = Defaults[.selectedVisualizer]
        if current == nil || legacyRandomPresetURLs.contains(current!.url.absoluteString) {
            Defaults[.selectedVisualizer] = builtInPresets.first
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
