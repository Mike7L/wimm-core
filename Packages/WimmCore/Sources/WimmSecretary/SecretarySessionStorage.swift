import CryptoKit
import Darwin
import Foundation
import SQLite3
import os

/// File-session state is immutable evidence between saves. Keep a small atomic manifest
/// at the legacy path, with shared, compressed binary data in a transactional store.
/// This is archive storage, not the note library or a search index.
enum SecretarySessionStorage {
    static let format = "wimm-secretary-content-v1"

    struct Manifest: Codable {
        let storage: String
        let payload: Data
        let payloadSHA256: String
        let stateSHA256: String
        let references: [String]
        let summary: Summary?
    }

    struct Summary: Codable {
        let runID: String
        let phase: String
        let document: URL
        let admittedSourceCount: Int
        let committed: Bool?
        let findings: [String]?
        let storedSources: [String]?
    }

    private struct Reference: Codable, Sendable {
        let sha256: String
        let bytes: Int
        let mapSHA256: String?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func directory(for session: URL) -> URL {
        session.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SecretarySessionArchive", isDirectory: true)
    }

    static func checkpointDirectory(document: URL, archive: URL) -> URL {
        archive.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(hash(Data(document.standardizedFileURL.path.utf8)), isDirectory: true)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func canonical(_ state: SecretaryPacketFiles.State) throws -> Data {
        try encoder().encode(state)
    }

    static func checkpointData(from file: URL) throws -> Data {
        let expected = file.deletingPathExtension().deletingPathExtension().lastPathComponent
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw Failure("Use the original content-addressed checkpoint filename.")
        }
        let full = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
        guard hash(full) == expected else { throw Failure("Secretary checkpoint checksum mismatch.") }
        _ = try JSONDecoder().decode(SecretaryPacketFiles.State.self, from: full)
        return full
    }

    static func load(from session: URL) throws -> SecretaryPacketFiles.State {
        let root = directory(for: session)
        return try locked(root, exclusive: false) {
            // Read the manifest inside the same lock as its chunks, so collection
            // cannot remove an old version between these two reads.
            let bytes = try Data(contentsOf: session)
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else {
                return try JSONDecoder().decode(SecretaryPacketFiles.State.self, from: bytes)
            }
            guard manifest.storage == format else { throw Failure("Unknown secretary session storage format.") }
            let database = try Database(root: root, create: false)
            return try decode(manifest, database: database)
        }
    }

