import Foundation
import WimmInfrastructure
import WimmSecretary
import Observation

/// The Personal document window's side of the secretary dispatcher
/// (`docs/Secretary_Dispatcher.md`): one run at a time (comments or a full
/// pass), its live log and its record. The agent edits the document; while it runs the
/// workspace refuses edits, and it reloads when the run ends.
@Observable @MainActor
public final class PersonalDocumentSecretary {
    public enum Phase: Equatable { case idle, running, finished }

    public private(set) var phase: Phase = .idle
    public private(set) var log: [SecretaryEvent] = []
    public private(set) var record: SecretaryRunRecord?
    public private(set) var runDirectory: URL?
    public private(set) var errorMessage: String?
    public var showsPanel = false
    private var storedPacketSourceKB = SecretaryPacketSettings.preferredKB()
    public var packetSourceKB: Int {
        get { storedPacketSourceKB }
        set {
            let value = SecretaryPacketSettings.normalize(newValue)
            storedPacketSourceKB = value
            UserDefaults.standard.set(value, forKey: SecretaryPacketSettings.defaultsKey)
        }
    }
    private var storedOptimizationLevel = SecretaryOptimizationLevel.preferred()
    public var optimizationLevel: SecretaryOptimizationLevel {
        get { storedOptimizationLevel }
        set {
            storedOptimizationLevel = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: SecretaryOptimizationLevel.defaultsKey)
        }
    }
    private var storedEffort = SecretaryEffortSetting.preferred()
    /// Reasoning effort for runs from the app; empty is automatic (`SecretaryEffortSetting`).
    public var effort: String {
        get { storedEffort }
        set {
            storedEffort = SecretaryEffortSetting.options.contains(newValue) ? newValue : ""
            SecretaryEffortSetting.store(storedEffort)
        }
    }
    public private(set) var startedAt: Date?
    public var isRunning: Bool { phase == .running }

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Which outside agent runs; remembered across launches.
    public var agent: SecretaryAgent = SecretaryAgent.preferred {
        didSet {
            UserDefaults.standard.set(agent.rawValue, forKey: SecretaryAgent.defaultsKey)
            let preferredModel = agent.preferredModel()
            if model != preferredModel { model = preferredModel }
        }
    }
    /// Which model the current agent uses; remembered per agent across launches.
    public var model: String = SecretaryAgent.preferred.preferredModel() {
        didSet {
            let key = agent.modelDefaultsKey
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else if UserDefaults.standard.string(forKey: key) != trimmed { UserDefaults.standard.set(trimmed, forKey: key) }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    public init() {
        // Settings → Agent → Secretary writes the same key; follow it unless a run is going.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning else { return }
                self.storedPacketSourceKB = SecretaryPacketSettings.preferredKB()
                self.storedOptimizationLevel = SecretaryOptimizationLevel.preferred()
                self.storedEffort = SecretaryEffortSetting.preferred()
                let preferredAgent = SecretaryAgent.preferred
                if self.agent != preferredAgent { self.agent = preferredAgent }
                let preferredModel = self.agent.preferredModel()
                if self.model != preferredModel { self.model = preferredModel }
            }
        }
    }

    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

    /// The agent and the CLI it calls; tests replace them.
    @ObservationIgnored public var makeDispatcher: (_ agent: SecretaryAgent, _ budget: Double, _ model: String?) throws -> SecretaryDispatcher = { agent, budget, model in
        guard let wimmCLI = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
        // `Secretary.maxTurns` lifts the turn ceiling for a long rewrite; unset, the run kind's applies.
        return SecretaryDispatcher(executor: try agent.executor(), wimmCLI: wimmCLI, budgetUSD: budget, model: model,
                                   maxTurns: UserDefaults.standard.object(forKey: "Secretary.maxTurns") as? Int)
    }
    private static let logLimit = 500

    /// Starts a comments run on `document`; `onFinish` reloads the window.
    public func answerComments(document: URL, onFinish: @escaping @MainActor () async -> Void) {
        start(.comments, document: document, onFinish: onFinish)
    }

    /// Starts a run of `kind`: a comments run, or a full pass started by hand.
    public func start(_ kind: SecretaryRunKind, document: URL, onFinish: @escaping @MainActor () async -> Void) {
        guard !isRunning else { return }
        phase = .running
        startedAt = Date()
        log = []; record = nil; errorMessage = nil; runDirectory = nil
        let defaults = UserDefaults.standard
        let budget = defaults.object(forKey: "Secretary.budgetUSD") as? Double ?? 2
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? agent.preferredModel(defaults: defaults) : trimmedModel
        let model = resolvedModel.isEmpty ? nil : resolvedModel
        let agent = agent
        let packetSourceKB = SecretaryPacketSettings.preferredKB(defaults: defaults)
        let optimizationLevel = SecretaryOptimizationLevel.preferred(defaults: defaults)
        let effort = SecretaryEffortSetting.preferred(defaults: defaults)
        let (events, continuation) = AsyncStream.makeStream(of: SecretaryEvent.self)
        let consumer = Task { for await event in events { append(event) } }
        runTask = Task {
            defer { continuation.finish() }
            do {
                var dispatcher = try makeDispatcher(agent, budget, model)
                dispatcher.packetSourceKB = packetSourceKB
                dispatcher.optimizationLevel = optimizationLevel
                if !effort.isEmpty { dispatcher.effort = effort }
                let task = kind == .pass
                    ? try await dispatcher.preparePass(document: document)
                    : try await dispatcher.prepareComments(document: document)
                runDirectory = task.workspace.runDirectory(task.id)
                let record = try await dispatcher.run(task) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                self.record = record
            } catch {
                continuation.finish()
                await consumer.value
                errorMessage = error.localizedDescription
            }
            phase = .finished
            storedPacketSourceKB = SecretaryPacketSettings.preferredKB()
            runTask = nil
            await onFinish()
        }
    }

    public func cancel() { runTask?.cancel() }

    private func append(_ event: SecretaryEvent) {
        log.append(event)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
