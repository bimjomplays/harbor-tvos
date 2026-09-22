import Foundation
import JavaScriptCore

/// Upstream Harbor's framework-free logic, bundled by `engine/build.mjs`, running in JavaScriptCore.
final class HarborEngine {
    enum Failure: Error { case bundleMissing, evaluation(String), badResult }

    private let context: JSContext

    init() throws {
        guard let url = Bundle.main.url(forResource: "harbor-engine", withExtension: "js") else { throw Failure.bundleMissing }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let context = JSContext() else { throw Failure.evaluation("no JSContext") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let log: @convention(block) (String) -> Void = { NSLog("[engine] %@", $0) }
        context.setObject(["log": log, "warn": log, "error": log], forKeyedSubscript: "console" as NSString)
        context.evaluateScript(source)
        if let failure { throw Failure.evaluation(failure) }
        self.context = context
    }

    func benchmark(rounds: Int) throws -> [String: Any] {
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let value = context.objectForKeyedSubscript("HarborEngine")?.invokeMethod("benchmark", withArguments: [rounds])
        if let failure { throw Failure.evaluation(failure) }
        guard let dict = value?.toDictionary() as? [String: Any] else { throw Failure.badResult }
        return dict
    }
}
