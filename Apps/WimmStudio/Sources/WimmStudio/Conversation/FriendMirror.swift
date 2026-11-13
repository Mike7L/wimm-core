@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// The built-in camera shown mirrored, like a mirror. Nothing is recorded:
/// the session only feeds a preview layer.
@MainActor @Observable
final class FriendMirror {
    enum State: Equatable { case off, starting, running, denied, unavailable }

    private(set) var state: State = .off
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false
    /// `startRunning`/`stopRunning` block; they run here, off the main thread.
    @ObservationIgnored private let queue = DispatchQueue(label: "WimmStudio.FriendMirror")

    func start() async {
        guard state == .off || state == .denied || state == .unavailable else { return }
        state = .starting
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { state = .denied; return }
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { state = .unavailable; return }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { session.startRunning(); done.resume() }
        }
        state = .running
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        let session = self.session
        queue.async { session.stopRunning() }
        state = .off
    }
}

struct FriendMirrorView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Changes when the session starts, so the new connection gets mirrored.
    let isRunning: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirror()
    }

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
            mirror()
        }

        /// The connection exists only once the session has an input.
        func mirror() {
            if let connection = preview.connection, connection.isVideoMirroringSupported, !connection.isVideoMirrored {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}
