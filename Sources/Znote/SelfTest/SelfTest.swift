import Foundation

/// Agent self-test mode — driven by `selftest/run.sh`.
///
/// Active only when both `ZNOTE_SELFTEST=<scenario>` and
/// `ZNOTE_SELFTEST_DIR=<dir>` are set. main.swift then runs this *instead of*
/// starting the menu-bar app: no status item, no event tap, no microphone, no
/// paste. Preferences go to a throwaway defaults domain and the history
/// database lives in `<dir>`, so the user's data is never read or written.
///
/// Each scenario writes `<dir>/report.json`:
///   logic     settings, hotkey bindings, silence gate, hallucination filter, i18n
///   history   SQLite store against a seeded old-schema database
///   hotkeys   KeyMonitor's gesture state machine, fed synthetic events
///   editor    screenshot annotation + History hover preview, rendered off screen
///   voice     seeded WAVs through the real WhisperService
///   translate TranslationService against Google (needs network)
///   bench     character error rate + speed of one model (a measurement, not a verdict)
enum SelfTest {
    struct Request {
        let scenario: String
        let dir: URL
    }

    static let request: Request? = {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["ZNOTE_SELFTEST"], !scenario.isEmpty,
              let dir = env["ZNOTE_SELFTEST_DIR"], !dir.isEmpty else { return nil }
        return Request(scenario: scenario, dir: URL(fileURLWithPath: dir, isDirectory: true))
    }()

    // MARK: - Isolated preferences

    static let defaultsDomain = "com.znote.app.selftest"

    /// A defaults store of its own, emptied before use. Built without the
    /// app's bundle domain in its search list, so nothing the user has saved
    /// leaks in.
    static func isolatedDefaults() -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
        return UserDefaults(suiteName: defaultsDomain) ?? .standard
    }

    // MARK: - Report

    struct Step: Encodable {
        let name: String
        let ok: Bool
        let ms: Int
        /// Set when a failure is an already-documented bug: the step still
        /// shows as failing but doesn't fail the run.
        let known: String?
        let detail: [String: String]
    }

    struct Report: Encodable {
        let scenario: String
        var passed = false
        var elapsedMs = 0
        var env: [String: String] = [:]
        var steps: [Step] = []
        var errors: [String] = []

        mutating func step(_ name: String, ok: Bool, ms: Int = 0, known: String? = nil,
                           _ detail: [String: String] = [:]) {
            steps.append(Step(name: name, ok: ok, ms: ms, known: ok ? nil : known, detail: detail))
        }

        /// Step that passes when `got == want`; records both on failure.
        mutating func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            step(name, ok: ok, ok ? ["value": "\(got)"] : ["got": "\(got)", "want": "\(want)"])
        }
    }

    // MARK: - Run

    /// Runs the scenario, writes the report, returns the process exit code.
    static func run(_ request: Request) async -> Int32 {
        let started = Date()
        var report = Report(scenario: request.scenario)
        report.env["binary"] = Bundle.main.executablePath ?? "?"

        switch request.scenario {
        case "logic": runLogic(&report)
        case "history": runHistory(request, &report)
        case "hotkeys": await runHotkeys(&report)
        case "editor":
            // AppKit views and windows must be made on the main thread.
            let scenario = report.scenario
            let onMain: Report = await MainActor.run {
                var local = Report(scenario: scenario)
                runEditor(request, &local)
                return local
            }
            report.steps += onMain.steps
            report.errors += onMain.errors
        case "voice": await runVoice(request, &report)
        case "bench": await runBench(request, &report)
        case "translate": runTranslate(&report)
        default: report.errors.append("unknown scenario '\(request.scenario)'")
        }

        report.passed = report.errors.isEmpty && !report.steps.isEmpty
            && report.steps.allSatisfy { $0.ok || $0.known != nil }
        report.elapsedMs = ms(since: started)

        // Leave no test preferences behind.
        UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            // Atomic so the polling runner never reads a half-written file.
            try encoder.encode(report).write(to: request.dir.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            log("SelfTest: failed to write report — \(error)")
            return 2
        }
        log("SelfTest: \(report.passed ? "PASSED" : "FAILED") in \(report.elapsedMs) ms")
        return report.passed ? 0 : 1
    }

    // MARK: - Helpers

    /// Lowercase and keep only letters and digits, so assertions ignore the
    /// punctuation, spacing and casing that vary from run to run.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func ms(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}
