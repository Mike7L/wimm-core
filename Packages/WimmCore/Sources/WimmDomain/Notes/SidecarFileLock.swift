import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cross-process exclusion for `.meta.json` read-modify-writes.
///
/// Studio, `wimm-cli`, the MCP server and the `transcript drain-queue` worker
/// all write sidecars of one library. `FileStore.mutateSidecar` takes this
/// `flock` (after its in-process `NSLock`) so that their read-modify-writes of
/// one sidecar never interleave.
///
/// Lock files live in the per-user Darwin temp directory
/// (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, i.e. `/var/folders/…/T/`), never in
/// the library: nothing there is listed as a note, moved to Trash, imported
/// or synced. That directory is the same for every unsandboxed process of the
/// user even when `TMPDIR` is overridden (an agent shell), and it does not
/// depend on how a process resolves its library (`WIMM_BASE_DIR`, test temp
/// base). The sidecar's resolved path is hashed onto a fixed set of stripes,
/// so the number of lock files stays bounded; two sidecars that share a
/// stripe only wait for each other briefly.
///
/// If the lock file cannot be opened or locked the write still proceeds under
/// the in-process lock alone (the behavior before this lock existed), and the
/// first such failure in a process is logged.
enum SidecarFileLock {
    static let stripeCount: UInt64 = 64
    static let directoryName = "wimm-sidecar-locks"

    static func directory() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let base: String
        if length > 0, length <= buffer.count {
            base = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            base = NSTemporaryDirectory()
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The stripe lock file guarding `sidecarURL`. The parent directory is
    /// resolved (the sidecar itself may not exist yet), so `/var/…` and
    /// `/private/var/…` spellings of one file share a lock.
    static func lockFileURL(forSidecar sidecarURL: URL) -> URL {
        let standardized = sidecarURL.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let key = parent.appendingPathComponent(standardized.lastPathComponent).path
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let stripe = hash % stripeCount
        return directory().appendingPathComponent(String(format: "sidecar-%02llu.lock", stripe))
    }

    /// Runs `body` while holding the exclusive `flock` for `sidecarURL`.
    static func withLock<T>(forSidecar sidecarURL: URL, _ body: () throws -> T) rethrows -> T {
        let lockURL = lockFileURL(forSidecar: sidecarURL)
        guard let fd = acquire(lockURL) else { return try body() }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    /// Opens and locks `lockURL`. Retries when the file was replaced or
    /// removed while waiting (the OS may clean old temp files): a lock on an
    /// unlinked inode would not exclude a process that opens the new file.
    private static func acquire(_ lockURL: URL) -> Int32? {
        let directory = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var lastError: Int32 = 0
        for _ in 0..<8 {
            let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { lastError = errno; break }
            var result: Int32
            repeat { result = flock(fd, LOCK_EX) } while result != 0 && errno == EINTR
            guard result == 0 else { lastError = errno; close(fd); break }
            var held = stat()
            var onDisk = stat()
            if fstat(fd, &held) == 0, stat(lockURL.path, &onDisk) == 0,
                held.st_dev == onDisk.st_dev, held.st_ino == onDisk.st_ino
            {
                return fd
            }
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        unavailableReport.reportOnce(path: lockURL.path, errno: lastError)
        return nil
    }

    private static let unavailableReport = OnceReport()

    private final class OnceReport: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = false

        func reportOnce(path: String, errno code: Int32) {
            lock.lock()
            let first = !reported
            reported = true
            lock.unlock()
            guard first else { return }
            let reason = code == 0 ? "lock file kept changing" : String(cString: strerror(code))
            fputs("[Wimm] sidecar cross-process lock unavailable (\(path)): \(reason); using in-process lock only\n", stderr)
            UnifiedEventLogger.shared.logAppEvent(
                kind: "sidecar_lock_unavailable",
                phase: "error",
                origin: "SidecarFileLock",
                message: path,
                error: reason,
                source: "FileStore"
            )
        }
    }
}