    static func save(_ state: SecretaryPacketFiles.State, to session: URL) throws {
        let root = directory(for: session)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try locked(root) {
            let database = try Database(root: root, create: true)
            let original = try canonical(state)
            let stateHash = hash(original)
            try database.execute("BEGIN IMMEDIATE")
            do {
                let references = OSAllocatedUnfairLock(initialState: Set<String>())
                let compactEncoder = encoder()
                compactEncoder.dataEncodingStrategy = .custom { data, encoder in
                    let reference = try database.store(data, field: encoder.codingPath.last?.stringValue ?? "")
                    _ = references.withLock { $0.insert(reference.sha256) }
                    try reference.encode(to: encoder)
                }
                let payload = try compactEncoder.encode(state)
                let report = state.report.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let bookkeeping = report?["bookkeeping"] as? [String: Any]
                let manifest = Manifest(storage: format, payload: payload, payloadSHA256: hash(payload),
                    stateSHA256: stateHash, references: references.withLock { $0.sorted() },
                    summary: Summary(runID: state.id, phase: state.phase, document: state.document,
                        admittedSourceCount: state.receipts.count, committed: report?["committed"] as? Bool,
                        findings: report?["findings"] as? [String],
                        storedSources: bookkeeping?["storedSources"] as? [String] ?? report?["stored_sources"] as? [String]))
                // Reconstruct and verify before an old full JSON can be replaced.
                _ = try decode(manifest, database: database)
                try database.execute("COMMIT")
                // Chunks are durable before this atomic publication. A crash leaves
                // either the old manifest or the new manifest; both remain readable.
                try encoder().encode(manifest).write(to: session, options: .atomic)
                do {
                    try checkpoints(state, original: original, hash: stateHash, root: root)
                    try collectIfDue(sessions: session.deletingLastPathComponent(), root: root, database: database)
                } catch {
                    NSLog("Secretary archive maintenance failed; verified session remains available: %@", error.localizedDescription)
                }
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    private static func decode(_ manifest: Manifest, database: Database) throws -> SecretaryPacketFiles.State {
        guard manifest.storage == format, hash(manifest.payload) == manifest.payloadSHA256 else {
            throw Failure("Secretary session manifest checksum mismatch.")
        }
        let references = OSAllocatedUnfairLock(initialState: Set<String>())
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let reference = try Reference(from: decoder)
            _ = references.withLock { $0.insert(reference.sha256) }
            return try database.read(reference)
        }
        let state = try decoder.decode(SecretaryPacketFiles.State.self, from: manifest.payload)
        guard references.withLock({ $0 }) == Set(manifest.references), hash(try canonical(state)) == manifest.stateSHA256 else {
            throw Failure("Secretary session state checksum mismatch.")
        }
        return state
    }

    /// At most once a day, discard only unreferenced intermediate data left by
    /// refreshes or interrupted publication. All session manifests are retained.
    private static func collectIfDue(sessions: URL, root: URL, database: Database) throws {
        let receipt = root.appendingPathComponent("collected-at.json")
        if let data = try? Data(contentsOf: receipt), let last = try? JSONDecoder().decode(Date.self, from: data),
           Date().timeIntervalSince(last) < 86_400 { return }
        try collect(sessions: sessions, database: database)
        try encoder().encode(Date()).write(to: receipt, options: .atomic)
    }

    static func collectUnreferenced(at session: URL) throws {
        let root = directory(for: session)
        try locked(root) {
            try collect(sessions: session.deletingLastPathComponent(), database: Database(root: root, create: false, writable: true))
        }
    }

    private static func collect(sessions: URL, database: Database) throws {
        var live = Set<String>()
        var maps: [String: Set<String>] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isSymbolicLinkKey])
        where file.pathExtension == "json" {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Failure("Cannot collect archive data with a symbolic session manifest.")
            }
            let bytes = try Data(contentsOf: file)
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else {
                // Unreadable evidence must stop collection, never authorize deletion.
                _ = try JSONDecoder().decode(SecretaryPacketFiles.State.self, from: bytes)
                continue
            }
            guard manifest.storage == format, hash(manifest.payload) == manifest.payloadSHA256 else {
                throw Failure("Cannot collect archive data with an invalid session manifest.")
            }
            let found = OSAllocatedUnfairLock(initialState: [Reference]())
            let decoder = JSONDecoder()
            decoder.dataDecodingStrategy = .custom { decoder in
                let ref = try Reference(from: decoder)
                guard ref.bytes >= 0 else { throw Failure("Invalid archive reference size.") }
                found.withLock { $0.append(ref) }
                return Data()
            }
            _ = try decoder.decode(SecretaryPacketFiles.State.self, from: manifest.payload)
            let references = found.withLock { $0 }
            guard Set(references.map(\.sha256)) == Set(manifest.references) else { throw Failure("Invalid archive reference inventory.") }
            for reference in references {
                live.insert(reference.sha256)
                maps[reference.sha256, default: []].insert(reference.mapSHA256 ?? "")
            }
        }
        try database.collect(references: live, maps: maps)
    }

    private struct Checkpoint: Codable {
        let runID: String
        let phase: String
        let sha256: String
        let stateSHA256: String
        let reason: String
    }

    private struct LastTerminal: Codable {
        let runID: String
        let findingSignature: String?
    }

