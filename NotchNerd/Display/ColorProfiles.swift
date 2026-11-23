//
//  ColorProfiles.swift
//  NotchNerd
//
//  Display color profiles through ColorSync: list the installed profiles, read the one a display
//  uses, and set a custom one (or go back to the factory profile).
//

import AppKit
import ColorSync
import CoreGraphics
import Foundation

enum ColorProfiles {
    struct Profile: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    /// Display-class (`mntr`) and common RGB profiles from the usual ColorSync folders.
    static func all() -> [Profile] {
        let folders = ["/Library/ColorSync/Profiles/Displays", "/Library/ColorSync/Profiles",
                       "/System/Library/ColorSync/Profiles", "\(NSHomeDirectory())/Library/ColorSync/Profiles"]
        var seen = Set<String>()
        var result: [Profile] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in names where file.hasSuffix(".icc") || file.hasSuffix(".icm") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
                guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { continue }
                let name = (ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?) ?? file
                if seen.insert(name).inserted { result.append(Profile(url: url, name: name)) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor static func currentName(for id: CGDirectDisplayID) -> String? {
        DisplayManager.screen(for: id)?.colorSpace?.localizedName
    }

    /// nil url = back to the factory profile.
    static func set(_ url: URL?, for id: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return }
        let key = kColorSyncDeviceDefaultProfileID.takeUnretainedValue()
        let value: CFTypeRef = url.map { $0 as CFURL } ?? kCFNull
        let dict = [key: value] as CFDictionary
        ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, dict)
    }
}
