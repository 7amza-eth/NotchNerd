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
    /// Bundled visualizer presets — a handful of verified-loading LottieFiles animations. They are
    /// seeded once into the user's `customVisualizers` list so each can be previewed live in
    /// Settings, selected, and removed. (Fun loops; preview and keep the ones you like.)
    static let builtInPresets: [CustomVisualizer] = [
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000001")!,
                         name: "Visualizer 1",
                         url: URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!),
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000002")!,
                         name: "Visualizer 2",
                         url: URL(string: "https://assets.lottiefiles.com/packages/lf20_yAh844.json")!),
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000003")!,
                         name: "Visualizer 3",
                         url: URL(string: "https://assets.lottiefiles.com/packages/lf20_jbrw3hcz.json")!),
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000004")!,
                         name: "Visualizer 4",
                         url: URL(string: "https://assets.lottiefiles.com/packages/lf20_szlepvdh.json")!),
        CustomVisualizer(UUID: Foundation.UUID(uuidString: "5715A11D-0001-4000-8000-000000000005")!,
                         name: "Visualizer 5",
                         url: URL(string: "https://assets.lottiefiles.com/packages/lf20_touohxv0.json")!),
    ]

    /// Append the presets to the user's list exactly once. Safe to call on every launch.
    @MainActor static func seedBuiltInsIfNeeded() {
        guard !Defaults[.visualizersSeeded] else { return }
        Defaults[.visualizersSeeded] = true
        var list = Defaults[.customVisualizers]
        let existing = Set(list.map(\.url))
        list.append(contentsOf: builtInPresets.filter { !existing.contains($0.url) })
        Defaults[.customVisualizers] = list
        if Defaults[.selectedVisualizer] == nil {
            Defaults[.selectedVisualizer] = builtInPresets.first
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
