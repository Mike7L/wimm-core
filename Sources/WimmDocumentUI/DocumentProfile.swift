import AppKit
import SwiftUI
import Darwin
import WimmDomain

/// A fresh, explicitly marked temporary library and preference domain are mandatory.
/// This profiles production views without starting capture, sync, providers or model inference.
@MainActor public enum DocumentProfile {
    public static var enabled: Bool { DocumentDiagnostics.enabled }
    public static var documentURL: URL { StoragePaths.baseDirectory().appendingPathComponent("document.md") }
    public static func prepare() throws {
        guard enabled else { return }
        let env = ProcessInfo.processInfo.environment
        let base = StoragePaths.baseDirectory().resolvingSymlinksInPath()
        guard env["WIMM_TEST_MODE"] == "1", env["WIMM_PRIVATE_MODE"] == "1",
              (base.path.hasPrefix("/private/tmp/wimm-document-profile-") || base.path.hasPrefix("/tmp/wimm-document-profile-")),
              FileManager.default.fileExists(atPath: base.appendingPathComponent(".performance-fixture").path),
              let id = Bundle.main.bundleIdentifier, id.hasPrefix("com.micha.wimm.document-profile."),
              env["WIMM_DEFAULTS_SUITE"] == id, env["CFFIXED_USER_HOME"] != nil else {
            FileHandle.standardError.write(Data("Invalid profile fixture: base=\(base.path), bundle=\(Bundle.main.bundleIdentifier ?? "nil"), suite=\(env["WIMM_DEFAULTS_SUITE"] ?? "nil")\n".utf8))
            throw CocoaError(.fileReadNoPermission)
        }
        try FileStore.ensureDirectoryExists()
        let count = max(0, min(10000, Int(env["WIMM_PROFILE_NOTES"] ?? "1000") ?? 1000))
        let text = String(repeating: "Заметка о проекте. Unicode café 👩‍💻.\n", count: 40)
        for i in 0..<count {
            let file = FileStore.recordingsDirectory().appendingPathComponent(String(format: "Wimm_2026-10-25_10-00-00_%05d.txt", i))
            try text.write(to: file, atomically: true, encoding: .utf8)
            FileStore.upsertMetadata(for: file, updates: ["noteCard": ["schema": Schemas.noteCard, "note_file": file.lastPathComponent,
                "title": "Fixture \(i)", "summary": "Synthetic fixture", "refined_text": text], "processingStatus": "completed"])
        }
    }

    public static func run(app: String, loadLibrary: @escaping @MainActor () async throws -> [String: Any],
                           makeDocument: @escaping @MainActor () -> AnyView,
                           makeReader: (@MainActor () -> AnyView)? = nil) {
        Task {
            var stages: [[String: Any]] = []
            let started = ProcessInfo.processInfo.systemUptime
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1040, height: 740),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Document resource profile · \(app)"
            @MainActor func mount(_ root: AnyView) {
                let host = NSHostingController(rootView: root)
                host.sizingOptions = []
                window.contentViewController = host
                // Assignment can adopt the hosting view's initial fitting size.
                window.setContentSize(NSSize(width: 1040, height: 740))
            }
            mount(AnyView(Color.clear))
            window.orderFrontRegardless()
            var library: [String: Any] = [:]
            var errorMessage: String?
            let hold = max(1, min(30, Double(ProcessInfo.processInfo.environment["WIMM_PROFILE_HOLD"] ?? "3") ?? 3))
            @MainActor func snapshot() -> [String: Any] {
                var vm = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let status = withUnsafeMutablePointer(to: &vm) { p in
                    p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                return ["uptime_seconds": ProcessInfo.processInfo.systemUptime - started,
                        "footprint_bytes": status == KERN_SUCCESS ? vm.phys_footprint as Any : NSNull(),
                        "lifetime_peak_bytes": status == KERN_SUCCESS ? vm.ledger_phys_footprint_peak as Any : NSNull(),
                        "cpu_seconds": cpu, "counters": DocumentDiagnostics.counters,
                        "window_content_width": window.contentView?.bounds.width ?? 0,
                        "window_content_height": window.contentView?.bounds.height ?? 0]
            }
            @MainActor func stage(_ name: String, action: @MainActor () async throws -> Void = {}) async throws {
                FileHandle.standardError.write(Data("profile stage: \(name)\n".utf8))
                let before = snapshot()
                try await action()
                // Flush layout and allow rendering/async parsing to settle, before the idle window.
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .seconds(1))
                let settled = snapshot()
                if ProcessInfo.processInfo.environment["WIMM_PROFILE_SNAPSHOTS"] == "1",
                   let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: StoragePaths.baseDirectory().appendingPathComponent("snapshot-\(name).png"))
                    }
                }
                try await Task.sleep(for: .seconds(hold))
                let after = snapshot()
                stages.append(["stage": name, "before": before, "settled": settled, "after": after,
                    "action_and_settle_cpu_seconds": (settled["cpu_seconds"] as! Double) - (before["cpu_seconds"] as! Double),
                    "idle_cpu_percent_one_core": ((after["cpu_seconds"] as! Double) - (settled["cpu_seconds"] as! Double)) /
                        ((after["uptime_seconds"] as! Double) - (settled["uptime_seconds"] as! Double)) * 100])
            }
            do {
                try await stage("empty_window")
                try await stage("library_loaded") { library = try await loadLibrary() }
                let mode = ProcessInfo.processInfo.environment["WIMM_PROFILE_MODE"] ?? "document"
                if mode == "reader", let makeReader {
                    try await stage("reader_open") { mount(makeReader()) }
                } else if mode == "document" {
                    try await stage("document_collapsed") {
                        mount(makeDocument())
                        let deadline = ProcessInfo.processInfo.systemUptime + 30
                        while !DocumentDiagnostics.control.documentLoaded {
                            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadUnknown) }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                    try await stage("document_expanded") { DocumentDiagnostics.control.expansion = 1 }
                    try await stage("document_scrolled_end") { DocumentDiagnostics.control.scrollToEnd = true }
                    try await stage("document_narrow") { window.setContentSize(NSSize(width: 680, height: 740)) }
                    try await stage("document_collapsed_again") { DocumentDiagnostics.control.expansion = 0 }
                }
                try await stage("view_released") { window.contentViewController = nil; window.orderOut(nil) }
            } catch { errorMessage = error.localizedDescription }
            window.close()
            var report: [String: Any] = ["schema": 2, "app": app, "reference_renderer": DocumentDiagnostics.reference, "stages": stages, "library": library,
                "window_points": [1040, 740], "idle_seconds": hold,
                "limitations": "Synthetic temporary fixtures; same-process deltas include allocator/framework retention. Peak is lifetime high-water mark, never a per-view allocation count. One-second settle is a fixed window, not time-to-last-pixel. No sync, microphone or model inference. Compare medians of fresh processes at identical settings."]
            if let errorMessage { report["error"] = errorMessage }
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: StoragePaths.baseDirectory().appendingPathComponent("document-profile.json"), options: .atomic)
            } catch { fputs("Could not save document profile\n", stderr) }
            NSApp.terminate(nil)
        }
    }
}
