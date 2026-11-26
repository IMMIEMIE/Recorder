import Foundation

// APIKeyFileStore (issue #50): file permissions, round trip, cache, corrupt files and the one-time legacy
// Keychain migration. Every store is rooted in a temporary directory and uses a fake legacy source, so the
// real home directory and the login Keychain are never touched.

struct KeyTestError: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw KeyTestError(description: message) }
}

/// Fake legacy Keychain: counts reads and records deletions.
final class FakeLegacy {
    var items: [String: LegacyKeyResult]
    var reads: [String] = []
    var deleted: [String] = []
    init(_ items: [String: LegacyKeyResult]) { self.items = items }
    var source: LegacyKeySource {
        LegacyKeySource(read: { [self] account in reads.append(account); return items[account] ?? .missing },
                        delete: { [self] account in deleted.append(account); items[account] = nil })
    }
}

func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

func message(_ error: Error) -> String { (error as? AIError)?.errorDescription ?? "\(error)" }

@main struct APIKeyStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default

        // Default location is under the app data root, not a Keychain.
        try expect(APIKeyStore.shared.directory.path.hasSuffix("Library/Application Support/LocalRecorder/APIKeys"), "default directory")

        // Round trip, permissions, atomic write, account strings with ':' and '/'.
        let dir = root.appendingPathComponent("basic/APIKeys")
        let store = APIKeyFileStore(directory: dir)
        let live = "livetranslate:wss://example.com/api-ws/v1/realtime"
        try expect(try store.read(live) == nil, "missing key reads nil")
        try expect(!manager.fileExists(atPath: dir.path), "reading creates nothing")
        try store.save("sk-live", account: live)
        try store.save("sk-asr", account: "asr:https://api.example.com/v1")
        try expect(try permissions(dir) == 0o700, "directory is 0700")
        try expect(try permissions(store.file) == 0o600, "file is 0600")
        try expect(try manager.contentsOfDirectory(atPath: dir.path) == ["keys.json"], "no temporary files left")
        try expect(try store.read(live) == "sk-live", "round trip")
        let reopened = APIKeyFileStore(directory: dir)
        try expect(try reopened.read(live) == "sk-live" && reopened.read("asr:https://api.example.com/v1") == "sk-asr", "new process reads file")
        try store.save("sk-live-2", account: live)
        try expect(try store.read(live) == "sk-live-2", "save replaces key in memory")
        try expect(try APIKeyFileStore(directory: dir).read(live) == "sk-live-2", "save replaces key on disk")
        print("PASS: round trip, 0700/0600 permissions, atomic file")

        // A loose directory gets tightened on the next write.
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try store.save("sk-live-3", account: live)
        try expect(try permissions(dir) == 0o700 && permissions(store.file) == 0o600, "permissions restored on write")

        // The file is read once per process: outside edits are not seen until a new store loads it.
        let other = Data(#"{"schema_version":1,"keys":{"x":"outside"},"legacy_checked":[],"legacy_declined":false}"#.utf8)
        try other.write(to: store.file)
        try expect(try store.read(live) == "sk-live-3" && store.read("x") == nil, "cached contents survive outside edits")
        try expect(try APIKeyFileStore(directory: dir).read("x") == "outside", "new store loads the file")
        print("PASS: in-memory cache")

        // Remove.
        let removeStore = APIKeyFileStore(directory: dir)
        try removeStore.remove("x")
        try expect(try removeStore.read("x") == nil, "removed in memory")
        try expect(try APIKeyFileStore(directory: dir).read("x") == nil, "removed on disk")
        try removeStore.remove("never-saved")
        print("PASS: remove")

        // Corrupt and newer-schema files: reads report it, a save keeps a backup and starts over.
        for (name, body) in [("corrupt", "not json"), ("newer", #"{"schema_version":2,"keys":{"a":"b"}}"#)] {
            let bad = root.appendingPathComponent(name)
            try manager.createDirectory(at: bad, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: bad.appendingPathComponent("keys.json"))
            let damaged = APIKeyFileStore(directory: bad)
            do { _ = try damaged.read("a"); throw KeyTestError(description: "\(name) file must fail to read") }
            catch let error as AIError { try expect(message(error) == "已保存的 API Key 文件已损坏，请重新保存 API Key", "\(name) message: \(message(error))") }
            try damaged.save("fresh", account: "a")
            try expect(try damaged.read("a") == "fresh" && APIKeyFileStore(directory: bad).read("a") == "fresh", "\(name) replaced by save")
            try expect(try Data(contentsOf: bad.appendingPathComponent("keys.corrupt.json")) == Data(body.utf8), "\(name) backup kept")
            try expect(try permissions(bad.appendingPathComponent("keys.json")) == 0o600, "\(name) new file 0600")
        }
        let removeBad = root.appendingPathComponent("remove-corrupt")
        try manager.createDirectory(at: removeBad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: removeBad.appendingPathComponent("keys.json"))
        try APIKeyFileStore(directory: removeBad).remove("a")
        try expect(try APIKeyFileStore(directory: removeBad).read("a") == nil, "remove works over a corrupt file")
        print("PASS: corrupt and newer-schema files")

        // Unwritable location: save reports the code, nothing is cached as saved.
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let blocked = APIKeyFileStore(directory: blocker.appendingPathComponent("APIKeys"))
        do { try blocked.save("k", account: "a"); throw KeyTestError(description: "save under a file must fail") }
        catch let error as AIError { try expect(message(error).hasPrefix("无法保存 API Key（"), "save error: \(message(error))") }
        try expect(try blocked.read("a") == nil, "failed save is not cached")
        print("PASS: write failure")

        // Migration: a legacy key moves into the file once and its Keychain item is deleted.
        let migrate = root.appendingPathComponent("migrate")
        let legacy = FakeLegacy(["a": .found("legacy-a"), "r": .found("legacy-r"), "s": .found("legacy-s"), "e": .found("")])
        let migrating = APIKeyFileStore(directory: migrate, legacy: legacy.source)
        try expect(try migrating.read("a") == "legacy-a", "legacy key returned")
        try expect(legacy.deleted == ["a"], "legacy item deleted after migration")
        try expect(try migrating.read("a") == "legacy-a" && legacy.reads == ["a"], "no second legacy read")
        try expect(try APIKeyFileStore(directory: migrate).read("a") == "legacy-a", "migrated key is in the file")
        try expect(try permissions(migrate) == 0o700 && permissions(migrating.file) == 0o600, "migration writes 0700/0600")
        // A missing account is looked up once, ever.
        try expect(try migrating.read("m") == nil && migrating.read("m") == nil, "missing legacy key")
        try expect(try APIKeyFileStore(directory: migrate, legacy: legacy.source).read("m") == nil, "missing in new process")
        try expect(legacy.reads == ["a", "m"], "missing account looked up once across processes: \(legacy.reads)")
        // Removing or saving an account first supersedes its legacy item.
        try migrating.remove("r")
        try expect(try migrating.read("r") == nil, "removed key does not come back from the Keychain")
        try migrating.save("new-s", account: "s")
        try expect(try migrating.read("s") == "new-s", "saved key wins over legacy")
        try expect(try migrating.read("e") == nil, "empty legacy item reads as missing")
        try expect(legacy.reads == ["a", "m", "e"], "no lookups for removed or saved accounts: \(legacy.reads)")
        print("PASS: one-time legacy migration")

        // Denying the Keychain prompt (-128) is not an error and stops every further lookup, across processes.
        let denyDir = root.appendingPathComponent("deny")
        let denying = FakeLegacy(["x": .declined, "y": .found("legacy-y")])
        let denyStore = APIKeyFileStore(directory: denyDir, legacy: denying.source)
        try expect(try denyStore.read("x") == nil, "declined reads as missing without throwing")
        try expect(try denyStore.read("x") == nil && denyStore.read("y") == nil, "no prompt after a deny")
        try expect(try APIKeyFileStore(directory: denyDir, legacy: denying.source).read("y") == nil, "deny persists")
        try expect(denying.reads == ["x"] && denying.deleted.isEmpty, "only one prompt: \(denying.reads)")
        try denyStore.save("typed-again", account: "x")
        try expect(try APIKeyFileStore(directory: denyDir).read("x") == "typed-again", "user can enter the key again")
        print("PASS: denied Keychain prompt")

        // A Keychain that cannot prompt (locked / no UI) is skipped for the rest of the process, retried later.
        let lockedDir = root.appendingPathComponent("locked")
        let locked = FakeLegacy(["p": .unavailable, "q": .unavailable])
        let lockedStore = APIKeyFileStore(directory: lockedDir, legacy: locked.source)
        try expect(try lockedStore.read("p") == nil && lockedStore.read("q") == nil && locked.reads == ["p"], "unavailable stops lookups")
        locked.items["p"] = .found("legacy-p")
        try expect(try APIKeyFileStore(directory: lockedDir, legacy: locked.source).read("p") == "legacy-p", "retried in a new process")
        // Failed errors are recorded like a miss.
        let failDir = root.appendingPathComponent("fail")
        let failing = FakeLegacy(["f": .failed])
        try expect(try APIKeyFileStore(directory: failDir, legacy: failing.source).read("f") == nil, "failed reads as missing")
        try expect(try APIKeyFileStore(directory: failDir, legacy: failing.source).read("f") == nil && failing.reads == ["f"], "failed not retried")
        print("PASS: unavailable and failed Keychain")

        // If the file cannot be written, the migrated key is used for this process but stays in the Keychain.
        let stuck = FakeLegacy(["k": .found("legacy-k")])
        let stuckStore = APIKeyFileStore(directory: blocker.appendingPathComponent("Stuck"), legacy: stuck.source)
        try expect(try stuckStore.read("k") == "legacy-k" && stuckStore.read("k") == "legacy-k", "key usable without a file")
        try expect(stuck.reads == ["k"] && stuck.deleted.isEmpty, "legacy item kept when the file was not written")
        print("PASS: migration without a writable file")

        // Concurrent use from several threads.
        let shared = APIKeyFileStore(directory: root.appendingPathComponent("threads"), legacy: FakeLegacy([:]).source)
        let errors = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            do {
                try shared.save("key-\(i)", account: "acct:\(i)/x")
                guard try shared.read("acct:\(i)/x") == "key-\(i)" else { throw KeyTestError(description: "read back \(i)") }
                _ = try shared.read("acct:\((i + 1) % 64)/x")
            } catch { errors.add("\(error)") }
        }
        try expect(errors.count == 0, "concurrent errors: \(errors)")
        let after = APIKeyFileStore(directory: root.appendingPathComponent("threads"))
        try expect(try (0..<64).allSatisfy { try after.read("acct:\($0)/x") == "key-\($0)" }, "all concurrent saves on disk")
        print("PASS: concurrent saves and reads")

        // The static API goes through the injectable shared store.
        let previous = APIKeyStore.shared
        defer { APIKeyStore.shared = previous }
        APIKeyStore.shared = APIKeyFileStore(directory: root.appendingPathComponent("static"))
        try APIKeyStore.save("k", endpoint: "livetranslate:wss://a/b")
        try expect(try APIKeyStore.read(endpoint: "livetranslate:wss://a/b") == "k", "static read")
        try APIKeyStore.remove(endpoint: "livetranslate:wss://a/b")
        try expect(try APIKeyStore.read(endpoint: "livetranslate:wss://a/b") == nil, "static remove")
        print("PASS: APIKeyStore facade")
    }
}
