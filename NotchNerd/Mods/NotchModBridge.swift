//
//  NotchModBridge.swift
//  NotchNerd
//
//  Connects a mod's tab page (WKWebView) to NotchModAPI: calls come in through a
//  `WKScriptMessageHandlerWithReply` and return as promises; events go out with evaluateJavaScript.
//  Also holds the JavaScript that builds `window.notch`, shared with the logic runtime, and the
//  per-mod storage.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class NotchModBridge: NSObject, WKScriptMessageHandlerWithReply, NotchModEventSink {
    static let handlerName = "notch"

    let mod: NotchMod
    var closeNotch: () -> Void
    weak var webView: WKWebView?

    init(mod: NotchMod, closeNotch: @escaping () -> Void) {
        self.mod = mod
        self.closeNotch = closeNotch
    }

    typealias Failure = NotchModAPI.Failure

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
            let result = try NotchModAPI.call(method, args, mod: mod, surface: .page, sink: self, closeNotch: closeNotch)
            replyHandler(result is NSNull ? nil : result, nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    func deliver(event: String, json: String) {
        guard let webView else { return }
        let eventLiteral = NotchModAPI.json(event)
        webView.evaluateJavaScript("window.__notchEmit && window.__notchEmit(\(eventLiteral), \(NotchModAPI.json(json)))",
                                   in: nil, in: .page, completionHandler: nil)
    }

    /// The page is going away: stop its events.
    func detach() {
        NotchModEvents.shared.unsubscribe(self, mod: mod.id)
        webView = nil
    }

    nonisolated static func isWebURL(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    // MARK: JavaScript

    /// Builds `notch` from a `call(method, args) → Promise` function. Shared by the page and the logic
    /// runtime; defines `notch` and `emit(event, json)` in the enclosing scope.
    nonisolated static let clientCore = """
      const listeners = new Map();
      const fmt = (values) => values.map((v) => {
        if (typeof v === 'string') return v;
        // JavaScriptCore's stack leaves out the message, so lead with it.
        if (v instanceof Error) return `${v.name}: ${v.message}` + (v.stack ? `\\n${v.stack}` : '');
        try { return JSON.stringify(v); } catch { return String(v); }
      }).join(' ');
      const on = (event, callback) => {
        if (typeof callback !== 'function') throw new TypeError('notch.on(event, callback) needs a function');
        let set = listeners.get(event);
        if (!set) {
          set = new Set();
          listeners.set(event, set);
          call('subscribe', { event }).catch((error) => notch.log.error(`notch.on('${event}'): ${error.message}`));
        }
        set.add(callback);
        return () => {
          set.delete(callback);
          if (set.size === 0 && listeners.get(event) === set) {
            listeners.delete(event);
            call('unsubscribe', { event }).catch(() => {});
          }
        };
      };
      const emit = (event, json) => {
        const set = listeners.get(event);
        if (!set) return;
        const payload = JSON.parse(json);
        for (const callback of [...set]) {
          try { callback(payload); } catch (error) { notch.log.error(error); }
        }
      };
      const log = (...values) => call('log', { message: fmt(values) });
      log.error = (...values) => call('log', { message: fmt(values), level: 'error' });
      const notch = Object.freeze({
        info: () => call('info'),
        log: Object.freeze(log),
        close: () => call('close'),
        openURL: (url) => call('openURL', { url: String(url) }),
        on,
        storage: Object.freeze({
          get: (key) => call('storage.get', { key }),
          set: (key, value) => call('storage.set', { key, value: value === undefined ? null : value }),
          remove: (key) => call('storage.remove', { key }),
          keys: () => call('storage.keys'),
        }),
        closed: Object.freeze({
          set: (chip) => call('closed.set', chip ?? {}),
          clear: () => call('closed.clear'),
        }),
        notify: (notice) => call('notify', notice ?? {}),
        media: Object.freeze({ get: () => call('media.get') }),
        calendar: Object.freeze({ events: () => call('calendar.events') }),
        agent: Object.freeze({ get: () => call('agent.get') }),
        notes: Object.freeze({
          list: () => call('notes.list'),
          read: (id) => call('notes.read', { id }),
          append: (id, text) => call('notes.append', { id, text }),
          create: (text, title) => call('notes.create', { text, title }),
        }),
      });
    """

    /// Injected into the tab page at document start. `notch` and `__notchEmit` can't be replaced.
    static let script = """
    (() => {
      const handler = window.webkit.messageHandlers.\(handlerName);
      const call = (method, args) => {
        if (method === 'log') (args.level === 'error' ? console.error : console.log)(args.message);
        return handler.postMessage({ method, args: args ?? {} });
      };
    \(clientCore)
      Object.defineProperty(window, 'notch', { value: notch, writable: false, configurable: false });
      Object.defineProperty(window, '__notchEmit', { value: emit, writable: false, configurable: false });
      const style = document.createElement('style');
      style.textContent = ':root{color-scheme:dark}html,body{margin:0;background:transparent;color:#fff;' +
        'font:13px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-user-select:none;cursor:default}';
      document.documentElement.appendChild(style);
    })();
    """
}

/// One mod's saved data: ModData/<id>/data.json, a JSON object of key → value. One instance per
/// mod, shared by its page and its logic.
@MainActor
final class NotchModStorage {
    private static var instances: [String: NotchModStorage] = [:]

    static func `for`(_ modID: String) -> NotchModStorage {
        if let existing = instances[modID] { return existing }
        let storage = NotchModStorage(modID: modID)
        instances[modID] = storage
        return storage
    }

    private let file: URL
    private var cache: [String: Any]?

    private init(modID: String) {
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
            throw NotchModAPI.Failure(message: "This mod's storage is full (1 MB).")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        cache = object
    }
}
