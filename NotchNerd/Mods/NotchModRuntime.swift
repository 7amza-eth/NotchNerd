//
//  NotchModRuntime.swift
//  NotchNerd
//
//  Runs a notch mod's logic (`"main"` in notch-mod.json) while the mod is on: plain JavaScript in a
//  JavaScriptCore context, with no web page and no WebKit process (a few MB per mod). Each mod gets its
//  own virtual machine on its own serial queue, so a slow or stuck mod can't freeze the notch; a mod
//  that keeps its queue busy for 5 seconds is stopped and reported in Settings.
//
//  The script sees `notch` (the same API as the tab page, minus close/openURL), setTimeout /
//  setInterval (intervals at least 1 second apart, at most 100 timers) and console. No DOM, no
//  network (fetch doesn't exist here), no modules: one plain script.
//

import Combine
import Defaults
import Foundation
import JavaScriptCore

@MainActor
final class NotchModRuntimeManager: ObservableObject {
    static let shared = NotchModRuntimeManager()

    /// The last error each mod's logic reported or threw.
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var running: Set<String> = []

    private var runtimes: [String: NotchModRuntime] = [:]
    private var started: [String: (revision: Int, manifest: NotchModManifest)] = [:]
    private var observers: [AnyCancellable] = []
    private var watchdog: Timer?

    private init() {}

    /// Called once at launch (AppDelegate). Starts every enabled mod's logic and follows changes.
    func start() {
        let store = NotchModStore.shared
        store.$mods.combineLatest(store.$revisions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.sync() }
            .store(in: &observers)
        Defaults.publisher(.notchModsEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &observers)
        sync()
    }

    func reportError(_ message: String, for modID: String) {
        errors[modID] = String(message.prefix(500))
    }

    /// Makes the running set match the enabled, compatible mods that have logic.
    func sync() {
        let store = NotchModStore.shared
        let enabled = Set(Defaults[.notchModsEnabled])
        let wanted = store.mods.filter { enabled.contains($0.id) && store.isCompatible($0) }
        let wantedIDs = Set(wanted.map(\.id))

        // Turned off or gone: stop it and take down anything it showed.
        for id in Array(runtimes.keys) where !wantedIDs.contains(id) { stop(id) }
        for id in NotchModChipCenter.shared.chips.keys where !wantedIDs.contains(id) {
            NotchModChipCenter.shared.clear(id)
        }

        for mod in wanted {
            let revision = store.revisions[mod.id] ?? 0
            if let previous = started[mod.id], previous.revision == revision, previous.manifest == mod.manifest,
               runtimes[mod.id] != nil || mod.manifest.main == nil {
                continue
            }
            stop(mod.id)
            started[mod.id] = (revision, mod.manifest)
            guard mod.manifest.main != nil else { continue }
            errors[mod.id] = nil
            let runtime = NotchModRuntime(mod: mod)
            runtimes[mod.id] = runtime
            running.insert(mod.id)
            runtime.start()
        }
        updateWatchdog()
    }

    private func stop(_ id: String) {
        runtimes.removeValue(forKey: id)?.stop()
        running.remove(id)
        started[id] = nil
        NotchModChipCenter.shared.clear(id)
    }

    private func updateWatchdog() {
        if runtimes.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
        } else if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkStuck() }
            }
        }
    }

    private func checkStuck() {
        for (id, runtime) in runtimes {
            guard let since = runtime.engine.busySince, Date().timeIntervalSince(since) > 5 else { continue }
            halt(id)
        }
        updateWatchdog()
    }

    /// Stops a mod whose script ran too long without a break. It stays stopped until its files
    /// change or it's turned off and on.
    func halt(_ id: String) {
        guard runtimes[id] != nil else { return }
        reportError("Stopped: its script ran for more than \(Int(NotchModJSEngine.maxRunSeconds)) seconds without a break. Fix the loop, then turn the mod off and on again.", for: id)
        runtimes.removeValue(forKey: id)?.stop()
        running.remove(id)
        NotchModChipCenter.shared.clear(id)
        // `started` stays, so sync() doesn't restart it on its own.
        updateWatchdog()
    }
}

/// One mod's running logic. Main-actor side: answers its calls and receives its events.
@MainActor
final class NotchModRuntime: NotchModEventSink {
    let mod: NotchMod
    let engine: NotchModJSEngine

    init(mod: NotchMod) {
        self.mod = mod
        engine = NotchModJSEngine(name: mod.id)
    }

