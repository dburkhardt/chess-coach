import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var inferenceKey = ""
    @State private var discoveredModels: [String] = []
    @State private var status: InferenceTestStatus = .idle
    @State private var isWorking = false
    @State private var showsThirdPartyNotices = false
    @State private var handledNavigationRequestID: UUID?
    @FocusState private var focusedField: FocusedField?

    private var settings: InferenceSettings { appModel.inferenceSettings }
    private let inference = ModelInferenceClient()

    private enum FocusedField: Hashable {
        case inferenceKey
    }

    var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
            Form {
                Section("Inference provider") {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(InferenceProviderKind.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .onChange(of: settings.provider) {
                        inferenceKey = ""
                        discoveredModels = []
                        status = .idle
                        appModel.coordinator
                            .refreshPreparedCoachingForCurrentPosition()
                    }

                    if settings.provider == .customOpenAICompatible {
                        TextField(
                            "Endpoint URL",
                            text: $settings.customEndpoint
                        )
                        .onSubmit {
                            appModel.coordinator
                                .refreshPreparedCoachingForCurrentPosition()
                        }
                    } else {
                        LabeledContent(
                            "Endpoint",
                            value: "https://api.openai.com"
                        )
                    }

                    SecureField(
                        settings.hasStoredKey
                            ? "New inference key (a key is already stored)"
                            : (settings.provider.requiresCredential
                                ? "Inference key"
                                : "Inference key (optional)"),
                        text: $inferenceKey
                    )
                    .textContentType(.password)
                    .focused($focusedField, equals: .inferenceKey)
                    .accessibilityIdentifier("inference-key-field")

                    HStack {
                        credentialStatus
                        Spacer()

                        Button("Use for This Session") {
                            useTypedKeyForSession()
                        }
                        .disabled(
                            inferenceKey
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                        )

                        if settings.credentialPersistenceAvailability
                            == .persistent {
                            Button("Save Inference Key") {
                                saveTypedKey()
                            }
                            .disabled(
                                inferenceKey
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                            )
                        }

                        if settings.credentialState != .missing ||
                            settings.hasStoredKey {
                            Button(
                                "Remove Inference Key",
                                role: .destructive
                            ) {
                                removeKey()
                            }
                        }
                    }

                    if settings.credentialPersistenceAvailability
                        == .sessionOnly {
                        Text(
                            "This development or relocated build keeps inference "
                                + "keys in memory for this session only. The signed "
                                + "app installed in Applications can store them in "
                                + "macOS Keychain."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            "Automatic prefers the Responses API and uses Chat "
                                + "Completions only when the endpoint reports that "
                                + "Responses is unsupported."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !discoveredModels.isEmpty {
                        Menu(
                            "Choose from \(discoveredModels.count) discovered models"
                        ) {
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
                                    credential: settings.keyForRequest(
                                        typedKey: inferenceKey
                                    )
                                )
                            }
                        }
                        Button("Discover Models") {
                            run(success: "Model discovery finished.") {
                                discoveredModels = try await inference.listModels(
                                    configuration: settings.configuration,
                                    credential: settings.keyForRequest(
                                        typedKey: inferenceKey
                                    )
                                )
                            }
                        }
                        Button("Test Selected Model") {
                            run(success: "\(settings.modelID) is accessible.") {
                                try await inference.testModel(
                                    configuration: settings.configuration,
                                    credential: settings.keyForRequest(
                                        typedKey: inferenceKey
                                    )
                                )
                                appModel.coordinator
                                    .refreshPreparedCoachingForCurrentPosition()
                            }
                        }
                    }
                    .disabled(isWorking)

                    statusView

                    Text(
                        "Tests use the inference key currently typed above before "
                            + "the session or stored key. The typed key is not kept "
                            + "unless you choose a key action. Model discovery can "
                            + "be incomplete, so the manual model ID always remains "
                            + "available. When configured, the provider receives the "
                            + "current coaching context for background hint "
                            + "preparation and explicit chat requests."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .id(SettingsDestination.inference)

                Section("Coaching") {
                    LabeledContent(
                        "Hint behavior",
                        value: "Concept first, move on reveal"
                    )
                    LabeledContent(
                        "Engine authority",
                        value: "Stockfish selects all recommended moves"
                    )
                    LabeledContent(
                        "Language model",
                        value: settings.modelID
                    )
                    LabeledContent(
                        "Privacy",
                        value: "No accounts, telemetry, ads, or cloud sync"
                    )
                }

                Section("Engine and licenses") {
                    LabeledContent(
                        "Opponent",
                        value: "Stockfish 18 · Levels 1–10"
                    )
                    LabeledContent(
                        "Analysis",
                        value: "Separate full-strength process"
                    )
                    Text(
                        "Stockfish runs as a separate GPLv3 executable over UCI. "
                            + "Its source and build provenance, plus ChessKit's MIT "
                            + "license, are included with the app."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Third-Party Notices…") {
                        showsThirdPartyNotices = true
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                handleNavigationRequest(using: proxy)
            }
            .onChange(of: appModel.settingsNavigationRequest?.id) {
                handleNavigationRequest(using: proxy)
            }
        }
        .navigationTitle("Settings")
        .padding(16)
        .sheet(isPresented: $showsThirdPartyNotices) {
            ThirdPartyNoticesView()
        }
    }

    @ViewBuilder
    private var credentialStatus: some View {
        switch settings.credentialState {
        case .missing:
            Label(
                "No inference key configured",
                systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(.secondary)
        case .sessionOnly:
            Label(
                "Using an inference key for this session",
                systemImage: "clock.badge.checkmark"
            )
            .foregroundStyle(.secondary)
        case .stored:
            Label(
                "Inference key stored securely",
                systemImage: "key.fill"
            )
            .foregroundStyle(.secondary)
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

    private func handleNavigationRequest(
        using proxy: ScrollViewProxy
    ) {
        guard let request = appModel.settingsNavigationRequest,
              request.destination == .inference,
              handledNavigationRequestID != request.id
        else {
            return
        }
        handledNavigationRequestID = request.id
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(SettingsDestination.inference, anchor: .top)
            focusedField = .inferenceKey
        }
    }

    private func useTypedKeyForSession() {
        settings.useKeyForSession(inferenceKey)
        inferenceKey = ""
        appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
        status = .success("Inference key is available for this session.")
    }

    private func saveTypedKey() {
        do {
            try settings.savePersistentKey(inferenceKey)
            inferenceKey = ""
            appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
            status = .success(
                "Inference key saved securely in Keychain."
            )
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func removeKey() {
        do {
            try settings.removeKey()
            inferenceKey = ""
            appModel.coordinator.refreshPreparedCoachingForCurrentPosition()
            status = .success("The configured inference key was removed.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func run(
        success: String,
        _ work: @escaping @MainActor () async throws -> Void
    ) {
        isWorking = true
        status = .working("Contacting inference provider…")
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
