import CryptoKit
import Foundation

@main struct HyRuntimeAvailabilityTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hy-gate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        let report = root.appendingPathComponent("report.json")
        func check(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        func inspect() -> HyRuntimeAvailability.Assessment {
            HyRuntimeAvailability.inspect(helperURL: helper, reportURL: report)
        }
        check(!inspect().isVerified, "missing helper is unavailable")
        let bytes = Data("#!/bin/sh\nexit 0\n".utf8)
        try bytes.write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        check(!inspect().isVerified, "a helper alone cannot unlock local mode")
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let runs: [[String: Any]] = ["en-zh", "zh-en"].map {
            ["direction": $0, "audio_seconds": 600.5, "realtime_factor": 0.6,
             "max_queue_seconds": 1.2, "complete": true]
        }
        let valid: [String: Any] = [
            "schema_version": 1, "passed": true,
            "runtime_commit": HyRuntimeAvailability.runtimeCommit,
            "model_sha256": HyRuntimeAvailability.modelSHA256,
            "bundled_helper_sha256": hash,
            "checks": ["streaming_before_eof": true, "rollover": true,
                       "tail_recovery": true, "cli_parity": true,
                       "content_anchors": true, "cancel_and_restart": true, "noise_floor": true], "runs": runs]
        func write(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: report)
        }
        try write(valid)
        check(inspect().isVerified && inspect().executableURL == helper, "verified exact executable is usable")
        for key in ["passed", "schema_version", "runtime_commit", "model_sha256", "bundled_helper_sha256", "checks", "runs"] {
            var changed = valid; changed.removeValue(forKey: key)
            try write(changed)
            check(!inspect().isVerified, "missing \(key) must fail closed")
        }
        var changed = valid
        var withoutNoiseCheck = valid["checks"] as! [String: Bool]
        withoutNoiseCheck["noise_floor"] = nil
        changed["checks"] = withoutNoiseCheck
        try write(changed)
        check(!inspect().isVerified, "a report from before the noise-floor check cannot unlock local mode")
        changed = valid
        changed["runs"] = [runs[0]]
        try write(changed)
        check(!inspect().isVerified, "both directions must pass")
        for (key, value) in [("audio_seconds", 599.0), ("realtime_factor", 1.1), ("max_queue_seconds", 11.0)] {
            var invalidRuns = runs; invalidRuns[1][key] = value
            changed = valid; changed["runs"] = invalidRuns; try write(changed)
            check(!inspect().isVerified, "invalid sustained run metric \(key) must fail")
        }
        try write(valid)
        try Data("changed executable".utf8).write(to: helper)
        check(!inspect().isVerified, "rebuilding the helper invalidates old evidence")
        print("PASS: Hy runtime release gate, required evidence, both sustained directions and executable integrity")
    }
}