    func start() {
        guard let main = mod.manifest.main else { return }
        let file = mod.folder.appendingPathComponent(main).standardizedFileURL.resolvingSymlinksInPath()
        let root = mod.folder.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let source = try? String(contentsOf: file, encoding: .utf8) else {
            NotchModRuntimeManager.shared.reportError("Couldn't read \(main).", for: mod.id)
            return
        }
        let modID = mod.id
        engine.onCall = { [weak self] id, method, argsJSON in
            Task { @MainActor in self?.handle(id: id, method: method, argsJSON: argsJSON) }
        }
        engine.onError = { message in
            Task { @MainActor in NotchModRuntimeManager.shared.reportError(message, for: modID) }
        }
        engine.onTerminated = {
            Task { @MainActor in NotchModRuntimeManager.shared.halt(modID) }
        }
        engine.start(source: source, fileName: main)
    }

    func stop() {
        NotchModEvents.shared.unsubscribe(self, mod: mod.id)
        engine.stop()
    }

    private func handle(id: Int, method: String, argsJSON: String) {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        do {
            let result = try NotchModAPI.call(method, args, mod: mod, surface: .logic, sink: self)
            engine.resolve(id, json: NotchModAPI.json(result))
        } catch {
            engine.reject(id, message: error.localizedDescription)
        }
    }

    func deliver(event: String, json: String) {
        engine.emit(event, json: json)
    }
}

/// The JavaScriptCore side. Every touch of the context happens on `queue`.
final class NotchModJSEngine: @unchecked Sendable {
    static let maxTimers = 100
    static let minInterval: TimeInterval = 1
    static let minTimeout: TimeInterval = 0.01

    private let queue: DispatchQueue
    private var context: JSContext?
    private var hooks: JSValue?
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var stopped = false

    private let lock = NSLock()
    private var _busySince: Date?
    /// When the script started its current run, or nil while it's idle. Read by the watchdog.
    var busySince: Date? {
        lock.lock(); defer { lock.unlock() }
        return _busySince
    }

    /// (call id, method, JSON args). Called on the engine's queue.
    var onCall: ((Int, String, String) -> Void)?
    var onError: ((String) -> Void)?
    /// The script ran past `maxRunSeconds` and the engine stopped itself.
    var onTerminated: (() -> Void)?

    init(name: String) {
        queue = DispatchQueue(label: "eth.7amza.notchnerd.mod.\(name)", qos: .utility)
    }

    func start(source: String, fileName: String) {
        queue.async { [self] in
            guard !stopped, let context = JSContext(virtualMachine: JSVirtualMachine()) else { return }
            context.name = "NotchNerd mod"
            context.exceptionHandler = { [weak self] _, exception in
                guard let self, let exception else { return }
                if exception.toString()?.contains("execution terminated") == true {
                    // Hit maxRunSeconds. Stop for good rather than let the next timer loop again.
                    self.stopped = true
                    for timer in self.timers.values { timer.cancel() }
                    self.timers.removeAll()
                    self.onTerminated?()
                    return
                }
                let line = exception.objectForKeyedSubscript("line")?.toString() ?? "?"
                let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
                self.onError?("\(exception.toString() ?? "Error") (line \(line))\(stack.isEmpty ? "" : "\n\(stack)")")
            }
            installNative(in: context)
            Self.limitRunTime(of: context)
            self.context = context
            run { context.evaluateScript(Self.prelude, withSourceURL: URL(string: "notchnerd://prelude.js")) }
            hooks = context.objectForKeyedSubscript("__notch")
            run { context.evaluateScript(source, withSourceURL: URL(string: "notchmod://\(fileName)")) }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for timer in timers.values { timer.cancel() }
            timers.removeAll()
            hooks = nil
            context = nil
        }
    }

    func resolve(_ id: Int, json: String) { invoke("resolve", [id, json]) }
    func reject(_ id: Int, message: String) { invoke("reject", [id, message]) }
    func emit(_ event: String, json: String) { invoke("emit", [event, json]) }

    private func invoke(_ hook: String, _ arguments: [Any]) {
        queue.async { [self] in
            guard !stopped, let function = hooks?.objectForKeyedSubscript(hook) else { return }
            run { function.call(withArguments: arguments) }
        }
    }

