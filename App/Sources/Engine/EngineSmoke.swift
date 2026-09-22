import Foundation

/// A quick end-to-end check of the engine host: boot, `runtime.selfTest()` (URL, storage,
/// crypto, Intl, timers and a live fetch) and one real catalog call through the bundle.
/// Returns human-readable lines for a spike screen; it never throws.
enum EngineSmoke {
    static func run() async -> [String] {
        var lines: [String] = []

        let bootStart = Date()
        let engine: HarborEngine
        do {
            engine = HarborEngine.shared
        } catch {
            return ["engine failed to start: \(error)"]
        }
        lines.append(line("boot", since: bootStart))

        // --- runtime.selfTest() ---------------------------------------------------------
        let selfTestStart = Date()
        do {
            let result = try await engine.selfTest()
            let ok = result["ok"]?.bool ?? false
            lines.append("\(line("selfTest", since: selfTestStart)) — ok=\(ok)")
            if case .object(let checks)? = result["checks"] {
                for name in checks.keys.sorted() {
                    lines.append("  \(name): \(describe(checks[name]))")
                }
            }
        } catch {
            lines.append("selfTest failed: \(error)")
        }

        // --- cinemeta.topMovies() -------------------------------------------------------
        let cinemetaStart = Date()
        do {
            let metas = try await engine.callJSON("cinemeta.topMovies", [])
            let names = (metas.array ?? []).prefix(3).map { describe($0["name"]) }
            lines.append("\(line("cinemeta.topMovies", since: cinemetaStart)) — \(metas.array?.count ?? 0) metas")
            for name in names { lines.append("  \(name)") }
        } catch {
            lines.append("cinemeta.topMovies failed: \(error)")
        }

        // --- benchmark ------------------------------------------------------------------
        do {
            let result = try engine.benchmark(rounds: 50)
            lines.append("benchmark(50): \(result["streams"] ?? 0) streams, kept \(result["kept"] ?? 0), \(result["ms"] ?? 0) ms")
        } catch {
            lines.append("benchmark failed: \(error)")
        }

        let logs = engine.recentLogs
        if !logs.isEmpty { lines.append("engine logged \(logs.count) line(s); last: \(logs[logs.count - 1])") }
        return lines
    }

    private static func line(_ label: String, since start: Date) -> String {
        String(format: "%@ in %.0f ms", label, Date().timeIntervalSince(start) * 1000)
    }

    private static func describe(_ value: AnyJSON?) -> String {
        guard let value else { return "—" }
        switch value {
        case .string(let text): return text
        case .number(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .null: return "null"
        case .array(let items): return "[\(items.count) items]"
        case .object(let fields): return "{\(fields.count) keys}"
        }
    }
}
