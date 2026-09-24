import Foundation

/// The optional `wsOpen / wsSend / wsClose` host functions behind engine/shims/websocket.js:
/// upstream's Watch Together client (lib/together/client.ts) talks to its relay through them.
///
/// One `URLSessionWebSocketTask` per socket id. Every event goes back through `deliver`, which
/// the engine hops onto its own queue before touching JavaScript. The JS side expects, per
/// socket, "open" once, any number of "message", and exactly one "close" (after an "error"
/// when the connection failed), the same order a browser WebSocket fires them in.
final class EngineSockets: NSObject, URLSessionWebSocketDelegate {
    typealias Deliver = (_ id: Int, _ kind: String, _ data: String?) -> Void

    private let deliver: Deliver
    private let lock = NSLock()
    private var tasks: [Int: URLSessionWebSocketTask] = [:]
    private var idByTask: [Int: Int] = [:]
    private var closeCodes: [Int: Int] = [:]
    private var session: URLSession!

    init(deliver: @escaping Deliver) {
        self.deliver = deliver
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func open(url: String, id: Int) {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            deliver(id, "error", "bad WebSocket URL")
            deliver(id, "close", Self.closeJSON(code: 1006, reason: "", clean: false))
            return
        }
        let task = session.webSocketTask(with: u)
        // Relay frames are small; room state with an inline avatar can reach ~600 KB (client.ts AVATAR_MAX_CHARS).
        task.maximumMessageSize = 4 * 1024 * 1024
        lock.lock()
        tasks[id] = task
        idByTask[task.taskIdentifier] = id
        lock.unlock()
        task.resume()
        receive(task, id: id)
    }

    func send(id: Int, text: String) {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.deliver(id, "error", error.localizedDescription) }
        }
    }

    func close(id: Int, code: Int, reason: String) {
        lock.lock()
        let task = tasks[id]
        // A close can race a socket that already finished here; don't leave its code behind (review 18).
        if task != nil { closeCodes[id] = code } else { closeCodes.removeValue(forKey: id) }
        lock.unlock()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }

    private func receive(_ task: URLSessionWebSocketTask, id: Int) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success(.string(let text)):
                self.deliver(id, "message", text)
                self.receive(task, id: id)
            case .success(.data(let data)):
                // The Together relay speaks JSON text only (lib/together/protocol.ts); a binary frame
                // is handed over as UTF-8 text, not a Blob/ArrayBuffer (the shim has no binary path).
                self.deliver(id, "message", String(decoding: data, as: UTF8.self))
                self.receive(task, id: id)
            case .success:
                self.receive(task, id: id)
            case .failure:
                // The delegate reports the close (with its code); nothing more to read.
                break
            }
        }
    }

    /// Reports "close" once and forgets the socket.
    private func finish(taskIdentifier: Int, code: Int?, reason: String, clean: Bool, error: String?) {
        lock.lock()
        guard let id = idByTask.removeValue(forKey: taskIdentifier) else { lock.unlock(); return }
        tasks.removeValue(forKey: id)
        let asked = closeCodes.removeValue(forKey: id)
        lock.unlock()
        if let error, !clean { deliver(id, "error", error) }
        deliver(id, "close", Self.closeJSON(code: code ?? asked ?? 1006, reason: reason, clean: clean))
    }

    private static func closeJSON(code: Int, reason: String, clean: Bool) -> String {
        let obj: [String: Any] = ["code": code, "reason": reason, "wasClean": clean]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        lock.lock()
        let id = idByTask[webSocketTask.taskIdentifier]
        lock.unlock()
        if let id { deliver(id, "open", nil) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        finish(taskIdentifier: webSocketTask.taskIdentifier, code: closeCode.rawValue, reason: text, clean: true, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A close we asked for arrives here as a cancellation: clean, with the code we sent.
        lock.lock()
        let id = idByTask[task.taskIdentifier]
        let asked = id.flatMap { closeCodes[$0] }
        lock.unlock()
        let cancelled = (error as? URLError)?.code == .cancelled
        finish(taskIdentifier: task.taskIdentifier, code: asked, reason: "", clean: asked != nil && (error == nil || cancelled),
               error: error?.localizedDescription ?? "connection closed")
    }
}
