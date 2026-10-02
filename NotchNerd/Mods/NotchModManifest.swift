//
//  NotchModManifest.swift
//  NotchNerd
//
//  `notch-mod.json`: what a notch mod is and what it may do. A notch mod is web code that NotchNerd
//  runs in a sandbox: an optional tab page (HTML/JS/CSS in a WKWebView, only while the tab shows)
//  and optional logic (`main.js` in JavaScriptCore, while the mod is on), which can drive a chip in
//  the closed notch. See spec.md Part II → "Notch mods".
//

import Foundation

struct NotchModManifest: Codable, Equatable {
    struct Tab: Codable, Equatable {
        let title: String
        /// An SF Symbol name for the tab bar.
        let icon: String?
        /// Open height in points; clamped to `NotchModManifest.tabHeights`.
        let height: Double?
        /// The tab takes keyboard focus (text fields) while it's on screen, like the Notes tab.
        let keyboard: Bool?
        /// The page to load, relative to the mod folder. Defaults to `view.html`.
        let view: String?
    }

    /// The mod may show a chip in the closed notch (`notch.closed.set`).
    struct Closed: Codable, Equatable {
        /// Width of the chip's text side in points; clamped to `NotchModManifest.chipWidths`.
        let maxWidth: Double?
    }

    struct Surfaces: Codable, Equatable {
        let tab: Tab?
        let closed: Closed?
    }

    let id: String
    let name: String
    let version: String
    let minAppVersion: String?
    let author: String?
    let description: String?
    /// The logic script, run in JavaScriptCore while the mod is on. Optional.
    let main: String?
    let surfaces: Surfaces
    /// What the mod may use beyond its own files and storage. See `Permission`.
    let permissions: [String]?
    /// The id of this mod's Claude Code half in the mod directory, if it has one.
    let claudeMod: String?

    static let fileName = "notch-mod.json"
    static let tabHeights: ClosedRange<Double> = 120...320
    static let chipWidths: ClosedRange<Double> = 30...120

    /// Permissions a mod can ask for. `network:<host>` is separate (see `networkHosts`).
    enum Permission: String, CaseIterable {
        case mediaRead = "media.read"
        case calendarRead = "calendar.read"
        case agentRead = "agent.read"
        case notesRead = "notes.read"
        case notesWrite = "notes.write"
        case notify

        /// For Settings and, later, the install prompt.
        var summary: String {
            switch self {
            case .mediaRead: return "See what's playing"
            case .calendarRead: return "See your calendar events"
            case .agentRead: return "See your Claude Code sessions (titles and status)"
            case .notesRead: return "Read your notepad"
            case .notesWrite: return "Add to your notepad"
            case .notify: return "Show notifications in the notch"
            }
        }
    }

    enum Problem: LocalizedError {
        case badID(String)
        case nothingToRun
        case badPath(String)
        case badHost(String)
        case unknownPermission(String)

        var errorDescription: String? {
            switch self {
            case .badID(let id): return "\"\(id)\" isn't a valid id (lowercase words joined by hyphens)."
            case .nothingToRun: return "The manifest has no tab, closed chip or main script."
            case .badPath(let path): return "\"\(path)\" must be a file inside the mod folder."
            case .badHost(let host): return "\"network:\(host)\" isn't a host name."
            case .unknownPermission(let name): return "Unknown permission \"\(name)\"."
            }
        }
    }

    /// Throws the first thing that makes the manifest unusable.
    func validate() throws {
        guard id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil, id.count <= 50 else {
            throw Problem.badID(id)
        }
        guard surfaces.tab != nil || surfaces.closed != nil || main != nil else { throw Problem.nothingToRun }
        for path in [surfaces.tab.map { _ in tabView }, main].compactMap({ $0 }) where !Self.isInsideFolder(path) {
            throw Problem.badPath(path)
        }
        for permission in permissions ?? [] {
            if permission.hasPrefix("network:") {
                let host = String(permission.dropFirst("network:".count))
                if host.range(of: #"^(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) == nil {
                    throw Problem.badHost(host)
                }
            } else if Permission(rawValue: permission) == nil, permission != "storage" {
                throw Problem.unknownPermission(permission)
            }
        }
    }

    private static func isInsideFolder(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    var tabView: String { surfaces.tab?.view ?? "view.html" }

    var tabHeight: CGFloat {
        let requested = surfaces.tab?.height ?? 190
        return CGFloat(min(max(requested, Self.tabHeights.lowerBound), Self.tabHeights.upperBound))
    }

    var chipWidth: CGFloat {
        let requested = surfaces.closed?.maxWidth ?? 64
        return CGFloat(min(max(requested, Self.chipWidths.lowerBound), Self.chipWidths.upperBound))
    }

    func allows(_ permission: Permission) -> Bool {
        (permissions ?? []).contains(permission.rawValue)
    }

    var declaredPermissions: [Permission] {
        (permissions ?? []).compactMap(Permission.init(rawValue:))
    }

    /// Hosts the mod may reach (`network:<host>`), e.g. `api.example.com` or `*.example.com`.
    var networkHosts: [String] {
        (permissions ?? []).compactMap { permission in
            permission.hasPrefix("network:") ? String(permission.dropFirst("network:".count)) : nil
        }
    }
}
