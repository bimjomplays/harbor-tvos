import Foundation
import JavaScriptCore
import Security
import os

/// Everything that can go wrong on the Swift side of the bridge.
enum EngineError: Error, CustomStringConvertible {
    /// `harbor-engine.js` is not in the app bundle.
    case bundleMissing
    /// JavaScriptCore refused to make a context or an object.
    case contextCreation(String)
    /// `HarborEngine.runtime.missingHostFunctions()` came back non-empty.
    case missingHostFunctions([String])
    /// A JavaScript exception, message first and stack after it when JSC gave us one.
    case js(String)
    /// The bundle answered with something we cannot use.
    case badResult(String)
    /// The engine was deallocated while a call was in flight.
    case gone

    var description: String {
        switch self {
        case .bundleMissing:
            return "harbor-engine.js is missing from the app bundle (App/Engine/harbor-engine.js)"
        case .contextCreation(let what):
            return "JavaScriptCore could not create \(what)"
        case .missingHostFunctions(let names):
            return "__harbor_host is incomplete, missing: \(names.joined(separator: ", "))"
        case .js(let message):
            return "JS error: \(message)"
        case .badResult(let message):
            return "bad engine result: \(message)"
        case .gone:
            return "the engine was released while a call was in flight"
        }
    }
}

/// A malformed `HostRequest` from the JS side. Never surfaces to Swift callers: it is
/// turned straight into the `TypeError` shape the fetch shim expects.
private struct FetchParseError: Error {
    let message: String
}

/// Upstream Harbor's framework-free logic, bundled by `engine/build.mjs`, running in
/// JavaScriptCore behind the `__harbor_host` contract (docs/engine-report.md §3).
///
/// Threading: `JSContext` is not thread-safe, so every single touch of the context or of any
/// `JSValue` happens on `queue`. Public async calls hop onto it with `queue.async`;
/// `benchmark(rounds:)` is the one synchronous entry point and uses `queue.sync`, so it must
/// never be called from inside `queue`.
///
/// Storage: the bundle keeps its own in-memory mirror of `localStorage`, seeded from
/// `storageSnapshot()` at boot. **Any `KeyValueStore` write made from Swift (account sync
/// writing `harbor.settings`, a profile switch rewriting `harbor.profiles.v1`, …) must be
/// mirrored into the bundle with `syncStorage(key:value:)`, or the bundle keeps serving the
/// value it read at boot.** Wiring that up is the caller's job; the engine deliberately does
/// not observe `KeyValueStore`.
final class HarborEngine {

    // MARK: - Lifetime

    private static let sharedLock = NSLock()
    private static var sharedInstance: HarborEngine?

