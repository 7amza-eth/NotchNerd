//
//  TabButton.swift
//  NotchNerd
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    /// Side padding; TabSelectionView tightens it when the tabs would run under the physical notch.
    var horizontalPadding: CGFloat = 15
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .padding(.horizontal, horizontalPadding)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