    /// Stops any single run of the mod's script after `maxRunSeconds`, so a runaway loop can't burn a
    /// core forever. JavaScriptCore has this (WebKit uses it), but it's not in the public headers, so
    /// it's looked up at runtime; without it, the manager's watchdog still stops calling the mod.
    static let maxRunSeconds: Double = 2

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    private static func limitRunTime(of context: JSContext) {
        guard let setLimit = setExecutionTimeLimit else { return }
        // nil callback = always terminate once the limit is hit.
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), maxRunSeconds, nil, nil)
    }

    /// Runs script on the queue, marking the engine busy for the watchdog.
    private func run(_ body: () -> Void) {
        lock.lock(); _busySince = Date(); lock.unlock()
        body()
        lock.lock(); _busySince = nil; lock.unlock()
    }

    private func installNative(in context: JSContext) {
        let call: @convention(block) (Int, String, String) -> Void = { [weak self] id, method, args in
            self?.onCall?(id, method, args)
        }
        let timer: @convention(block) (Int, Double, Bool) -> Bool = { [weak self] id, milliseconds, repeats in
            self?.addTimer(id, milliseconds: milliseconds, repeats: repeats) ?? false
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        let native = JSValue(newObjectIn: context)
        native?.setObject(call, forKeyedSubscript: "call" as NSString)
        native?.setObject(timer, forKeyedSubscript: "timer" as NSString)
        native?.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    /// Called on the queue (from script). False when the mod has too many timers.
    private func addTimer(_ id: Int, milliseconds: Double, repeats: Bool) -> Bool {
        guard timers.count < Self.maxTimers else { return false }
        let seconds = max(milliseconds.isFinite ? milliseconds / 1000 : 0, repeats ? Self.minInterval : Self.minTimeout)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + seconds, repeating: repeats ? seconds : .infinity,
                        leeway: .milliseconds(repeats ? 250 : 20))
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if !repeats { self.timers.removeValue(forKey: id)?.cancel() }
            self.invokeNow("fire", [id, repeats])
        }
        timers[id] = source
        source.resume()
        return true
    }

    /// Like invoke, but already on the queue.
    private func invokeNow(_ hook: String, _ arguments: [Any]) {
        guard let function = hooks?.objectForKeyedSubscript(hook) else { return }
        run { function.call(withArguments: arguments) }
    }

    /// Sets up `notch`, timers and console, then hides the native bridge from the mod's script.
    private static let prelude = """
    (() => {
      const native = globalThis.__native;
      delete globalThis.__native;
      const pending = new Map();
      let nextCall = 0;
      const call = (method, args) => new Promise((resolve, reject) => {
        const id = ++nextCall;
        pending.set(id, { resolve, reject });
        native.call(id, method, JSON.stringify(args ?? {}));
      });
    \(NotchModBridge.clientCore)
      const timers = new Map();
      let nextTimer = 0;
      const addTimer = (callback, ms, repeats, args) => {
        if (typeof callback !== 'function') throw new TypeError('setTimeout/setInterval need a function');
        const id = ++nextTimer;
        if (!native.timer(id, Number(ms) || 0, repeats)) throw new Error('Too many timers (100 at most).');
        timers.set(id, () => callback(...args));
        return id;
      };
      const clearTimer = (id) => { if (timers.delete(id)) native.clearTimer(id); };
      const fixed = (name, value) =>
        Object.defineProperty(globalThis, name, { value, writable: false, configurable: false });
      fixed('notch', notch);
      globalThis.setTimeout = (callback, ms, ...args) => addTimer(callback, ms, false, args);
      globalThis.setInterval = (callback, ms, ...args) => addTimer(callback, ms, true, args);
      globalThis.clearTimeout = clearTimer;
      globalThis.clearInterval = clearTimer;
      globalThis.console = Object.freeze({
        log: (...v) => { notch.log(...v); }, info: (...v) => { notch.log(...v); },
        debug: (...v) => { notch.log(...v); }, warn: (...v) => { notch.log(...v); },
        error: (...v) => { notch.log.error(...v); },
      });
      fixed('__notch', Object.freeze({
        resolve: (id, json) => {
          const call = pending.get(id);
          if (!call) return;
          pending.delete(id);
          call.resolve(JSON.parse(json));
        },
        reject: (id, message) => {
          const call = pending.get(id);
          if (!call) return;
          pending.delete(id);
          call.reject(new Error(message));
        },
        fire: (id, repeats) => {
          const callback = timers.get(id);
          if (!repeats) timers.delete(id);
          if (callback) {
            try { callback(); } catch (error) { notch.log.error(error); }
          }
        },
        emit,
      }));
    })();
    """
}
