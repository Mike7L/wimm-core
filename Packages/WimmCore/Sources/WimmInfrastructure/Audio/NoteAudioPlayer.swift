import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Shared note audio player for macOS and iOS.
///
/// Uses `AVPlayer` over `AVURLAsset` with `AVURLAssetPreferPreciseDurationAndTimingKey`
/// instead of `AVAudioPlayer`: Studio captures crash-safe raw ADTS `.aac` streams without
/// a container duration header, where `AVAudioPlayer` misestimates both duration and seek
/// offsets from the bitrate of the opening frames.
@MainActor
@Observable
public final class NoteAudioPlayer {
    public private(set) var isPlaying = false
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isReady = false
    public private(set) var failed = false

    public var skipSilence: Bool {
        didSet {
            guard skipSilence, let url = loadedURL, silenceMapURL != url else { return }
            loadSilenceMap(for: url)
        }
    }

    public var playbackRate: Float = 1.0 {
        didSet {
            let clamped = max(0.5, min(playbackRate, 3.0))
            if playbackRate != clamped {
                playbackRate = clamped
                return
            }
            #if canImport(AVFoundation)
            if isPlaying, !isSeeking {
                handle?.player.rate = playbackRate
            }
            #endif
        }
    }

    public var volume: Float = 1.0 {
        didSet {
            let clamped = max(0, min(volume, 1.0))
            if volume != clamped {
                volume = clamped
                return
            }
            #if canImport(AVFoundation)
            handle?.player.volume = volume
            #endif
        }
    }

    /// Invoked right before playback starts (used on iOS to switch `AVAudioSession` to `.playback`).
    @ObservationIgnored public var onBeforePlay: (@MainActor () -> Void)?

    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var autoPlayAfterLoad = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var silenceMap: AudioSilenceMap?
    @ObservationIgnored private var silenceMapURL: URL?
    @ObservationIgnored private var silenceMapTask: Task<Void, Never>?
    #if canImport(AVFoundation)
    @ObservationIgnored private var handle: PlaybackHandle?
    #endif

    public init(skipSilence: Bool = false, onBeforePlay: (@MainActor () -> Void)? = nil) {
        self.skipSilence = skipSilence
        self.onBeforePlay = onBeforePlay
    }

    /// Loads an audio file with exact frame timing and prepares it for playback.
    public func load(_ url: URL) async {
        loadTask?.cancel()
        loadTask = nil
        autoPlayAfterLoad = false
        await performLoad(url)
    }

    /// Starts or resumes playback of `url`, loading it on demand if it is not already loaded.
    public func play(url: URL) {
        if loadedURL == url {
            if isReady {
                play()
                return
            }
            if isLoading {
                autoPlayAfterLoad = true
                return
            }
        }
        loadTask?.cancel()
        autoPlayAfterLoad = true
        loadTask = Task { [weak self] in
            await self?.performLoad(url)
        }
    }

    /// Starts or resumes playback of the currently loaded recording.
    public func play() {
        #if canImport(AVFoundation)
        guard isReady, let player = handle?.player else { return }
        onBeforePlay?()
        if duration > 0, position >= duration - 0.05 {
            seek(to: 0, play: true)
            return
        }
        isPlaying = true
        if !isSeeking {
            player.rate = playbackRate
        }
        #endif
    }

    /// Pauses playback without unloading the recording.
    public func pause() {
        autoPlayAfterLoad = false
        isPlaying = false
        #if canImport(AVFoundation)
        handle?.player.pause()
        #endif
    }

