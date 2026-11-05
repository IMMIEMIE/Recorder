import CryptoKit
import Foundation

/// A local runtime is offered only when the exact bundled executable passed the
/// real-model validation. Mock tests and a successful compilation cannot unlock it.
enum HyRuntimeAvailability {
    static let runtimeCommit = "d38e66aac7bb18101f417338b795e4546a5a1a59"
    static let modelSHA256 = "26c87f0a5f6409f3a57f8c4d2a49d58ad0f5c0753141643789e73564339cedbc"

    struct Assessment {
        let executableURL: URL?
        let isVerified: Bool
        let reason: String
    }

    private static let bundled: Assessment = {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HySimulMTHelper")
        let report = Bundle.main.resourceURL?.appendingPathComponent("hy-runtime-validation.json")
        return inspect(helperURL: helper, reportURL: report)
    }()

    static var executableURL: URL? { bundled.executableURL }
    static var isVerified: Bool { bundled.isVerified }
    static var unavailableReason: String { bundled.reason }

    static func inspect(helperURL: URL, reportURL: URL?) -> Assessment {
        func unavailable(_ reason: String) -> Assessment {
            Assessment(executableURL: nil, isVerified: false, reason: reason)
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return unavailable("此版本尚未包含已验证的 Hy-SimulMT 本地推理程序。")
        }
        guard let reportURL, let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(ValidationReport.self, from: data),
              report.schemaVersion == 1, report.passed,
              report.runtimeCommit == runtimeCommit, report.modelSHA256 == modelSHA256,
              report.checks.values.allSatisfy({ $0 }),
              ["en-zh", "zh-en"].allSatisfy({ direction in
                  report.runs.contains { run in
                      run.direction == direction && run.complete && run.audioSeconds >= 600 &&
                      run.realtimeFactor.isFinite && run.realtimeFactor > 0 && run.realtimeFactor <= 1 &&
                      run.maxQueueSeconds.isFinite && (0...10).contains(run.maxQueueSeconds)
                  }
              }) else {
            return unavailable("Hy-SimulMT 本地推理尚未通过双向连续实时验证，暂不可启用。")
        }
        guard report.checks["streaming_before_eof"] == true,
              report.checks["rollover"] == true,
              report.checks["tail_recovery"] == true,
              report.checks["cli_parity"] == true,
              report.checks["content_anchors"] == true,
              report.checks["cancel_and_restart"] == true,
              report.checks["noise_floor"] == true,
              let expected = report.bundledHelperSHA256,
              expected.count == 64,
              (try? sha256(helperURL)) == expected else {
            return unavailable("本地推理程序与验证记录不匹配，请重新构建经过验证的版本。")
        }
        return Assessment(executableURL: helperURL, isVerified: true, reason: "")
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct ValidationReport: Decodable {
        let schemaVersion: Int
        let passed: Bool
        let runtimeCommit: String
        let modelSHA256: String
        let bundledHelperSHA256: String?
        let checks: [String: Bool]
        let runs: [Run]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", passed, runtimeCommit = "runtime_commit"
            case modelSHA256 = "model_sha256", bundledHelperSHA256 = "bundled_helper_sha256", checks, runs
        }
    }

    private struct Run: Decodable {
        let direction: String
        let audioSeconds: Double
        let realtimeFactor: Double
        let complete: Bool
        let maxQueueSeconds: Double
        enum CodingKeys: String, CodingKey {
            case direction, audioSeconds = "audio_seconds", realtimeFactor = "realtime_factor"
            case complete, maxQueueSeconds = "max_queue_seconds"
        }
    }
}
