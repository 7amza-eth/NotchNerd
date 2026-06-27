//
//  AgentNotificationSound.swift
//  NotchNerd — agent notification sounds
//
//  Plays a macOS system sound when a Claude Code session needs the user
//  (permission prompt / question / completion). Adapted from Open Island's
//  NotificationSoundService (GPL v3, Octane0411). Reads NotchNerd Defaults
//  so the Settings controls bind directly.
//

import AppKit
import Defaults

enum AgentNotificationSound {
    private static let soundsDirectory = "/System/Library/Sounds"
    static let fallbackSoundName = "Submarine"

    /// System sound names (no extension), sorted. Empty if the dir is unreadable.
    static func availableSounds() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: soundsDirectory) else { return [] }
        return contents
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    /// Plays a named system sound immediately (used for the Settings preview).
    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }

    /// Plays the user's selected sound, honoring the enabled + mute gates.
    /// No-op unless `agentSoundEnabled && !agentSoundMuted`.
    static func playNotification() {
        guard Defaults[.agentSoundEnabled], !Defaults[.agentSoundMuted] else { return }
        let name = Defaults[.agentSoundName]
        play(name.isEmpty ? fallbackSoundName : name)
    }
}
