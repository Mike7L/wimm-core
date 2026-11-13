#if os(iOS)
import BackgroundTasks
import Foundation
import WimmInfrastructure

/// Schedules a BGProcessingTask that uploads pending recordings (and pulls
/// remote changes) while the app is in the background, so sync no longer
/// depends on the app staying open.
enum BackgroundSync {
    static let taskIdentifier = "com.micha.wimm.sync"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task: task)
        }
    }

    /// Ask the system for a background run. Safe to call repeatedly —
    /// resubmitting the same identifier replaces the pending request.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundSync] scheduled \(taskIdentifier)")
        } catch {
            // BGTaskScheduler.Error.unavailable fires on the simulator — expected.
            print("[BackgroundSync] submit failed: \(error)")
        }
    }

    private static func handle(task: BGProcessingTask) {
        // Chain the next run before doing any work.
        schedule()

        let work = Task {
            var success = true
            if let service = CloudRecordingSyncService.live() {
                do {
                    try await service.syncNow()
                } catch {
                    print("[BackgroundSync] sync failed: \(error)")
                    success = false
                }
            }
            task.setTaskCompleted(success: success)
        }

        // On expiration cancel the work; syncNow throws CancellationError and
        // the task completes with success=false, so the system retries later.
        task.expirationHandler = {
            work.cancel()
        }
    }
}
#endif
