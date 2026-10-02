//
//  NotchModWebView.swift
//  NotchNerd
//
//  Runs a notch mod's tab page in a sandboxed WKWebView:
//  - Pages load from notchmod://<id>/…, served by NotchModSchemeHandler from the mod's own folder
//    only, with a Content-Security-Policy that allows the mod's own files, no inline scripts, and
//    network access only to the hosts its manifest declares (`network:<host>`).
//  - No cookies or storage survive (non-persistent data store); `notch.storage` is the mod's
//    persistence, a JSON file in ModData/<id>/.
//  - Navigation never leaves the mod: http(s) links open in the default browser instead.
//  - `window.notch` is the only way out, and every call goes through NotchModBridge.
//  The web view exists only while the tab is on screen; SwiftUI tears it down when the notch closes.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct NotchModWebView: NSViewRepresentable {
    let mod: NotchMod
    /// Changes when the mod's files change (developer mode); triggers a reload.
    let revision: Int
    let closeNotch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(mod: mod, closeNotch: closeNotch) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(NotchModSchemeHandler(mod: mod), forURLScheme: NotchModSchemeHandler.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: NotchModBridge.script, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        content.addScriptMessageHandler(context.coordinator.bridge, contentWorld: .page, name: NotchModBridge.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")   // let the notch's black show through
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.isInspectable = mod.isDevelopment            // Safari → Develop → NotchNerd
        context.coordinator.revision = revision
        context.coordinator.bridge.webView = webView
        webView.load(URLRequest(url: NotchModSchemeHandler.url(for: mod, path: mod.manifest.tabView)))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.closeNotch = closeNotch
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            // The reloaded page subscribes again to what it needs.
            NotchModEvents.shared.unsubscribe(context.coordinator.bridge, mod: mod.id)
            webView.load(URLRequest(url: NotchModSchemeHandler.url(for: mod, path: mod.manifest.tabView)))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge.detach()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let mod: NotchMod
        let bridge: NotchModBridge
        var revision = 0
        var closeNotch: () -> Void {
            didSet { bridge.closeNotch = closeNotch }
        }

        init(mod: NotchMod, closeNotch: @escaping () -> Void) {
            self.mod = mod
            self.closeNotch = closeNotch
            bridge = NotchModBridge(mod: mod, closeNotch: closeNotch)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if NotchModSchemeHandler.belongs(url, to: mod) || url.absoluteString == "about:blank" {
                return decisionHandler(.allow)
            }
            // Subresources (images, fetch) aren't navigations; this only sees page loads and link
            // clicks. A clicked web link opens in the browser; anything else is refused.
            if action.navigationType == .linkActivated, NotchModBridge.isWebURL(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        // window.open / target=_blank
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, NotchModBridge.isWebURL(url) { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

// MARK: - Serving the mod's files

final class NotchModSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "notchmod"

    private let mod: NotchMod

    init(mod: NotchMod) {
        self.mod = mod
    }

    static func url(for mod: NotchMod, path: String) -> URL {
        URL(string: "\(scheme)://\(mod.id)/")!.appendingPathComponent(path)
    }

    static func belongs(_ url: URL, to mod: NotchMod) -> Bool {
        url.scheme == scheme && url.host == mod.id
    }

    /// The policy for every page a mod loads. Its own files, inline styles, data: images, and the
    /// network hosts it declared; nothing else. Not overridable by the mod: a <meta> CSP in its
    /// HTML can only narrow this further.
    static func contentSecurityPolicy(for mod: NotchMod) -> String {
        let own = "\(scheme)://\(mod.id)"
        let hosts = mod.manifest.networkHosts.map { "https://\($0)" }
        let network = hosts.joined(separator: " ")
        return [
            "default-src 'none'",
            "script-src \(own)",
            "style-src \(own) 'unsafe-inline'",
            "img-src \(own) data: blob: \(network)",
            "media-src \(own) data: blob: \(network)",
            "font-src \(own) data:",
            "connect-src \(hosts.isEmpty ? "'none'" : network)",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, Self.belongs(url, to: mod) else {
            return task.didFailWithError(URLError(.unsupportedURL))
        }
        let root = mod.folder.standardizedFileURL.resolvingSymlinksInPath()
        var relative = url.path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = mod.manifest.tabView }
        let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()

        // Never serve anything outside the mod's folder (../, symlinks).
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
            return
        }

        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = [
            "Content-Type": type.hasPrefix("text/") || type == "application/javascript" ? "\(type); charset=utf-8" : type,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if type == "text/html" { headers["Content-Security-Policy"] = Self.contentSecurityPolicy(for: mod) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
