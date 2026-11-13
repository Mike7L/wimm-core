#if os(iOS)
import SwiftUI
import WimmDomain
import WimmInfrastructure

/// Debug switches for the battery measurement
/// (`docs/iOS_Battery_Measurement_Plan_2026-11-12.md`). Everything is off by
/// default; changes apply to the next recording. Not localized on purpose: it is
/// a developer tool, not a user setting.
private struct BatteryDiagnosticsSection: View {
    @AppStorage(BatteryDiagnosticsSettings.logKey) private var logOn = false
    @AppStorage(BatteryDiagnosticsSettings.disableLiveTextKey) private var noLiveText = false
    @AppStorage(BatteryDiagnosticsSettings.disableLevelMeterKey) private var noMeter = false
    @AppStorage(BatteryDiagnosticsSettings.quietLiveLogKey) private var quietLog = false
    @AppStorage(BatteryDiagnosticsSettings.slowAutosaveKey) private var slowSave = false
    @State private var logs: [URL] = []

    var body: some View {
        Section {
            Toggle("Журнал батареи (раз в минуту)", isOn: $logOn)
            Toggle("Без живого текста", isOn: $noLiveText)
            Toggle("Без индикатора уровня (10 Гц)", isOn: $noMeter)
            Toggle("Без строки лога на каждый фрагмент", isOn: $quietLog)
            Toggle("Автосохранение раз в 60 с", isOn: $slowSave)
            ForEach(logs, id: \.self) { url in
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Диагностика батареи")
        } footer: {
            Text("Для замера расхода батареи во время записи. Действует со следующей записи. Без живого текста заметка сохраняется без текста, услышанного во время записи.")
        }
        .onAppear { logs = BatteryProbe.existingLogs() }
    }
}

/// API keys and the default model for manual re-transcription.
struct ModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var geminiKey = ""
    @State private var openRouterKey = ""
    @State private var hasGeminiKey = false
    @State private var hasOpenRouterKey = false
    @State private var transcribeModel = Config.transcribeModel
    @State private var microphone = RecordingMicrophonePreference.load()

    private static let geminiKeyName = "GEMINI_API_KEY"
    private static let openRouterKeyName = "OPENROUTER_API_KEY"

    /// Every place the rotators read a key from (single and list form, Keychain
    /// and defaults). "Saved" and "Remove" must cover all of them, or a stale
    /// key from an old install keeps being used while the screen says "none".
    private static func storedNames(_ keyName: String) -> [String] {
        [keyName, keyName + "S"]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ModelPickerView(title: L10n.iOS.Settings.transcriptionModel, audioOnly: true, selection: $transcribeModel)
                    } label: {
                        LabeledContent(L10n.iOS.Settings.transcriptionModel, value: transcribeModel)
                    }
                } header: {
                    Text(L10n.iOS.Settings.modelsHeader)
                } footer: {
                    Text(L10n.iOS.Settings.modelsFooter)
                }

                Section {
                    Picker(L10n.iOS.Settings.microphone, selection: $microphone) {
                        Text(L10n.iOS.Settings.microphoneBluetooth).tag(RecordingMicrophonePreference.bluetoothWhenConnected)
                        Text(L10n.iOS.Settings.microphoneBuiltIn).tag(RecordingMicrophonePreference.builtInOnly)
                    }
                } header: {
                    Text(L10n.iOS.Settings.microphoneHeader)
                } footer: {
                    Text(L10n.iOS.Settings.microphoneFooter)
                }

                keySection(
                    title: "Gemini",
                    key: $geminiKey,
                    isSaved: hasGeminiKey,
                    keyName: Self.geminiKeyName,
                    footer: L10n.iOS.Settings.geminiFooter
                )
                keySection(
                    title: "OpenRouter",
                    key: $openRouterKey,
                    isSaved: hasOpenRouterKey,
                    keyName: Self.openRouterKeyName,
                    footer: L10n.iOS.Settings.openRouterFooter
                )

                BatteryDiagnosticsSection()
            }
            .navigationTitle(L10n.iOS.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .onAppear(perform: refreshSavedState)
            .onChange(of: transcribeModel) { _, value in ModelSelection.setModel(value, for: .hear) }
            .onChange(of: microphone) { _, value in value.save() }
        }
    }

    private func keySection(
        title: String,
        key: Binding<String>,
        isSaved: Bool,
        keyName: String,
        footer: String
    ) -> some View {
        Section {
            if isSaved {
                Label(L10n.iOS.Settings.keySaved, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button(L10n.iOS.Settings.removeKey, role: .destructive) {
                    for name in Self.storedNames(keyName) {
                        APIKeySecureStore.delete(name)
                        UserDefaults.standard.removeObject(forKey: name)
                    }
                    refreshSavedState()
                }
            } else {
                SecureField(L10n.iOS.Settings.pasteKey, text: key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.iOS.Settings.saveKey) {
                    APIKeySecureStore.write(key.wrappedValue, for: keyName)
                    key.wrappedValue = ""
                    refreshSavedState()
                }
                .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    /// Asks the rotators themselves, so the screen shows exactly what a
    /// re-run would use.
    private func refreshSavedState() {
        Task {
            hasGeminiKey = await ConfiguredKeys.gemini()
            hasOpenRouterKey = await ConfiguredKeys.openRouter()
        }
    }
}

/// The models the saved keys can reach, fetched from each provider's catalog.
/// OpenRouter's list is long, hence the search; a model id can also be typed.
private struct ModelPickerView: View {
    let title: String
    let audioOnly: Bool
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var gemini: [String] = []
    @State private var openRouter: [String] = []
    @State private var query = ""
    @State private var loadError: String?
    @State private var isLoading = true

    private func filtered(_ ids: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? ids : ids.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, !gemini.contains(typed), !openRouter.contains(typed) {
                Section {
                    row(typed, label: L10n.iOS.Settings.useTypedModel(typed))
                }
            }
            // On-device Parakeet needs no key, so it is offered even before the cloud lists load.
            if audioOnly, typed.isEmpty {
                Section {
                    row(ParakeetModel.ultra, label: "Parakeet Ultra")
                } header: {
                    Text(L10n.iOS.Settings.onDeviceModels)
                } footer: {
                    Text(L10n.iOS.Settings.parakeetFooter)
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
            }
            if !filtered(gemini).isEmpty {
                Section("Gemini") { ForEach(filtered(gemini), id: \.self) { row($0) } }
            }
            if !filtered(openRouter).isEmpty {
                Section("OpenRouter") { ForEach(filtered(openRouter), id: \.self) { row($0) } }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: Text(L10n.iOS.Settings.searchModels))
        .task { await load() }
    }

    private func row(_ id: String, label: String? = nil) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Text(label ?? id).foregroundStyle(.primary)
                Spacer()
                if id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func load() async {
        defer { isLoading = false }
        var errors: [String] = []
        if await ConfiguredKeys.gemini() {
            do {
                gemini = try await GeminiModelsAPI.fetch().map(\.id).sorted()
            } catch {
                errors.append("Gemini: \(error.localizedDescription)")
            }
        }
        if await ConfiguredKeys.openRouter() {
            do {
                openRouter = try await OpenRouterModelsAPI.fetch()
                    .filter { !audioOnly || $0.isAudioCapable == true }
                    .map(\.id)
                    .sorted()
            } catch {
                errors.append("OpenRouter: \(error.localizedDescription)")
            }
        }
        if gemini.isEmpty, openRouter.isEmpty, errors.isEmpty {
            errors.append(L10n.iOS.Settings.noKeysForModels)
        }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
#endif
