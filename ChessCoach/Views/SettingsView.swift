import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var apiKey = ""
    @State private var discoveredModels: [String] = []
    @State private var status: InferenceTestStatus = .idle
    @State private var isWorking = false
    @State private var showsThirdPartyNotices = false

    private var settings: InferenceSettings { appModel.inferenceSettings }
    private let inference = ModelInferenceClient()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(InferenceProviderKind.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .onChange(of: settings.provider) {
                    apiKey = ""
                    discoveredModels = []
                    status = .idle
                    appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
                }

                if settings.provider == .customOpenAICompatible {
                    TextField("Endpoint URL", text: $settings.customEndpoint)
                        .onSubmit {
                            appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
                        }
                } else {
                    LabeledContent("Endpoint", value: "https://api.openai.com")
                }

                SecureField(
                    settings.hasStoredKey
                        ? "New API key (a key is already stored)"
                        : (settings.provider.requiresCredential
                            ? "API key"
                            : "API key (optional)"),
                    text: $apiKey
                )
                .textContentType(.password)

                HStack {
                    if settings.hasStoredKey {
                        Label("API key stored in Keychain", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No API key stored", systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Typed Key") {
                        saveTypedKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if settings.hasStoredKey {
                        Button("Remove Key", role: .destructive) {
                            removeKey()
                        }
                    }
                }

                TextField("Model ID", text: $settings.modelID)
                    .onSubmit {
                        appModel.coordinator
                            .refreshPreparedCoachingForCurrentPosition()
                    }

                DisclosureGroup("Advanced") {
                    Picker("API mode", selection: $settings.apiMode) {
                        ForEach(InferenceAPIMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(
                        "Automatic prefers the Responses API and uses Chat Completions "
                            + "only when the endpoint reports that Responses is unsupported."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !discoveredModels.isEmpty {
                    Menu("Choose from \(discoveredModels.count) discovered models") {
                        ForEach(discoveredModels, id: \.self) { model in
                            Button(model) {
                                settings.modelID = model
                                appModel.coordinator
                                    .refreshPreparedCoachingForCurrentPosition()
                            }
                        }
                    }
                }

                HStack {
                    Button("Validate Configuration") {
                        run(success: "Configuration is valid.") {
                            try inference.validate(
                                configuration: settings.configuration,
                                credential: settings.keyForRequest(typedKey: apiKey)
                            )
                        }
                    }
                    Button("Discover Models") {
                        run(success: "Model discovery finished.") {
                            discoveredModels = try await inference.listModels(
                                configuration: settings.configuration,
                                credential: settings.keyForRequest(typedKey: apiKey)
                            )
                        }
                    }
                    Button("Test Selected Model") {
                        run(success: "\(settings.modelID) is accessible.") {
                            try await inference.testModel(
                                configuration: settings.configuration,
                                credential: settings.keyForRequest(typedKey: apiKey)
                            )
                            appModel.coordinator
                                .refreshPreparedCoachingForCurrentPosition()
                        }
                    }
                }
                .disabled(isWorking)

                statusView

                Text(
                    "Tests use the key currently typed above before the stored key. "
                        + "The typed key is not saved unless you choose Save Typed Key. "
                        + "Model discovery can be incomplete, so the manual model ID always remains available. "
                        + "When configured, the provider receives the current coaching "
                        + "context for background hint preparation and explicit chat requests."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Coaching") {
                LabeledContent("Hint behavior", value: "Concept first, move on reveal")
                LabeledContent("Engine authority", value: "Stockfish selects all recommended moves")
                LabeledContent("Language model", value: settings.modelID)
                LabeledContent("Privacy", value: "No accounts, telemetry, ads, or cloud sync")
            }

            Section("Engine and licenses") {
                LabeledContent("Opponent", value: "Stockfish 18 · Levels 1–10")
                LabeledContent("Analysis", value: "Separate full-strength process")
                Text(
                    "Stockfish runs as a separate GPLv3 executable over UCI. "
                        + "Its source and build provenance, plus ChessKit's MIT license, "
                        + "are included with the app."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Third-Party Notices…") {
                    showsThirdPartyNotices = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .padding(16)
        .sheet(isPresented: $showsThirdPartyNotices) {
            ThirdPartyNoticesView()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func saveTypedKey() {
        do {
            try settings.saveKey(apiKey)
            apiKey = ""
            appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
            status = .success("API key saved securely in Keychain.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func removeKey() {
        do {
            try settings.removeKey()
            apiKey = ""
            appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
            status = .success("The stored API key was removed.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func run(
        success: String,
        _ work: @escaping @MainActor () async throws -> Void
    ) {
        isWorking = true
        status = .working("Contacting model provider…")
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await work()
                status = .success(success)
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}

enum InferenceTestStatus: Equatable {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}