    /// Toggles between playing and paused for the currently loaded recording.
    public func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seeks to `seconds` with frame-accurate timing; optionally begins playback once positioned.
    public func seek(to seconds: Double, play shouldPlay: Bool = false) {
        #if canImport(AVFoundation)
        guard isReady, let player = handle?.player else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = target
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        if shouldPlay && !isPlaying {
            onBeforePlay?()
            isPlaying = true
        }
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                if self.isPlaying {
                    self.handle?.player.rate = self.playbackRate
                }
            }
        }
        #endif
    }

    /// Stops playback and releases the underlying player and observers.
    public func stop() {
        loadGeneration &+= 1
        seekGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        silenceMapTask?.cancel()
        silenceMapTask = nil
        isLoading = false
        autoPlayAfterLoad = false
        isSeeking = false
        isPlaying = false
        position = 0
        duration = 0
        isReady = false
        failed = false
        loadedURL = nil
        silenceMap = nil
        silenceMapURL = nil
        #if canImport(AVFoundation)
        handle?.teardown()
        handle = nil
        #endif
    }

    // MARK: - Internals

    private func performLoad(_ url: URL) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let shouldAutoPlay = autoPlayAfterLoad
        autoPlayAfterLoad = false

        #if canImport(AVFoundation)
        handle?.teardown()
        handle = nil
        #endif
        silenceMapTask?.cancel()
        silenceMapTask = nil
        silenceMap = nil
        silenceMapURL = nil

        seekGeneration &+= 1
        isSeeking = false
        isPlaying = false
        position = 0
        duration = 0
        isReady = false
        failed = false
        loadedURL = url
        isLoading = true

        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let loadedDuration: Double?
        do {
            let (playable, rawDuration) = try await asset.load(.isPlayable, .duration)
            let seconds = CMTimeGetSeconds(rawDuration)
            loadedDuration = (playable && seconds.isFinite && seconds > 0) ? seconds : nil
        } catch {
            loadedDuration = nil
        }

        guard loadGeneration == generation else { return }
        isLoading = false
        guard !Task.isCancelled else { return }

        guard let seconds = loadedDuration else {
            failed = true
            isReady = false
            duration = 0
            return
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        player.actionAtItemEnd = .pause

        let newHandle = PlaybackHandle(player: player)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        newHandle.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTimeTick(time)
            }
        }
        newHandle.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackEnded()
            }
        }
        newHandle.statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                if status == .paused, !self.isSeeking, self.isPlaying {
                    self.isPlaying = false
                }
            }
        }

        handle = newHandle
        duration = seconds
        isReady = true
        failed = false

        if skipSilence {
            loadSilenceMap(for: url)
        }
        if shouldAutoPlay || autoPlayAfterLoad {
            autoPlayAfterLoad = false
            play()
        }
        #else
        isLoading = false
        failed = true
        #endif
    }

    private func loadSilenceMap(for url: URL) {
        silenceMapTask?.cancel()
        silenceMapURL = url
        silenceMap = nil
        silenceMapTask = Task { [weak self] in
            let map = await AudioSilenceAnalyzer.shared.silenceMap(for: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.silenceMapURL == url else { return }
                self.silenceMap = map
            }
        }
    }

    #if canImport(AVFoundation)
    private func handleTimeTick(_ time: CMTime) {
        guard !isSeeking else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = clamped
        if skipSilence, isPlaying, let target = silenceMap?.skipTarget(at: clamped) {
            if duration > 0, target >= duration - 0.05 {
                handlePlaybackEnded()
            } else {
                seek(to: target, play: true)
            }
        }
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        position = 0
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        handle?.player.pause()
        handle?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                if self.isPlaying {
                    self.handle?.player.rate = self.playbackRate
                }
            }
        }
    }

    /// Owns the raw `AVPlayer` and its observer tokens so cleanup is guaranteed both
    /// on explicit `teardown()` and on `deinit` without Swift 6 actor-isolation conflicts.
    private final class PlaybackHandle: @unchecked Sendable {
        let player: AVPlayer
        var timeObserver: Any?
        var endObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?

        init(player: AVPlayer) {
            self.player = player
        }

        func teardown() {
            player.pause()
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
            if let observer = endObserver {
                NotificationCenter.default.removeObserver(observer)
                endObserver = nil
            }
            statusObservation?.invalidate()
            statusObservation = nil
        }

        deinit {
            teardown()
        }
    }
    #endif
}
