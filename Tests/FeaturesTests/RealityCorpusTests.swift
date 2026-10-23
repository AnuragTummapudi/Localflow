import XCTest
import Shared
@testable import CommandMode

@MainActor final class RealityCorpusTests: LocalSettingsTestCase {
    private struct Catalog: ApplicationCatalog {
        func installedApplications() -> [ApplicationMatch] {
            ["Notes", "Safari", "Chrome", "Preview", "Calculator", "Mail", "Finder", "Calendar",
             "Visual Studio Code", "Photo Booth", "Pages", "Numbers", "Reminders", "Music", "Spotify", "Terminal"].map {
                ApplicationMatch(name: $0, bundleIdentifier: "fixture." + $0, url: nil, confidence: 1)
            }
        }
    }
    func testFrozenCorpusAgainstActualDeterministicEngineWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LOCALFLOW_REALITY_CORPUS"],
              let output = ProcessInfo.processInfo.environment["LOCALFLOW_REALITY_DETERMINISTIC_OUTPUT"] else {
            throw XCTSkip("Opt-in frozen LocalFlow decision corpus export; no real native tools.")
        }
        let commands = CommandMode(catalog: Catalog())
        let engine = DeterministicDecisionEngine(commands: commands)
        var results: [[String: Any]] = []
        for split in ["calibration", "test"] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(split + ".jsonl")
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let state = try XCTUnwrap(row["state"] as? [String: Any])
                let text = try XCTUnwrap(state["utterance"] as? String)
                let final = try XCTUnwrap(state["is_final"] as? Bool)
                let start = ProcessInfo.processInfo.systemUptime
                let decisions = try await engine.evaluate(DecisionState(text: text, isFinal: final))
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let intent = try XCTUnwrap(decisions.intent)
                let risk = try XCTUnwrap(decisions.risk)
                let more = try XCTUnwrap(decisions.requiresMoreSpeech)
                let name: String
                switch intent.value {
                case .switchApplication: name = "focus_application"
                case .closeApplication: name = "quit_application"
                default: name = intent.value.rawValue
                }
                let ambiguous: Bool
                if case .needsConfirmation = commands.resolve(text) { ambiguous = true } else { ambiguous = false }
                results.append(["id": row["id"]!, "split": split, "labels": row["labels"]!,
                    "predictions": ["intent": name, "risk": risk.value.rawValue, "more_speech": more.value,
                                    "command": intent.value != .dictation, "ambiguous": ambiguous],
                    "confidence": ["intent": intent.confidence.value, "risk": risk.confidence.value,
                                   "more_speech": more.confidence.value], "milliseconds": elapsed])
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        XCTAssertEqual(results.filter { $0["split"] as? String == "test" }.count, 72)
    }
}
