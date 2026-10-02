//
//  NotchModBridge.swift
//  NotchNerd
//
//  `window.notch`: the API a notch mod's page gets. Every call arrives here as
//  { method, args } and returns a promise. Keep this list and tooling/notch-mod-sample/notchnerd.d.ts
//  in step.
//
//    notch.info()                     { id, version, appVersion, development }
//    notch.close()                    close the notch
//    notch.openURL(url)               open an http(s) link in the default browser
//    notch.log(...values)             print to Console.app (and the Web Inspector in developer mode)
//    notch.storage.get(key)           this mod's saved value, or null
//    notch.storage.set(key, value)    save any JSON value (1 MB per mod)
//    notch.storage.remove(key)
//    notch.storage.keys()
//

import AppKit
import Foundation
import os
import WebKit

@MainActor
final class NotchModBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "notch"
    static let storageLimit = 1_000_000

    let mod: NotchMod
    var closeNotch: () -> Void
    private let storage: NotchModStorage
    private let log: Logger

    init(mod: NotchMod, closeNotch: @escaping () -> Void) {
        self.mod = mod
        self.closeNotch = closeNotch
        storage = NotchModStorage(modID: mod.id)
        log = Logger(subsystem: "eth.7amza.notchnerd", category: "mod.\(mod.id)")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the mod's own top-level page may call in.
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              NotchModSchemeHandler.belongs(url, to: mod),
              let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return replyHandler(nil, "Not allowed.")
        }
        let args = body["args"] as? [String: Any] ?? [:]
        do {
            replyHandler(try handle(method, args), nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    private func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
        switch method {
        case "info":
            return [
                "id": mod.id,
                "version": mod.manifest.version,
                "appVersion": Bundle.main.releaseVersionNumber ?? "",
                "development": mod.isDevelopment,
            ]
        case "close":
            closeNotch()
            return nil
        case "openURL":
            guard let string = args["url"] as? String, let url = URL(string: string), Self.isWebURL(url) else {
                throw Failure(message: "notch.openURL takes an http or https URL.")
            }
            NSWorkspace.shared.open(url)
            return nil
        case "log":
            let text = (args["message"] as? String ?? "").prefix(2000)
            log.info("\(text, privacy: .public)")
            return nil
        case "storage.get":
            return try storage.get(try key(args)) ?? NSNull()
        case "storage.set":
            guard let value = args["value"], JSONSerialization.isValidJSONObject([value]) else {
                throw Failure(message: "notch.storage.set takes a JSON value.")
            }
            try storage.set(try key(args), value, limit: Self.storageLimit)
            return nil
        case "storage.remove":
            try storage.remove(try key(args))
            return nil
        case "storage.keys":
            return try storage.keys()
        default:
            throw Failure(message: "notch.\(method) isn't available in this version of NotchNerd.")
        }
    }

    private func key(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, !key.isEmpty, key.count <= 200 else {
            throw Failure(message: "Storage keys are non-empty strings of up to 200 characters.")
        }
        return key
    }

    nonisolated static func isWebURL(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    /// Injected at document start. Frozen so the page can't swap out the API it calls.
    static let script = """
    (() => {
      const handler = window.webkit.messageHandlers.\(handlerName);
      const call = (method, args) => handler.postMessage({ method, args: args ?? {} });
      const storage = Object.freeze({
        get: (key) => call('storage.get', { key }),
        set: (key, value) => call('storage.set', { key, value: value === undefined ? null : value }),
        remove: (key) => call('storage.remove', { key }),
        keys: () => call('storage.keys'),
      });
      const notch = Object.freeze({
        info: () => call('info'),
        close: () => call('close'),
        openURL: (url) => call('openURL', { url: String(url) }),
        log: (...values) => {
          console.log(...values);
          return call('log', { message: values.map((v) => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') });
        },
        storage,
      });
      Object.defineProperty(window, 'notch', { value: notch, writable: false, configurable: false });
      const style = document.createElement('style');
      style.textContent = ':root{color-scheme:dark}html,body{margin:0;background:transparent;color:#fff;' +
        'font:13px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-user-select:none;cursor:default}';
      document.documentElement.appendChild(style);
    })();
    """
}

/// One mod's saved data: ModData/<id>/data.json, a JSON object of key → value.
@MainActor
final class NotchModStorage {
    private let file: URL
    private var cache: [String: Any]?

    init(modID: String) {
        file = NotchModStore.dataDirectory.appendingPathComponent(modID, isDirectory: true)
            .appendingPathComponent("data.json")
    }

    private func load() throws -> [String: Any] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: file) else { cache = [:]; return [:] }
        let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        cache = object
        return object
    }

    func get(_ key: String) throws -> Any? { try load()[key] }

    func keys() throws -> [String] { try load().keys.sorted() }

    func set(_ key: String, _ value: Any, limit: Int) throws {
        var object = try load()
        object[key] = value
        try save(object, limit: limit)
    }

    func remove(_ key: String) throws {
        var object = try load()
        guard object.removeValue(forKey: key) != nil else { return }
        try save(object, limit: .max)
    }

    private func save(_ object: [String: Any], limit: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= limit else {
            throw NotchModBridge.Failure(message: "This mod's storage is full (1 MB).")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        cache = object
    }
}