    private static func checkpoints(_ state: SecretaryPacketFiles.State, original: Data, hash: String, root: URL) throws {
        guard state.phase == "applied" || state.phase == "failed" else { return }
        let directory = checkpointDirectory(document: state.document, archive: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var names = [String: String]()
        // Calendar boundaries follow the run ID, rather than a later archive time.
        let day = String(state.id.prefix(8))
        if day.count == 8, day.allSatisfy(\.isNumber) { names[day + "-latest"] = "latest completed session of day" }
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.json").path) {
            names["first"] = "first completed session"
        }
        if state.phase == "applied", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("first-success.json").path) {
            names["first-success"] = "first successful session"
        }
        let lastURL = directory.appendingPathComponent(".last-terminal")
        let last = (try? Data(contentsOf: lastURL)).flatMap { try? JSONDecoder().decode(LastTerminal.self, from: $0) }
        var signature: String?
        if let report = state.report,
           let object = try JSONSerialization.jsonObject(with: report) as? [String: Any],
           let findings = object["findings"] as? [String], !findings.isEmpty {
            // Repeated historical findings must not create another full checkpoint
            // on every pass. Preserve the first example of each distinct finding set.
            signature = Self.hash(try JSONSerialization.data(withJSONObject: findings.sorted()))
            let name = "finding-" + signature!
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path) {
                names[name] = "first occurrence of finding set"
            }
        }
        if state.phase == "applied", signature == nil, let previous = last?.findingSignature {
            let name = "resolved-" + previous
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path) {
                names[name] = "first successful session after finding set"
            }
        }
        guard !names.isEmpty else { return }
        // Include the resulting document/registry and the host's run evidence,
        // rather than only the input snapshot captured before the pass.
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var evidence: [String: String] = [:]
        if let workspace = SecretaryWorkspace(document: state.document) {
            let run = workspace.runDirectory(state.id)
            let files = [workspace.document, workspace.document.deletingPathExtension().appendingPathExtension("sources.json"),
                         workspace.root.appendingPathComponent("secretary/review_queue.md"), workspace.threadsFile]
                + ["run.json", "response.json", "result.json", "apply-report.json", "packet-edit-report.json",
                   "packet-task-report.json", "document.diff", "registry-before-host.json"].map { run.appendingPathComponent($0) }
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                evidence[workspace.relative(file)] = try Data(contentsOf: file).base64EncodedString()
            }
        }
        object["_checkpoint_files"] = evidence
        let full = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let fullHash = Self.hash(full)
        let compressed = try (full as NSData).compressed(using: .lzfse) as Data
        guard fullHash == Self.hash(try (compressed as NSData).decompressed(using: .lzfse) as Data) else {
            throw Failure("Secretary checkpoint round-trip failed.")
        }
        for (name, reason) in names {
            let metadataURL = directory.appendingPathComponent(name + ".json")
            // The lock serializes completion/publication order. Run IDs contain
            // a random suffix and cannot order two sessions in the same second.
            // Content-addressing keeps metadata and data consistent across a crash.
            let snapshot = directory.appendingPathComponent(fullHash + ".json.lzfse")
            if !FileManager.default.fileExists(atPath: snapshot.path) { try compressed.write(to: snapshot, options: .atomic) }
            try encoder().encode(Checkpoint(runID: state.id, phase: state.phase, sha256: fullHash, stateSHA256: hash, reason: reason))
                .write(to: metadataURL, options: .atomic)
        }
        // Superseded daily snapshots are convenience copies. Every complete state
        // is still reconstructable through its manifest and the shared database.
        try thinDailyCheckpoints(in: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var retained = Set<String>()
        for file in files where file.pathExtension == "json" {
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: file))
            retained.insert(checkpoint.sha256 + ".json.lzfse")
        }
        for file in files where file.lastPathComponent.hasSuffix(".json.lzfse") && !retained.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
        try encoder().encode(LastTerminal(runID: state.id, findingSignature: signature)).write(to: lastURL, options: .atomic)
    }

    /// Full convenience copies become weekly after 30 days and monthly after
    /// 180 days. This never removes any session or its shared evidence.
    private static func thinDailyCheckpoints(in directory: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = formatter.timeZone
        var buckets: [String: [URL]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            guard name.count == 20, name.hasSuffix("-latest.json"),
                  let date = formatter.date(from: String(name.prefix(8))) else { continue }
            let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if days <= 30 { continue }
            let key: String
            if days <= 180 {
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                key = "week-\(parts.yearForWeekOfYear!)-\(parts.weekOfYear!)"
            } else { key = "month-" + name.prefix(6) }
            buckets[key, default: []].append(file)
        }
        for files in buckets.values {
            let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in ordered.dropLast() { try FileManager.default.removeItem(at: file) }
        }
    }

    private static func locked<T>(_ root: URL, exclusive: Bool = true, operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Failure("Cannot open secretary archive lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw Failure("Cannot lock secretary archive.") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Coder callbacks are Sendable: serialize caches and handle access even if
    /// Foundation parallelizes callbacks. The outer file lock protects publication
    /// and collection across processes; SQLite commits provide durable storage.
    private final class Database: @unchecked Sendable {
        private let access = NSRecursiveLock()
        private var handle: OpaquePointer?
        private var chunkIDs: [String: Int64] = [:]
        private var blobHashes = Set<String>()

        init(root: URL, create: Bool, writable: Bool = false) throws {
            let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
            let result = sqlite3_open_v2(root.appendingPathComponent("objects.sqlite3").path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK else {
                sqlite3_close(handle); handle = nil
                throw Failure("Cannot open secretary archive database.")
            }
            sqlite3_busy_timeout(handle, 10_000)
            if create {
                try execute("PRAGMA auto_vacuum=INCREMENTAL")
                try execute("PRAGMA synchronous=FULL")
                try execute("CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, sha TEXT UNIQUE NOT NULL, size INTEGER NOT NULL, data BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS blobs(sha TEXT PRIMARY KEY, size INTEGER NOT NULL, refs BLOB NOT NULL)")
                try query("SELECT id,sha FROM chunks") { row in chunkIDs[text(row, 1)] = sqlite3_column_int64(row, 0) }
                try query("SELECT sha FROM blobs") { row in blobHashes.insert(text(row, 0)) }
            }
        }

        deinit { sqlite3_close(handle) }

        func execute(_ sql: String) throws {
            access.lock(); defer { access.unlock() }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure("Secretary archive database write failed.") }
        }

        func store(_ bytes: Data, field: String) throws -> Reference {
            access.lock(); defer { access.unlock() }
            let sha = hash(bytes)
            if blobHashes.contains(sha) {
                var reference: Reference?
                try query("SELECT size,refs FROM blobs WHERE sha=?", parameter: sha) { row in
                    guard bytes.count == Int(sqlite3_column_int64(row, 0)) else { throw Failure("Invalid secretary archive object size.") }
                    let refs = try (data(row, 1) as NSData).decompressed(using: .lzfse) as Data
                    reference = Reference(sha256: sha, bytes: bytes.count, mapSHA256: hash(refs))
                }
                guard let reference else { throw Failure("Missing secretary archive object.") }
                return reference
            }
            let delimiter: Data? = field == "registryData" ? Data("\n    {".utf8) : field == "documentData" ? Data("\n\n".utf8) : nil
            var ranges: [Range<Int>] = []
            if let delimiter, bytes.count > 65_536 {
                var start = 0
                var search = 0
                while search < bytes.count, let next = bytes.range(of: delimiter, in: search..<bytes.count) {
                    if next.lowerBound > start { ranges.append(start..<next.lowerBound) }
                    start = next.lowerBound; search = next.upperBound
                }
                if start < bytes.count { ranges.append(start..<bytes.count) }
            } else {
                var start = 0
                while start < bytes.count { let end = min(start + 65_536, bytes.count); ranges.append(start..<end); start = end }
            }
            var ids: [Int64] = []
            for range in ranges {
                let part = bytes.subdata(in: range), key = hash(part)
                if let id = chunkIDs[key] { ids.append(id); continue }
                let compressed = try (part as NSData).compressed(using: .lzfse) as Data
                try update("INSERT INTO chunks(sha,size,data) VALUES(?,?,?)", text: key, size: part.count, bytes: compressed)
                let id = sqlite3_last_insert_rowid(handle); chunkIDs[key] = id; ids.append(id)
            }
            let map = try JSONEncoder().encode(ids)
            let refs = try (map as NSData).compressed(using: .lzfse) as Data
            try update("INSERT INTO blobs(sha,size,refs) VALUES(?,?,?)", text: sha, size: bytes.count, bytes: refs)
            blobHashes.insert(sha)
            return Reference(sha256: sha, bytes: bytes.count, mapSHA256: hash(map))
        }

        func read(_ reference: Reference) throws -> Data {
            access.lock(); defer { access.unlock() }
            var size: Int?
            var refs: Data?
            try query("SELECT size,refs FROM blobs WHERE sha=?", parameter: reference.sha256) { row in
                size = Int(sqlite3_column_int64(row, 0)); refs = data(row, 1)
            }
            guard let refs, size == reference.bytes else { throw Failure("Missing secretary archive data.") }
            let map = try (refs as NSData).decompressed(using: .lzfse) as Data
            guard reference.mapSHA256 == nil || reference.mapSHA256 == hash(map) else { throw Failure("Secretary archive chunk inventory checksum mismatch.") }
            let ids = try JSONDecoder().decode([Int64].self, from: map)
            var result = Data(); result.reserveCapacity(reference.bytes)
            for id in ids {
                var part: Data?
                try query("SELECT sha,size,data FROM chunks WHERE id=\(id)") { row in
                    let decoded = try (data(row, 2) as NSData).decompressed(using: .lzfse) as Data
                    guard decoded.count == Int(sqlite3_column_int64(row, 1)), hash(decoded) == text(row, 0) else {
                        throw Failure("Secretary archive chunk checksum mismatch.")
                    }
                    part = decoded
                }
                guard let part else { throw Failure("Missing secretary archive chunk.") }
                result.append(part)
            }
            guard result.count == reference.bytes, hash(result) == reference.sha256 else {
                throw Failure("Secretary archive data checksum mismatch.")
            }
            return result
        }

        func collect(references live: Set<String>, maps: [String: Set<String>]) throws {
            access.lock(); defer { access.unlock() }
            try execute("BEGIN IMMEDIATE")
            do {
                var unusedBlobs: [String] = []
                var liveChunks = Set<Int64>()
                var found = Set<String>()
                try query("SELECT sha,refs,size FROM blobs") { row in
                    let sha = text(row, 0)
                    if live.contains(sha) {
                        found.insert(sha)
                        let bytes = try (data(row, 1) as NSData).decompressed(using: .lzfse) as Data
                        let expected = maps[sha] ?? []
                        guard expected.filter({ !$0.isEmpty }).allSatisfy({ $0 == hash(bytes) }) else {
                            throw Failure("Cannot collect archive data: chunk inventory checksum mismatch.")
                        }
                        // Older manifests did not bind the chunk inventory. Verify
                        // their complete object before trusting that inventory.
                        if expected.contains("") {
                            _ = try read(Reference(sha256: sha, bytes: Int(sqlite3_column_int64(row, 2)), mapSHA256: nil))
                        }
                        liveChunks.formUnion(try JSONDecoder().decode([Int64].self, from: bytes))
                    } else { unusedBlobs.append(sha) }
                }
                guard found == live else { throw Failure("Cannot collect archive data: a referenced object is missing.") }
                for sha in unusedBlobs {
                    let statement = try prepare("DELETE FROM blobs WHERE sha=?")
                    bind(sha, to: statement, at: 1)
                    let result = sqlite3_step(statement); sqlite3_finalize(statement)
                    guard result == SQLITE_DONE else { throw Failure("Archive data collection failed.") }
                }
                var unusedChunks: [Int64] = []
                try query("SELECT id FROM chunks") { row in
                    let id = sqlite3_column_int64(row, 0)
                    if !liveChunks.contains(id) { unusedChunks.append(id) }
                }
                for id in unusedChunks { try execute("DELETE FROM chunks WHERE id=\(id)") }
                try execute("COMMIT")
                try execute("PRAGMA incremental_vacuum(256)")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        private func update(_ sql: String, text: String, size: Int, bytes: Data) throws {
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            bind(text, to: statement, at: 1); sqlite3_bind_int64(statement, 2, Int64(size))
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure("Secretary archive insert failed.") }
        }

        private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

        private func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Failure("Secretary archive query failed.")
            }
            return statement
        }

        private func query(_ sql: String, parameter: String? = nil, row: (OpaquePointer) throws -> Void) throws {
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            if let parameter { bind(parameter, to: statement, at: 1) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw Failure("Secretary archive read failed.") }
                try row(statement)
            }
        }

        private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
            _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        }

        private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: bytes)
        }

        private func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
