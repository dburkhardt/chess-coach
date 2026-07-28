import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var profile: LearnerProfile
    var complete: () -> Void

    @State private var step = 1
    @State private var inferenceKey = ""
    @State private var discoveredModels: [String] = []
    @State private var status: InferenceTestStatus = .idle
    @State private var isWorking = false

    private var settings: InferenceSettings { appModel.inferenceSettings }
    private let inference = ModelInferenceClient()

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                Text("Step \(step) of 2")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if step == 1 {
                experienceStep
            } else {
                inferenceStep(settings: settings)
            }
        }
        .padding(32)
        .frame(width: 680, height: 650, alignment: .topLeading)
    }

    private var experienceStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Chess Coach")
                    .font(.largeTitle.bold())
                Text(
                    "Choose the starting point for your explanations. "
                        + "The coach will adapt as it reviews your games."
                )
                .foregroundStyle(.secondary)
            }

            Picker(
                "Experience",
                selection: Binding(
                    get: { profile.experience },
                    set: { profile.experience = $0 }
                )
            ) {
                ForEach(ExperienceLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                let range = profile.experience.initialRange
                Text(
                    "Initial coaching range: \(range.lowerBound)–\(range.upperBound). "
                        + "This stays labeled Calibrating until five eligible games."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            HStack {
                Text("You can change this later in Progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue") {
                    withAnimation {
                        step = 2
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func inferenceStep(settings: InferenceSettings) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional inference-powered coaching")
                    .font(.largeTitle.bold())
                Text(
                    "Stockfish play, analysis, arrows, and deterministic hints work "
                        + "without an inference provider. When configured, your selected provider "
                        + "receives the current coaching context for background hint "
                        + "preparation and explicit chat requests."
                )
                .foregroundStyle(.secondary)
            }

            Picker("Provider", selection: $settings.provider) {
                ForEach(InferenceProviderKind.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .onChange(of: settings.provider) {
                inferenceKey = ""
                discoveredModels = []
                status = .idle
            }

            if settings.provider == .customOpenAICompatible {
                TextField("Endpoint URL", text: $settings.customEndpoint)
            } else {
                LabeledContent("Endpoint", value: "https://api.openai.com")
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
            .accessibilityIdentifier("onboarding-inference-key-field")

            credentialStatus(settings: settings)

            if settings.credentialPersistenceAvailability == .sessionOnly {
                Text(
                    "This development or relocated build keeps inference keys "
                        + "in memory for this session only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            TextField("Model ID", text: $settings.modelID)

            DisclosureGroup("Advanced") {
                Picker("API mode", selection: $settings.apiMode) {
                    ForEach(InferenceAPIMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            if !discoveredModels.isEmpty {
                Menu("Choose from \(discoveredModels.count) discovered models") {
                    ForEach(discoveredModels, id: \.self) { model in
                        Button(model) {
                            settings.modelID = model
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
                    }
                }
            }
            .disabled(isWorking)

            statusView

            Text(
                "Tests use the typed inference key without saving it. Model discovery is optional, "
                    + "so a manually entered model ID remains usable."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Button("Back") {
                    withAnimation {
                        step = 1
                    }
                }

                Spacer()

                if !inferenceKey
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    if settings.credentialPersistenceAvailability == .persistent {
                        Button("Use for This Session & Start") {
                            useForSessionAndComplete()
                        }
                        .buttonStyle(.bordered)

                        Button("Save Inference Key & Start") {
                            saveAndComplete()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Use for This Session & Start") {
                            useForSessionAndComplete()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if settings.isConfigured {
                    Button("Start Learning", action: complete)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Without Inference", action: complete)
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func credentialStatus(
        settings: InferenceSettings
    ) -> some View {
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
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var explanation: String {
        switch profile.experience {
        case .beginner:
            "Start with threats, loose pieces, development, king safety, and simple plans."
        case .developing:
            "Assume the basic principles and add candidate moves, tactics, and pawn structure."
        case .intermediate:
            "Emphasize calculation, positional tradeoffs, move order, and practical plans."
        case .advanced:
            "Use concise engine-grounded explanations with deeper strategic and tactical detail."
        }
    }

    private func saveAndComplete() {
        do {
            try settings.savePersistentKey(inferenceKey)
            inferenceKey = ""
            complete()
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func useForSessionAndComplete() {
        settings.useKeyForSession(inferenceKey)
        inferenceKey = ""
        complete()
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
