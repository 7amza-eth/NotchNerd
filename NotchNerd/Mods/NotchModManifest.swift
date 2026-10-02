//
//  NotchModManifest.swift
//  NotchNerd
//
//  `notch-mod.json`: what a notch mod is and what it may do. A notch mod is web code (HTML, JS,
//  CSS) that NotchNerd runs in a sandbox. See spec.md Part II → "Notch mods".
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

    struct Surfaces: Codable, Equatable {
        let tab: Tab?
    }

    let id: String
    let name: String
    let version: String
    let minAppVersion: String?
    let author: String?
    let description: String?
    let surfaces: Surfaces
    /// e.g. "storage", "network:api.example.com". Only `network:` grants anything so far;
    /// the rest arrive with the APIs they gate.
    let permissions: [String]?
    /// The id of this mod's Claude Code half in the mod directory, if it has one.
    let claudeMod: String?

    static let fileName = "notch-mod.json"
    static let tabHeights: ClosedRange<Double> = 120...320

    enum Problem: LocalizedError {
        case badID(String)
        case noSurface
        case badViewPath(String)
        case badHost(String)

        var errorDescription: String? {
            switch self {
            case .badID(let id): return "\"\(id)\" isn't a valid id (lowercase words joined by hyphens)."
            case .noSurface: return "The manifest declares no surfaces (add \"surfaces\": { \"tab\": … })."
            case .badViewPath(let path): return "\"\(path)\" must be a file inside the mod folder."
            case .badHost(let host): return "\"network:\(host)\" isn't a host name."
            }
        }
    }

    /// Throws the first thing that makes the manifest unusable.
    func validate() throws {
        guard id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil, id.count <= 50 else {
            throw Problem.badID(id)
        }
        guard let tab = surfaces.tab else { throw Problem.noSurface }
        let view = tab.view ?? "view.html"
        if view.hasPrefix("/") || view.split(separator: "/").contains("..") { throw Problem.badViewPath(view) }
        for host in networkHosts where host.range(of: #"^(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) == nil {
            throw Problem.badHost(host)
        }
    }

    var tabView: String { surfaces.tab?.view ?? "view.html" }

    var tabHeight: CGFloat {
        let requested = surfaces.tab?.height ?? 190
        return CGFloat(min(max(requested, Self.tabHeights.lowerBound), Self.tabHeights.upperBound))
    }

    /// Hosts the mod may reach (`network:<host>`), e.g. `api.example.com` or `*.example.com`.
    var networkHosts: [String] {
        (permissions ?? []).compactMap { permission in
            permission.hasPrefix("network:") ? String(permission.dropFirst("network:".count)) : nil
        }
    }
}
