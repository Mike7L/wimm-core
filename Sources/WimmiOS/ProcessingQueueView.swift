#if os(iOS)
import SwiftUI
import WimmDomain
import WimmInfrastructure

/// The main screen's way into the queue: shows that something is running
/// and how much is left, without opening anything.
struct ProcessingQueueButton: View {
    @ObservedObject var queue: ProcessingQueue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: queue.isRunning ? "gearshape.2.fill" : "tray.full")
                    .symbolEffect(.pulse, isActive: queue.isRunning)
                if queue.activeCount > 0 {
                    Text("\(queue.activeCount)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(L10n.iOS.Queue.title)
        .accessibilityValue(queue.activeCount > 0 ? "\(queue.activeCount)" : "")
    }
}

struct ProcessingQueueView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var queue: ProcessingQueue
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = false
    @State private var found: [URL] = []
    @State private var showAddConfirmation = false
    @State private var showNothingFound = false

    private var activeJobs: [ProcessingJob] { queue.jobs.filter { $0.state.isActive } }
    private var finishedJobs: [ProcessingJob] { queue.jobs.filter { !$0.state.isActive }.reversed() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            Label(L10n.iOS.Queue.findUnprocessed, systemImage: "magnifyingglass")
                            Spacer()
                            if isScanning { ProgressView() }
                        }
                    }
                    .disabled(isScanning)
                } footer: {
                    Text(L10n.iOS.Queue.findFooter)
                }

                Section {
                    if activeJobs.isEmpty {
                        Text(L10n.iOS.Queue.empty).foregroundStyle(.secondary)
                    }
                    // Section-scoped ids: a job finishing must read as a delete
                    // here and an insert below, never as a cross-section move.
                    ForEach(activeJobs, id: \.activeRowID) { job in
                        row(job)
                            .swipeActions {
                                if job.state != .running {
                                    Button(L10n.Common.delete, role: .destructive) { queue.remove(job.id) }
                                }
                            }
                    }
                } header: {
                    Text(statusTitle)
                } footer: {
                    if !activeJobs.isEmpty { Text(L10n.iOS.Queue.backgroundFooter) }
                }

                if !finishedJobs.isEmpty {
                    Section {
                        ForEach(finishedJobs, id: \.finishedRowID) { job in
                            row(job)
                                .swipeActions {
                                    if case .failed = job.state {
                                        Button(L10n.iOS.Queue.retry) { queue.retry(job.id) }.tint(.orange)
                                    }
                                    Button(L10n.Common.delete, role: .destructive) { queue.remove(job.id) }
                                }
                        }
                        Button(L10n.iOS.Queue.clearFinished, role: .destructive) { queue.clearFinished() }
                    } header: {
                        Text(L10n.iOS.Queue.finished)
                    }
                }
            }
            .navigationTitle(L10n.iOS.Queue.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if queue.isRunning && !queue.isPaused {
                        Button(L10n.iOS.Queue.pause) { queue.pause() }
                    } else if activeJobs.contains(where: { $0.state == .queued }) {
                        Button(L10n.iOS.Queue.start) { queue.start() }.fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog(
                L10n.iOS.Queue.addTitle(found.count),
                isPresented: $showAddConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.iOS.Queue.addAndStart(found.count)) {
                    queue.enqueue(found, kind: .auto)
                    queue.start()
                }
                Button(L10n.iOS.Queue.addOnly) {
                    queue.enqueue(found, kind: .auto)
                }
                Button(L10n.iOS.Recording.cancel, role: .cancel) {}
            } message: {
                Text(L10n.iOS.Queue.addMessage)
            }
            .alert(L10n.iOS.Queue.nothingFound, isPresented: $showNothingFound) {
                Button(L10n.Common.ok, role: .cancel) {}
            }
        }
    }

    private var statusTitle: String {
        if queue.isRunning { return queue.isPaused ? L10n.iOS.Queue.pausing : L10n.iOS.Queue.running }
        if queue.isPaused, !activeJobs.isEmpty { return L10n.iOS.Queue.paused }
        return L10n.iOS.Queue.queued
    }

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        found = await appState.unprocessedNotes()
        if found.isEmpty { showNothingFound = true } else { showAddConfirmation = true }
    }

    private func row(_ job: ProcessingJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stateIcon(job.state)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: job)).lineLimit(1)
                Text(kindLabel(job.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = job.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: ProcessingJob.State) -> some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// Same wording as the note list, so a job is recognisable at a glance.
    private func title(for job: ProcessingJob) -> String {
        let name = job.url.lastPathComponent
        guard let recording = appState.recordings.first(where: { $0.fileURL.lastPathComponent == name }) else {
            return job.url.deletingPathExtension().lastPathComponent
        }
        return recording.displayTitle
    }

    private func kindLabel(_ kind: ProcessingJobKind) -> String {
        switch kind {
        case .transcribe: return L10n.iOS.Reprocess.retranscribe
        case .transcribeLocal: return L10n.iOS.Reprocess.retranscribeOnDevice
        case .transcribeCloud:
            return L10n.iOS.Reprocess.retranscribeCloud(TranscriptKind.cloud.retranscriptionModel() ?? "")
        case .analyze: return L10n.iOS.Reprocess.reanalyze
        case .auto: return L10n.iOS.Queue.kindAuto
        }
    }
}
private extension ProcessingJob {
    var activeRowID: String { "active-\(id)" }
    var finishedRowID: String { "finished-\(id)" }
}
#endif