    /// The engine if it has already been started (never triggers the 1 s boot).
    static var loaded: HarborEngine? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return sharedInstance
    }

    /// The process-wide engine, built on first use. Building it evaluates a ~900 KB bundle
    /// (expect 0.5–1 s on an Apple TV), so ask for it off the main thread during launch.
    /// This is the form to use anywhere the failure can be shown to the user.
    static func sharedOrThrow() throws -> HarborEngine {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = sharedInstance { return existing }
        let engine = try HarborEngine()
        sharedInstance = engine
        return engine
    }

    /// The same instance, for call sites that cannot deal with a failure. A missing or
    /// broken `harbor-engine.js` is a build problem, so it traps rather than limping on.
    static var shared: HarborEngine {
        do {
            return try sharedOrThrow()
        } catch {
            fatalError("HarborEngine could not start: \(error)")
        }
    }

    private let virtualMachine: JSVirtualMachine?
    private let context: JSContext
    private let queue = DispatchQueue(label: "harbor.engine")
    private let logger = Logger(subsystem: "com.dltnp.harbor", category: "engine")

    /// Last uncaught JS exception seen by `context.exceptionHandler`; cleared before every
    /// entry into JS and read straight after.
    private var lastException: String?

    // Timers (engine queue only).
    private var timers: [Int: DispatchWorkItem] = [:]

    // In-flight fetches (engine queue only).
    private var pendingFetches: [Int: PendingFetch] = [:]

    // In-flight Swift → JS calls (engine queue only).
    private var pendingCalls: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextCallToken = 1

    // Networking. The session is never invalidated: the engine lives for the process.
    private let redirectDelegate: RedirectPolicyDelegate
    private let session: URLSession

    // Logs and event observers (touched from several threads, so they take the lock).
    private let sideLock = NSLock()
    private var logRing: [String] = []
    private var eventHandlers: [(id: Int, fn: (String, AnyJSON?) -> Void)] = []
    private var nextHandlerId = 1

    private static let logRingCapacity = 200

    // WebSockets (engine/shims/websocket.js; Watch Together's relay). Created on the engine
    // queue by the first wsOpen; its events hop back onto the queue before reaching JS.
    private lazy var sockets = EngineSockets { [weak self] id, kind, data in
        guard let self else { return }
        let payload: Any = data.map { $0 as Any } ?? NSNull()
        self.queue.async { self.invokeGlobal("__harbor_ws_event", arguments: [Double(id), kind, payload]) }
    }

    init() throws {
        guard let url = Bundle.main.url(forResource: "harbor-engine", withExtension: "js") else {
            throw EngineError.bundleMissing
        }
        let source = try String(contentsOf: url, encoding: .utf8)

        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            throw EngineError.contextCreation("a JSContext")
        }
        self.virtualMachine = vm
        self.context = context

        let delegate = RedirectPolicyDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = true
        // Do not set httpAdditionalHeaders: URLSession's own Accept-Encoding is what makes
        // gzip/br decompression transparent, which the bundle's TMDB client relies on.
        self.redirectDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var thrown: Error?
        queue.sync {
            do { try self.boot(source: source) } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    // MARK: - Boot

    private func boot(source: String) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            var text = exception?.toString() ?? "unknown JS exception"
            let stack: JSValue? = exception?.objectForKeyedSubscript("stack")
            if let stackText = stack?.toString(), !stackText.isEmpty, stack?.isUndefined == false {
                text += "\n" + stackText
            }
            self.lastException = text
            self.logger.error("uncaught JS exception: \(text, privacy: .public)")
            self.appendLog("error", "uncaught JS exception: " + text)
        }

        try installHost()
        try installBridgeBlocks()

        lastException = nil
        _ = context.evaluateScript(source, withSourceURL: URL(string: "harbor-engine.js"))
        if let failure = lastException { throw EngineError.js(failure) }

        let missing = try missingHostFunctions()
        if !missing.isEmpty { throw EngineError.missingHostFunctions(missing) }

        lastException = nil
        _ = context.evaluateScript(Self.glue, withSourceURL: URL(string: "harbor-glue.js"))
        if let failure = lastException { throw EngineError.js(failure) }
    }

    private func missingHostFunctions() throws -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        let engine: JSValue? = context.objectForKeyedSubscript("HarborEngine")
        guard let engine, engine.isUndefined == false, engine.isNull == false else {
            throw EngineError.badResult("the bundle did not define a HarborEngine global")
        }
        let runtime: JSValue? = engine.objectForKeyedSubscript("runtime")
        guard let runtime, runtime.isUndefined == false, runtime.isNull == false else {
            throw EngineError.badResult("HarborEngine.runtime is missing")
        }
        lastException = nil
        let result: JSValue? = runtime.invokeMethod("missingHostFunctions", withArguments: [])
        if let failure = lastException { throw EngineError.js(failure) }
        guard let list = result?.toArray() as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    // MARK: - The host contract (docs/engine-report.md §3)

    private func installHost() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let host: JSValue? = JSValue(newObjectIn: context)
        guard let host else { throw EngineError.contextCreation("the __harbor_host object") }

        // ---- network ----------------------------------------------------------------
        let fetchBlock: @convention(block) (JSValue?) -> JSValue? = { [weak self] request in
            guard let self else { return nil }
            let parsed = HarborEngine.parseRequest(request)
            return JSValue(newPromiseIn: self.context, fromExecutor: { resolve, reject in
                let resolveFn: JSValue? = resolve
                let rejectFn: JSValue? = reject
                switch parsed {
                case .failure(let failure):
                    self.rejectFetch(rejectFn, name: "TypeError", message: failure.message)
                case .success(let hostRequest):
                    self.startFetch(hostRequest, resolve: resolveFn, reject: rejectFn)
                }
            })
        }

        let abortBlock: @convention(block) (Double) -> Void = { [weak self] rawId in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.abortFetch(id)
        }

        // ---- storage ----------------------------------------------------------------
        let snapshotBlock: @convention(block) () -> [String: String] = {
            KeyValueStore.shared.snapshot()
        }
        let getBlock: @convention(block) (String) -> String? = { key in
            KeyValueStore.shared.get(key)
        }
        let setBlock: @convention(block) (String, String) -> Void = { [weak self] key, value in
            do {
                try KeyValueStore.shared.set(value, for: key)
            } catch {
                self?.logger.error("storageSet(\(key, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                self?.appendLog("error", "storageSet(\(key)) failed: \(error)")
            }
        }
        let removeBlock: @convention(block) (String) -> Void = { key in
            KeyValueStore.shared.remove(key)
        }
        let clearBlock: @convention(block) () -> Void = {
            for key in KeyValueStore.shared.snapshot().keys where KeyValueStore.isEngineKey(key) {
                KeyValueStore.shared.remove(key)
            }
        }

        // ---- clock / entropy ---------------------------------------------------------
        let nowBlock: @convention(block) () -> Double = {
            Date().timeIntervalSince1970 * 1000
        }
        let uuidBlock: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        let randomBytesBlock: @convention(block) (Double) -> String = { rawCount in
            let count = min(max(HarborEngine.asInt(rawCount) ?? 0, 0), 1 << 20)
            guard count > 0 else { return "" }
            var bytes = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
                for index in 0..<count { bytes[index] = UInt8.random(in: UInt8.min...UInt8.max) }
            }
            return Data(bytes).base64EncodedString()
        }

        // ---- logging -----------------------------------------------------------------
        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.record(level: level, message: message)
        }

        // ---- timers ------------------------------------------------------------------
        let setTimeoutBlock: @convention(block) (Double, Double) -> Void = { [weak self] delayMs, rawId in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.scheduleTimer(id: id, delayMs: delayMs)
        }
        let clearTimeoutBlock: @convention(block) (Double) -> Void = { [weak self] rawId in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.cancelTimer(id)
        }

        // ---- WebSocket (optional; engine/shims/websocket.js) -----------------------------
        let wsOpenBlock: @convention(block) (String, Double) -> Void = { [weak self] url, rawId in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.sockets.open(url: url, id: id)
        }
        let wsSendBlock: @convention(block) (Double, String) -> Void = { [weak self] rawId, text in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.sockets.send(id: id, text: text)
        }
        let wsCloseBlock: @convention(block) (Double, Double, String) -> Void = { [weak self] rawId, rawCode, reason in
            guard let self, let id = HarborEngine.asInt(rawId) else { return }
            self.sockets.close(id: id, code: HarborEngine.asInt(rawCode) ?? 1000, reason: reason)
        }

        host.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        host.setObject(abortBlock, forKeyedSubscript: "abort" as NSString)
        host.setObject(snapshotBlock, forKeyedSubscript: "storageSnapshot" as NSString)
        host.setObject(getBlock, forKeyedSubscript: "storageGet" as NSString)
        host.setObject(setBlock, forKeyedSubscript: "storageSet" as NSString)
        host.setObject(removeBlock, forKeyedSubscript: "storageRemove" as NSString)
        host.setObject(clearBlock, forKeyedSubscript: "storageClear" as NSString)
        host.setObject(nowBlock, forKeyedSubscript: "now" as NSString)
        host.setObject(uuidBlock, forKeyedSubscript: "randomUUID" as NSString)
        host.setObject(randomBytesBlock, forKeyedSubscript: "randomBytes" as NSString)
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        host.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        host.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        host.setObject(wsOpenBlock, forKeyedSubscript: "wsOpen" as NSString)
        host.setObject(wsSendBlock, forKeyedSubscript: "wsSend" as NSString)
        host.setObject(wsCloseBlock, forKeyedSubscript: "wsClose" as NSString)

        context.setObject(host, forKeyedSubscript: "__harbor_host" as NSString)
    }

    /// The two blocks the glue in `Self.glue` calls back into: one settles a pending
    /// `call`, the other forwards a `window` event. Installing them as globals (instead of
    /// handing JS a block per call) keeps every `JSValue` lifetime inside this file.
    private func installBridgeBlocks() throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let settleBlock: @convention(block) (Double, Bool, String?) -> Void = { [weak self] rawToken, ok, payload in
            guard let self, let token = HarborEngine.asInt(rawToken) else { return }
            self.settleCall(token: token, ok: ok, payload: payload)
        }
        let eventBlock: @convention(block) (String, String?) -> Void = { [weak self] type, detailArrayJSON in
            self?.deliverEvent(type: type, detailArrayJSON: detailArrayJSON)
        }

        context.setObject(settleBlock, forKeyedSubscript: "__harbor_settle" as NSString)
        context.setObject(eventBlock, forKeyedSubscript: "__harbor_event" as NSString)
    }

    // MARK: - Public API

    /// Call any function on the `HarborEngine.*` surface and decode its JSON result.
    /// `path` is dotted, e.g. `"cinemeta.topMovies"` or `"runtime.selfTest"`.
    func call<T: Decodable>(_ path: String, _ args: [any Encodable] = []) async throws -> T {
        let json = try await rawCall(path, argsJSON: Self.encodeArgs(args))
        return try Self.decodeSingle(json, as: T.self)
    }

    /// The same, when the shape of the result is not known up front.
    func callJSON(_ path: String, _ args: [AnyJSON] = []) async throws -> AnyJSON {
        let json = try await rawCall(path, argsJSON: Self.encodeJSONArgs(args))
        return try Self.decodeSingle(json, as: AnyJSON.self)
    }

    /// `HarborEngine.runtime.selfTest()` — proves URL, storage, crypto, Intl, timers and a
    /// real network fetch all work through this host.
    func selfTest() async throws -> AnyJSON {
        try await callJSON("runtime.selfTest", [])
    }

    /// Dispatch a `harbor:*` event into the bundle (Swift → JS).
    func emitEvent(_ type: String, detail: AnyJSON? = nil) {
        // The detail crosses as a one-element JSON array so a bare `null`, number or string
        // survives: JSONEncoder/JSONDecoder only guarantee containers at the top level.
        let payload: String? = detail.flatMap { value in
            guard let data = try? JSONEncoder().encode([value]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        var arguments: [Any] = [type]
        if let payload { arguments.append(payload) } else { arguments.append(NSNull()) }
        queue.async { [weak self] in
            self?.invokeGlobal("__harbor_emit", arguments: arguments)
        }
    }

    /// Tell the bundle that a `harbor.*` key changed underneath it. Call this after **every**
    /// `KeyValueStore` write made from Swift; `nil` means the key was removed.
    func syncStorage(key: String, value: String?) {
        var arguments: [Any] = [key]
        if let value { arguments.append(value) } else { arguments.append(NSNull()) }
        queue.async { [weak self] in
            self?.invokeGlobal("__harbor_sync", arguments: arguments)
        }
    }

    /// Observe every event the bundle dispatches on `window`. Handlers run on the main queue.
    /// Returns an unsubscribe; call it when the observer goes away.
    @discardableResult
    func onEvent(_ handler: @escaping (String, AnyJSON?) -> Void) -> () -> Void {
        sideLock.lock()
        let id = nextHandlerId
        nextHandlerId += 1
        eventHandlers.append((id, handler))
        sideLock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.sideLock.lock()
            self.eventHandlers.removeAll { $0.id == id }
            self.sideLock.unlock()
        }
    }

    /// The last 200 lines the bundle logged, newest last. For the debug screen.
    var recentLogs: [String] {
        sideLock.lock()
        defer { sideLock.unlock() }
        return logRing
    }

    /// Stage-0 stream benchmark, kept synchronous so `EngineSpikeView` still works.
    /// Never call this from inside the engine queue.
    func benchmark(rounds: Int) throws -> [String: Any] {
        try queue.sync {
            self.lastException = nil
            let engine: JSValue? = self.context.objectForKeyedSubscript("HarborEngine")
            guard let engine, engine.isUndefined == false, engine.isNull == false else {
                throw EngineError.badResult("HarborEngine global is missing")
            }
            let value: JSValue? = engine.invokeMethod("benchmark", withArguments: [rounds])
            if let failure = self.lastException { throw EngineError.js(failure) }
            guard let dict = value?.toDictionary() as? [String: Any] else {
                throw EngineError.badResult("benchmark() did not return an object")
            }
            return dict
        }
    }

    // MARK: - Swift → JS plumbing

    private func rawCall(_ path: String, argsJSON: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.gone)
                    return
                }
                let token = self.nextCallToken
                self.nextCallToken &+= 1
                self.pendingCalls[token] = continuation

                let invoke: JSValue? = self.context.objectForKeyedSubscript("__harbor_invoke")
                guard let invoke, invoke.isUndefined == false, invoke.isNull == false else {
                    self.pendingCalls.removeValue(forKey: token)
                    continuation.resume(throwing: EngineError.badResult("__harbor_invoke is not installed"))
                    return
                }
                self.lastException = nil
                _ = invoke.call(withArguments: [Double(token), path, argsJSON])
                // A synchronous throw out of the glue (it catches everything, but JSC can
                // still raise, e.g. on a stack overflow) has to settle the call itself.
                if let failure = self.lastException, self.pendingCalls[token] != nil {
                    self.pendingCalls.removeValue(forKey: token)
                    continuation.resume(throwing: EngineError.js(failure))
                }
            }
        }
    }

    private func settleCall(token: Int, ok: Bool, payload: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let continuation = pendingCalls.removeValue(forKey: token) else { return }
        if ok {
            continuation.resume(returning: payload ?? "null")
        } else {
            continuation.resume(throwing: EngineError.js(payload ?? "unknown JS error"))
        }
    }

    private func deliverEvent(type: String, detailArrayJSON: String?) {
        var detail: AnyJSON?
        if let detailArrayJSON, let data = detailArrayJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AnyJSON].self, from: data) {
            detail = decoded.first
        }
        sideLock.lock()
        let handlers = eventHandlers.map(\.fn)
        sideLock.unlock()
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(type, detail) }
        }
    }

    private func invokeGlobal(_ name: String, arguments: [Any]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let function: JSValue? = context.objectForKeyedSubscript(name)
        guard let function, function.isUndefined == false, function.isNull == false else { return }
        lastException = nil
        _ = function.call(withArguments: arguments)
        if let failure = lastException {
            logger.error("\(name, privacy: .public) threw: \(failure, privacy: .public)")
            lastException = nil
        }
    }

    // MARK: - Timers

    private func scheduleTimer(id: Int, delayMs: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        timers[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timers.removeValue(forKey: id)
            self.fireTimer(id)
        }
        timers[id] = item
        let delay = delayMs.isFinite && delayMs > 0 ? delayMs : 0
        queue.asyncAfter(deadline: .now() + delay / 1000, execute: item)
    }

    private func cancelTimer(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        timers.removeValue(forKey: id)?.cancel()
    }

    private func fireTimer(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let fire: JSValue? = context.objectForKeyedSubscript("__harbor_timer_fire")
        guard let fire, fire.isUndefined == false, fire.isNull == false else { return }
        lastException = nil
        _ = fire.call(withArguments: [Double(id)])
        if let failure = lastException {
            logger.error("timer \(id) threw: \(failure, privacy: .public)")
            lastException = nil
        }
    }

    // MARK: - Logging

    private func record(level: String, message: String) {
        switch level {
        case "error": logger.error("\(message, privacy: .public)")
        case "warn": logger.warning("\(message, privacy: .public)")
        case "debug": logger.debug("\(message, privacy: .public)")
        case "info": logger.info("\(message, privacy: .public)")
        default: logger.log("\(message, privacy: .public)")
        }
        appendLog(level, message)
    }

    private func appendLog(_ level: String, _ message: String) {
        sideLock.lock()
        logRing.append("[\(level)] \(message)")
        if logRing.count > Self.logRingCapacity {
            logRing.removeFirst(logRing.count - Self.logRingCapacity)
        }
        sideLock.unlock()
    }

    // MARK: - fetch

    private struct HostRequest {
        var requestId: Int
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var wantsBase64: Bool
        var redirect: RedirectPolicyDelegate.Policy
        var timeout: TimeInterval
    }

    private struct PendingFetch {
        let taskIdentifier: Int
        let task: URLSessionDataTask
        let resolve: JSValue?
        let reject: JSValue?
    }

    private static func parseRequest(_ value: JSValue?) -> Result<HostRequest, FetchParseError> {
        guard let dictionary = value?.toDictionary() as? [String: Any] else {
            return .failure(FetchParseError(message: "fetch: the request is not an object"))
        }
        guard let urlString = dictionary["url"] as? String, !urlString.isEmpty else {
            return .failure(FetchParseError(message: "fetch: the request has no url"))
        }
        guard let url = URL(string: urlString) else {
            return .failure(FetchParseError(message: "fetch: \(urlString) is not a valid URL"))
        }
        let requestId = (dictionary["requestId"] as? NSNumber)?.intValue ?? 0
        let method = ((dictionary["method"] as? String) ?? "GET").uppercased()

        var headers: [String: String] = [:]
        if let raw = dictionary["headers"] as? [String: Any] {
            for (name, value) in raw {
                let lowered = name.lowercased()
                // URLSession owns these two: leaving the JS-side accept-encoding in place
                // would stop it from negotiating and transparently decompressing gzip/br.
                if lowered == "accept-encoding" || lowered == "content-length" { continue }
                if let text = value as? String {
                    headers[lowered] = text
                } else if let number = value as? NSNumber {
                    headers[lowered] = number.stringValue
                }
            }
        }

        var body: Data?
        if let base64 = dictionary["bodyBase64"] as? String {
            guard let decoded = Data(base64Encoded: base64) else {
                return .failure(FetchParseError(message: "fetch: bodyBase64 is not valid base64"))
            }
            body = decoded
        } else if let text = dictionary["body"] as? String {
            body = Data(text.utf8)
        }

        let wantsBase64 = (dictionary["responseType"] as? String) == "base64"
        let redirect = RedirectPolicyDelegate.Policy(rawValue: (dictionary["redirect"] as? String) ?? "follow") ?? .follow
        let milliseconds = (dictionary["timeoutMs"] as? NSNumber)?.doubleValue ?? 30000
        let timeout = milliseconds.isFinite && milliseconds > 0 ? milliseconds / 1000 : 30

        return .success(HostRequest(requestId: requestId, url: url, method: method, headers: headers,
                                    body: body, wantsBase64: wantsBase64, redirect: redirect,
                                    timeout: timeout))
    }

    private func startFetch(_ hostRequest: HostRequest, resolve: JSValue?, reject: JSValue?) {
        dispatchPrecondition(condition: .onQueue(queue))

        var request = URLRequest(url: hostRequest.url)
        request.httpMethod = hostRequest.method
        request.timeoutInterval = hostRequest.timeout
        for (name, value) in hostRequest.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body = hostRequest.body, hostRequest.method != "GET", hostRequest.method != "HEAD" {
            request.httpBody = body
        }

        let requestId = hostRequest.requestId
        let wantsBase64 = hostRequest.wantsBase64
        let fallbackURL = hostRequest.url

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            // URLSession answers on its own queue; everything below touches JSValues.
            self.queue.async {
                self.completeFetch(requestId: requestId, wantsBase64: wantsBase64,
                                   fallbackURL: fallbackURL, data: data, response: response, error: error)
            }
        }
        redirectDelegate.setPolicy(hostRequest.redirect, for: task.taskIdentifier)
        pendingFetches[requestId] = PendingFetch(taskIdentifier: task.taskIdentifier, task: task,
                                                 resolve: resolve, reject: reject)
        task.resume()
    }

    private func abortFetch(_ requestId: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        // The cancellation surfaces as NSURLErrorCancelled in the completion handler, which
        // is where the promise is rejected with an AbortError.
        pendingFetches[requestId]?.task.cancel()
    }

    private func completeFetch(requestId: Int, wantsBase64: Bool, fallbackURL: URL,
                               data: Data?, response: URLResponse?, error: Error?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let entry = pendingFetches.removeValue(forKey: requestId) else { return }
        let redirects = redirectDelegate.finish(entry.taskIdentifier)

        if let error {
            let nsError = error as NSError
            let name: String
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                name = "AbortError"
            } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                name = "TimeoutError"
            } else {
                name = "TypeError"
            }
            rejectFetch(entry.reject, name: name, message: nsError.localizedDescription)
            return
        }
        if redirects.blocked {
            rejectFetch(entry.reject, name: "TypeError",
                        message: "fetch: the response was a redirect and redirect mode is \"error\"")
            return
        }
        guard let http = response as? HTTPURLResponse else {
            rejectFetch(entry.reject, name: "TypeError", message: "fetch: the response was not HTTP")
            return
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = (value as? String) ?? String(describing: value)
        }
        let payload = data ?? Data()
        var result: [String: Any] = [
            "status": http.statusCode,
            "statusText": HarborEngine.statusText(http.statusCode),
            "headers": headers,
            "url": http.url?.absoluteString ?? fallbackURL.absoluteString,
            "redirected": redirects.redirected,
        ]
        if wantsBase64 {
            result["body"] = NSNull()
            result["bodyBase64"] = payload.base64EncodedString()
        } else {
            // Lossy UTF-8, matching Node's Buffer.toString("utf8") in the reference host.
            result["body"] = String(decoding: payload, as: UTF8.self)
            result["bodyBase64"] = NSNull()
        }
        _ = entry.resolve?.call(withArguments: [result])
    }

    private func rejectFetch(_ reject: JSValue?, name: String, message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        // The shim turns {name:"AbortError"|"TimeoutError"} into a DOMException and anything
        // else into a TypeError, which is what a browser fetch does on a transport failure.
        let error: [String: String] = ["name": name, "message": message]
        _ = reject?.call(withArguments: [error])
    }

    // MARK: - Helpers

    private static func asInt(_ value: Double) -> Int? {
        guard value.isFinite, value >= -9007199254740991, value <= 9007199254740991 else { return nil }
        return Int(value)
    }

    private struct AnyEncodableBox: Encodable {
        let value: any Encodable
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    private static func encodeArgs(_ args: [any Encodable]) throws -> String {
        let data = try JSONEncoder().encode(args.map(AnyEncodableBox.init(value:)))
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeJSONArgs(_ args: [AnyJSON]) throws -> String {
        let data = try JSONEncoder().encode(args)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode one JSON value. The value is wrapped in an array first so that top-level
    /// fragments (`null`, a number, a bare string) decode on every Foundation version.
    private static func decodeSingle<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let wrapped = Data(("[" + json + "]").utf8)
        let values: [T]
        do {
            values = try JSONDecoder().decode([T].self, from: wrapped)
        } catch {
            throw EngineError.badResult("could not decode \(T.self) from the engine result: \(error)")
        }
        guard let first = values.first else {
            throw EngineError.badResult("the engine result was empty")
        }
        return first
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return ""
        }
    }

    // MARK: - JS glue

    /// Installed after the bundle. Every Swift → JS call crosses the boundary as JSON
    /// strings: typed arrays and class instances do not survive JSValue bridging.
    private static let glue = #"""
    (function () {
      var g = globalThis;

      g.__harbor_errText = function (e) {
        try {
          if (e === null || e === undefined) return "unknown JS error";
          var msg = (e.message !== undefined && e.message !== null) ? String(e.message) : String(e);
          var stack = e.stack ? String(e.stack) : "";
          if (!stack) return msg;
          if (stack.indexOf(msg) !== -1) return stack;
          return msg + "\n" + stack;
        } catch (_) {
          return "unknown JS error";
        }
      };

      g.__harbor_call = function (path, argsJson) {
        var args = JSON.parse(argsJson);
        var obj = g.HarborEngine;
        var parts = String(path).split(".");
        var pick = function (o, k) { return (o === null || o === undefined) ? undefined : o[k]; };
        var fn = parts.reduce(pick, obj);
        var owner = parts.slice(0, -1).reduce(pick, obj);
        if (typeof fn !== "function") throw new Error("no engine function " + path);
        return Promise.resolve(fn.apply(owner, args)).then(function (v) {
          return JSON.stringify(v === undefined ? null : v);
        });
      };

      g.__harbor_invoke = function (token, path, argsJson) {
        try {
          Promise.resolve(g.__harbor_call(path, argsJson)).then(
            function (json) { g.__harbor_settle(token, true, typeof json === "string" ? json : "null"); },
            function (e) { g.__harbor_settle(token, false, g.__harbor_errText(e)); }
          );
        } catch (e) {
          g.__harbor_settle(token, false, g.__harbor_errText(e));
        }
      };

      g.__harbor_emit = function (type, detailArrayJson) {
        var detail = undefined;
        if (typeof detailArrayJson === "string") {
          var a = JSON.parse(detailArrayJson);
          if (a && a.length > 0) detail = a[0];
        }
        return g.HarborEngine.runtime.emitEvent(String(type), detail);
      };

      g.__harbor_sync = function (key, value) {
        var v = (value === null || value === undefined) ? null : String(value);
        return g.HarborEngine.runtime.syncStorage(String(key), v);
      };

      g.__harbor_event_unsubscribe = g.HarborEngine.runtime.onEvent(function (type, detail) {
        if (typeof g.__harbor_event !== "function") return;
        var json = null;
        try { json = JSON.stringify([detail === undefined ? null : detail]); } catch (_) { json = null; }
        g.__harbor_event(String(type), json);
      });
    })();
    """#
}

/// Honours `redirect: "manual" | "error"` from the host contract. Kept apart from the engine
/// because `URLSession` retains its delegate for as long as the session lives.
private final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate {
    enum Policy: String { case follow, manual, error }

    private let lock = NSLock()
    private var policies: [Int: Policy] = [:]
    private var redirected: Set<Int> = []
    private var blocked: Set<Int> = []

    func setPolicy(_ policy: Policy, for taskIdentifier: Int) {
        lock.lock()
        policies[taskIdentifier] = policy
        lock.unlock()
    }

    /// Reads and clears what happened to this task.
    func finish(_ taskIdentifier: Int) -> (redirected: Bool, blocked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let wasRedirected = redirected.contains(taskIdentifier)
        let wasBlocked = blocked.contains(taskIdentifier)
        policies.removeValue(forKey: taskIdentifier)
        redirected.remove(taskIdentifier)
        blocked.remove(taskIdentifier)
        return (wasRedirected, wasBlocked)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let identifier = task.taskIdentifier
        lock.lock()
        let policy = policies[identifier] ?? .follow
        switch policy {
        case .follow: redirected.insert(identifier)
        case .error: blocked.insert(identifier)
        case .manual: break
        }
        lock.unlock()
        // nil hands the 3xx back as the response instead of following it, which is exactly
        // what "manual" wants; for "error" the `blocked` flag turns it into a rejection.
        completionHandler(policy == .follow ? request : nil)
    }
}
