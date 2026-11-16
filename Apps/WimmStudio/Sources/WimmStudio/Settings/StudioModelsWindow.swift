import AppKit
import SwiftUI
import WimmDocumentUI
import WimmInfrastructure
import WimmSecretary

/// Which model ids a role's picker offers. Pure, so the rules are testable
/// without a window or a network call.
enum StudioModelOptions {
    /// Catalog entries a text role can call: Gemini chat models, without the
    /// speech, image, live and embedding variants that share the prefix.
    static func textModels(in catalog: [GeminiModel]) -> [String] {
        let excluded = ["tts", "image", "live", "embedding", "audio"]
        return catalog
            .filter { $0.supportedGenerationMethods.contains("generateContent") }
            .map(\.id)
            .filter { id in
                let lower = id.lowercased()
                return lower.hasPrefix("gemini-") && !excluded.contains { lower.contains($0) }
            }
            .sorted()
    }

    /// An id a cloud re-run may use: not empty and not an on-device model
    /// (`TranscriptKind.ofModel` files an empty id under cloud).
    static func isCloudTranscriber(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && TranscriptKind.ofModel(trimmed) == .cloud
    }

    /// The current choice and the built-in defaults are always offered, so the
    /// picker shows the truth before the catalog loads, offline and in private mode.
    static func list(catalog: [String], current: String, defaults: [String]) -> [String] {
        var seen = Set<String>()
        return ([current] + defaults + catalog)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Studio's one place for model choices, by task: secretary, conversation,
/// note analysis and cloud transcription. Live text and on-device Parakeet are
/// tied to their protocol and device and are not offered here on purpose.
@MainActor
enum ModelsWindow {
    private static var window: NSWindow?

    static func show(secretary: PersonalDocumentSecretary) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: ModelsWindowView(secretary: secretary))
        host.sizingOptions = []
        let made = NSWindow(contentViewController: host)
        made.title = "Модели"
        made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        made.isReleasedWhenClosed = false
        made.setContentSize(NSSize(width: 520, height: 640))
        if !made.setFrameUsingName("WimmModelsWindow") { made.center() }
        made.setFrameAutosaveName("WimmModelsWindow")
        window = made
        NSApp.activate(ignoringOtherApps: true)
        made.makeKeyAndOrderFront(nil)
    }
}

struct ModelsWindowView: View {
    let secretary: PersonalDocumentSecretary

    @State private var catalog: [String] = []
    @State private var catalogNote: String?
    @State private var conversation = ModelSelection.conversationModel
    @State private var analysis = ModelSelection.model(for: .think)
    @State private var cloud = ModelsWindowView.cloudModel()

    /// What a cloud re-run uses: the stored model when it is a cloud one, else the default.
    private static func cloudModel() -> String {
        TranscriptKind.cloud.retranscriptionModel() ?? ModelSelection.defaultGeminiModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                role("Секретарь", note: "Усилие, лимит расходов и размер пакета — в окне секретаря.") {
                    Picker("Агент", selection: Bindable(secretary).agent) {
                        ForEach(SecretaryAgent.allCases) { Text($0.displayName).tag($0) }
                    }
                    let options = secretary.agent.modelOptions(including: secretary.model)
                    if !options.isEmpty {
                        Picker("Модель", selection: Bindable(secretary).model) {
                            ForEach(options) { Text($0.displayName).tag($0.id) }
                        }
                    }
                }
                .disabled(secretary.isRunning)

                role("Разговор", note: "Алёна и «Ангел и Демон». Только модели Gemini. Смена модели пересобирает досье «Ангела и Демона» при следующем открытии.") {
                    ModelField(current: conversation,
                               options: StudioModelOptions.list(catalog: catalog, current: conversation,
                                                                defaults: [ModelSelection.defaultConversationModel]),
                               accepts: ModelSelection.isGeminiModel) { id in
                        if ModelSelection.setConversationModel(id) { conversation = ModelSelection.conversationModel }
                    }
                }

                role("Анализ заметки", note: "Запускается после каждой записи. Gemini или id модели OpenRouter (с «/»).") {
                    ModelField(current: analysis,
                               options: StudioModelOptions.list(catalog: catalog, current: analysis,
                                                                defaults: [ModelSelection.defaultGeminiModel]),
                               accepts: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { id in
                        ModelSelection.setModel(id, for: .think)
                        analysis = ModelSelection.model(for: .think)
                    }
                }

                role("Облачная расшифровка", note: "Только по запросу. Расшифровка после записи остаётся на устройстве (Parakeet).") {
                    ModelField(current: cloud,
                               options: StudioModelOptions.list(catalog: catalog, current: cloud,
                                                                defaults: [ModelSelection.defaultGeminiModel]),
                               accepts: StudioModelOptions.isCloudTranscriber) { id in
                        ModelSelection.setModel(id, for: .hear)
                        cloud = Self.cloudModel()
                    }
                }

                if let catalogNote {
                    Text(catalogNote).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 420)
        .task { await loadCatalog() }
    }

    private func role<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
            Text(note).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadCatalog() async {
        // The catalog request carries only the key, but private mode means no cloud calls at all.
        guard !PrivateMode.isEnabled else {
            catalogNote = "Приватный режим: список моделей не загружается, id можно ввести вручную."
            return
        }
        do {
            catalog = StudioModelOptions.textModels(in: try await GeminiModelsAPI.fetch())
            catalogNote = nil
        } catch {
            catalogNote = "Список моделей Gemini не загружен (\(error.localizedDescription)). Id можно ввести вручную."
        }
    }
}

/// A picker over known ids plus a field for any other id. The typed id is
/// stored only on Return or «Применить», never per keystroke.
private struct ModelField: View {
    let current: String
    let options: [String]
    let accepts: (String) -> Bool
    let commit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        Picker("Модель", selection: Binding(get: { current }, set: { commit($0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        HStack {
            TextField("Другая модель (id)", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
            Button("Применить", action: apply)
                .disabled(!accepts(draft))
        }
    }

    private func apply() {
        let id = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(id) else { return }
        commit(id)
        draft = ""
    }
}
