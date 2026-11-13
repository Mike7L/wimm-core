import Foundation

/// Whether the process runs inside the App Sandbox (the Mac App Store build).
///
/// Dev builds (`make_app.sh`, WimmLocal) are unsandboxed, so anything that
/// reaches outside the container — Accessibility, posting key events into
/// another app, AppleScript, other apps' group containers — works there and
/// silently fails in the store build. Gate such features on this instead of
/// letting them fail quietly.
public enum AppSandbox {
    /// The sandbox sets `APP_SANDBOX_CONTAINER_ID` for every sandboxed process.
    public static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static var isActive: Bool { isActive() }
}
