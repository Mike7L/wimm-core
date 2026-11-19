import CoreLocation
import Foundation
import WimmDomain

/// One-shot position of this device for a note being captured now.
/// Asks for the "while in use" permission on first use; a refusal, a
/// timeout or a failed fix all mean "no place" and the note is saved without
/// one. Never runs under tests.
@MainActor
public final class DeviceLocation: NSObject {
    public static let shared = DeviceLocation()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<NoteLocation?, Never>] = []
    private var last: (location: NoteLocation, at: Date)?
    private var timeoutTask: Task<Void, Never>?

    /// A fix this fresh is reused: split notes in one sitting share a place.
    public static let reuseSeconds: TimeInterval = 120
    public static let timeoutSeconds: TimeInterval = 15

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func current() async -> NoteLocation? {
        guard !StoragePaths.isTestProcess else { return nil }
        if let last, Date().timeIntervalSince(last.at) <= Self.reuseSeconds { return last.location }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == 1 else { return }
            if manager.authorizationStatus != .notDetermined { manager.requestLocation() }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    /// Takes a fix in the background and writes it into the note's sidecar.
    /// Returns at once; capture never waits for the position.
    nonisolated public static func stampCurrent(for recordingURL: URL) {
        Task { @MainActor in
            guard let location = await shared.current() else { return }
            NoteLocation.stamp(location, for: recordingURL)
        }
    }

    private func finish(_ location: NoteLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let location { last = (location, Date()) }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: location) }
    }
}

extension DeviceLocation: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard !waiters.isEmpty else { return }
            switch self.manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: finish(nil)
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last.flatMap { location in
            NoteLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                source: .device,
                fixedAt: location.timestamp
            )
        }
        MainActor.assumeIsolated { finish(fix) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
