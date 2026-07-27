import Foundation
import Synchronization

enum InferenceError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case missingKey
    case missingModel
    case invalidCredentials
    case modelAccessDenied(model: String, status: Int)
    case timeout
    case offline
    case cancelled
    case malformedStream
    case streamFailed(message: String)
    case server(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The model endpoint is invalid."
        case .missingKey:
            "Add an API key in Settings."
        case .missingModel:
            "Choose or enter a model in Settings."
        case .invalidCredentials:
            "The API key was not accepted."
        case .modelAccessDenied(let model, _):
            "Your key is valid but does not have access to \(model)."
        case .timeout:
            "Model inference timed out. Stockfish coaching is still available."
        case .offline:
            "Model inference is unavailable while this Mac is offline."
        case .cancelled:
            "The coaching request was cancelled."
        case .malformedStream:
            "The model provider returned an incomplete streaming response."
        case .streamFailed(let message):
            "Model inference stopped before finishing: \(message)"
        case .server(let status, let message):
            status > 0
                ? "The model provider returned \(status): \(message)"
                : "Model inference failed: \(message)"
        case .invalidResponse:
            "The inference response could not be read."
        }
    }
}

struct InferenceMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String
}

final class InferenceCapabilityCache: Sendable {
    private let modes = Mutex<[String: InferenceAPIMode]>([:])

    func mode(for endpoint: String) -> InferenceAPIMode? {
        modes.withLock { $0[endpoint] }
    }

    func set(_ mode: InferenceAPIMode, for endpoint: String) {
        modes.withLock { $0[endpoint] = mode }
    }
}

struct ModelInferenceClient: Sendable {

    private let session: URLSession
    private let capabilityCache: InferenceCapabilityCache

    init(
        session: URLSession = .shared,
        capabilityCache: InferenceCapabilityCache = InferenceCapabilityCache()
    ) {
        self.session = session
        self.capabilityCache = capabilityCache
    }

    func validate(configuration: InferenceConfiguration, credential: String) throws {
        _ = try normalizedConfiguration(configuration, credential: credential)
    }

    func listModels(
        configuration: InferenceConfiguration,
        credential: String
    ) async throws -> [String] {
        let normalized = try normalizedConfiguration(configuration, credential: credential)
        guard let url = endpoint(baseURL: normalized.configuration.baseURL, path: "/v1/models") else {
            throw InferenceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        applyAuthorization(normalized.credential, to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            try validate(
                response: response,
                data: data,
                selectedModel: nil,
                credentialKnownValid: false,
                isCredentialValidation: false,
                key: normalized.credential
            )
            guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
                throw InferenceError.invalidResponse
            }
            return Array(Set(decoded.data.map(\.id))).sorted()
        } catch {
            throw Self.mapTransportError(error, key: normalized.credential)
        }
    }

    func testModel(
        configuration: InferenceConfiguration,
        credential: String
    ) async throws {
        let normalized = try normalizedConfiguration(configuration, credential: credential)
        let input = [InferenceMessage(role: "user", content: "Reply with OK.")]
        let text = try await complete(
            configuration: normalized.configuration,
            credential: normalized.credential,
            input: input,
            maxOutputTokens: 16
        )
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceError.invalidResponse
        }
    }

    /// GameCoordinator-facing API. Stockfish chooses the move; this method only
    /// explains the supplied recommendation and validates the structured reply.
    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        let normalized = try normalizedConfiguration(configuration, credential: credential)
        let configuration = normalized.configuration
        let credential = normalized.credential
        let input = try hintInput(context: context)

        do {
            let raw = try await complete(
                configuration: configuration,
                credential: credential,
                input: input,
                maxOutputTokens: 450,
                preferStructuredResponse: true,
                structuredHintMove: context.recommendedMove
            )
            return try decodeHint(raw, context: context, model: configuration.modelID)
        } catch {
            let mapped = Self.mapTransportError(error, key: credential)
            guard Self.shouldRetryStructuredOutput(after: mapped) else {
                throw mapped
            }

            let raw = try await completeAfterStructuredFailure(
                configuration: configuration,
                credential: credential,
                input: input,
                maxOutputTokens: 450
            )
            return try decodeHint(raw, context: context, model: configuration.modelID)
        }
    }

    private func hintInput(context: CoachContext) throws -> [InferenceMessage] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contextData = try encoder.encode(context)
        let contextJSON = String(decoding: contextData, as: UTF8.self)

        let system = """
        You are Chess Coach, a patient chess teacher. Stockfish is authoritative.
        Never choose a move yourself and never contradict the supplied recommendedMove.
        Explain only ideas supported by the supplied facts and principal variations.
        The recommendedMoveFacts object describes the purpose and concrete effects
        of Stockfish's move. Every explanation field must explain those move-specific
        facts. In particular, the concept must express recommendedMoveFacts.teachingTheme
        without naming the move. Do not substitute a generic check, capture, development,
        or opening principle merely because it is available elsewhere in the position.
        Match the learner's level. The concept field must not reveal the move, its
        origin square, destination square, UCI, or SAN. Return only valid JSON with
        exactly these keys: recommendedMove, concept, why, plan, likelyReply, watchFor.
        Copy recommendedMove exactly from the context. Do not include markdown fences.
        Keep each explanation field concise and use one or two plain sentences.
        """
        let user = """
        Explain the engine recommendation for this position.
        The app will reveal the exact move separately after the concept hint.
        Context:
        \(contextJSON)
        """
        return [
            InferenceMessage(role: "system", content: system),
            InferenceMessage(role: "user", content: user),
        ]
    }

    /// GameCoordinator-facing API. Text deltas are yielded as
    /// `response.output_text.delta` events arrive.
    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, Error> {
        do {
            let contextData = try JSONEncoder().encode(context)
            let contextJSON = String(decoding: contextData, as: UTF8.self)
            var input = [
                InferenceMessage(
                    role: "system",
                    content: """
                    You are a grounded chess coach. Stockfish is authoritative.
                    Use only the supplied legal moves and principal variations for
                    concrete calculation. Explain ideas at the learner's level.
                    Use plain prose only. Do not emit Markdown headings, emphasis,
                    bullets, code fences, tables, or links.
                    Current grounded context: \(contextJSON)
                    """
                )
            ]
            input.append(contentsOf: history.suffix(12).compactMap { message in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                switch message.role {
                case .user:
                    return InferenceMessage(role: "user", content: text)
                case .coach:
                    return InferenceMessage(role: "assistant", content: text)
                case .system:
                    return nil
                }
            })

            let normalized = try normalizedConfiguration(configuration, credential: credential)
            return automaticStream(
                configuration: normalized.configuration,
                credential: normalized.credential,
                input: input,
                maxOutputTokens: 900
            )
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    /// Returns a complete semantic reply. The first request asks the Responses
    /// API to enforce the local JSON schema. Some compatible model adapters
    /// do not expose `text.format`, so schema/protocol failures retry once as a
    /// non-streaming, prompt-constrained request. Partial streamed JSON is never
    /// decoded or persisted.
    func generateReply(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) async throws -> CoachReply {
        let normalized = try normalizedConfiguration(configuration, credential: credential)
        let configuration = normalized.configuration
        let credential = normalized.credential
        let input = try coachReplyInput(context: context, history: history)
        do {
            let raw = try await complete(
                configuration: configuration,
                credential: credential,
                input: input,
                maxOutputTokens: 1_000,
                preferStructuredResponse: true,
                structuredReply: true
            )
            return try decodeReply(raw, context: context)
        } catch {
            let mapped = Self.mapTransportError(error, key: credential)
            guard Self.shouldRetryStructuredOutput(after: mapped) else {
                throw mapped
            }

            let raw = try await completeAfterStructuredFailure(
                configuration: configuration,
                credential: credential,
                input: input,
                maxOutputTokens: 1_000
            )
            return try decodeReply(raw, context: context)
        }
    }

    private func complete(
        configuration: InferenceConfiguration,
        credential: String,
        input: [InferenceMessage],
        maxOutputTokens: Int,
        preferStructuredResponse: Bool = false,
        structuredReply: Bool = false,
        structuredHintMove: String? = nil
    ) async throws -> String {
        let mode = effectiveMode(for: configuration)
        switch mode {
        case .responses:
            return try await collectResponseStream(
                baseURL: configuration.baseURL,
                key: credential,
                model: configuration.modelID,
                input: input,
                maxOutputTokens: maxOutputTokens,
                structuredReply: preferStructuredResponse && structuredReply,
                structuredHintMove: preferStructuredResponse ? structuredHintMove : nil
            )
        case .chatCompletions:
            return try await chatCompletion(
                baseURL: configuration.baseURL,
                key: credential,
                model: configuration.modelID,
                messages: input,
                maxTokens: maxOutputTokens,
                isCredentialValidation: false
            )
        case .automatic:
            do {
                let text = try await collectResponseStream(
                    baseURL: configuration.baseURL,
                    key: credential,
                    model: configuration.modelID,
                    input: input,
                    maxOutputTokens: maxOutputTokens,
                    structuredReply: preferStructuredResponse && structuredReply,
                    structuredHintMove: preferStructuredResponse ? structuredHintMove : nil
                )
                capabilityCache.set(.responses, for: capabilityKey(configuration.baseURL))
                return text
            } catch {
                let mapped = Self.mapTransportError(error, key: credential)
                guard Self.isUnsupportedProtocol(mapped) else { throw mapped }
                let text = try await chatCompletion(
                    baseURL: configuration.baseURL,
                    key: credential,
                    model: configuration.modelID,
                    messages: input,
                    maxTokens: maxOutputTokens,
                    isCredentialValidation: false
                )
                capabilityCache.set(.chatCompletions, for: capabilityKey(configuration.baseURL))
                return text
            }
        }
    }

    private func completeAfterStructuredFailure(
        configuration: InferenceConfiguration,
        credential: String,
        input: [InferenceMessage],
        maxOutputTokens: Int
    ) async throws -> String {
        if effectiveMode(for: configuration) == .chatCompletions {
            return try await chatCompletion(
                baseURL: configuration.baseURL,
                key: credential,
                model: configuration.modelID,
                messages: input,
                maxTokens: maxOutputTokens,
                isCredentialValidation: false
            )
        }
        return try await completeResponse(
            baseURL: configuration.baseURL,
            key: credential,
            model: configuration.modelID,
            input: input,
            maxOutputTokens: maxOutputTokens,
            structuredReply: false
        )
    }

    private func automaticStream(
        configuration: InferenceConfiguration,
        credential: String,
        input: [InferenceMessage],
        maxOutputTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let mode = effectiveMode(for: configuration)
                    if mode == .chatCompletions {
                        for try await chunk in chatCompletionsStream(
                            baseURL: configuration.baseURL,
                            key: credential,
                            model: configuration.modelID,
                            messages: input,
                            maxTokens: maxOutputTokens
                        ) {
                            continuation.yield(chunk)
                        }
                    } else {
                        do {
                            for try await chunk in responsesStream(
                                baseURL: configuration.baseURL,
                                key: credential,
                                model: configuration.modelID,
                                input: input,
                                maxOutputTokens: maxOutputTokens,
                                credentialKnownValid: false
                            ) {
                                continuation.yield(chunk)
                            }
                            if configuration.apiMode == .automatic {
                                capabilityCache.set(
                                    .responses,
                                    for: capabilityKey(configuration.baseURL)
                                )
                            }
                        } catch {
                            let mapped = Self.mapTransportError(error, key: credential)
                            guard configuration.apiMode == .automatic,
                                  Self.isUnsupportedProtocol(mapped)
                            else {
                                throw mapped
                            }
                            for try await chunk in chatCompletionsStream(
                                baseURL: configuration.baseURL,
                                key: credential,
                                model: configuration.modelID,
                                messages: input,
                                maxTokens: maxOutputTokens
                            ) {
                                continuation.yield(chunk)
                            }
                            capabilityCache.set(
                                .chatCompletions,
                                for: capabilityKey(configuration.baseURL)
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: Self.mapTransportError(error, key: credential)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func effectiveMode(for configuration: InferenceConfiguration) -> InferenceAPIMode {
        guard configuration.apiMode == .automatic else {
            return configuration.apiMode
        }
        return capabilityCache.mode(for: capabilityKey(configuration.baseURL)) ?? .automatic
    }

    private func capabilityKey(_ baseURL: String) -> String {
        endpoint(baseURL: baseURL, path: "")?.absoluteString
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isUnsupportedProtocol(_ error: InferenceError) -> Bool {
        let statuses = [404, 405, 415, 501]
        switch error {
        case .server(let status, _):
            return statuses.contains(status)
        case .modelAccessDenied(_, let status):
            return statuses.contains(status)
        default:
            return false
        }
    }

    /// Internal for request-shape tests. The Authorization value is never
    /// logged, persisted, or placed in an error.
    func makeResponsesRequest(
        baseURL: String,
        key: String,
        model: String,
        input: [InferenceMessage],
        maxOutputTokens: Int,
        structuredReply: Bool = false,
        structuredHintMove: String? = nil,
        stream: Bool = true
    ) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try normalizedModel(model)
        guard let url = endpoint(baseURL: baseURL, path: "/v1/responses") else {
            throw InferenceError.invalidEndpoint
        }
        let nonemptyInput = input.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonemptyInput.isEmpty else { throw InferenceError.invalidResponse }

        let textConfiguration = structuredHintMove.map {
            ResponsesTextConfiguration.hint(recommendedMove: $0)
        } ?? (structuredReply ? .coachReply : nil)
        let body = ResponsesRequest(
            model: model,
            input: nonemptyInput,
            maxOutputTokens: max(1, maxOutputTokens),
            stream: stream,
            text: textConfiguration
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        applyAuthorization(key, to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func decodeHint(_ raw: String, context: CoachContext, model: String) throws -> CoachHint {
        guard let data = Self.completeJSONObjectData(from: raw),
              let payload = try? JSONDecoder().decode(HintPayload.self, from: data)
        else {
            throw InferenceError.invalidResponse
        }
        try validateHint(payload, context: context)

        return CoachHint(
            concept: payload.concept,
            why: payload.why,
            plan: payload.plan,
            likelyReply: payload.likelyReply,
            watchFor: payload.watchFor,
            recommendedMove: context.recommendedMove,
            source: model
        )
    }

    func decodeReply(_ raw: String, context: CoachContext) throws -> CoachReply {
        guard let data = Self.completeJSONObjectData(from: raw),
              let decoded = try? JSONDecoder().decode(CoachReply.self, from: data),
              decoded.version == CoachReply.currentVersion,
              decoded.sections.count <= 3
        else {
            throw InferenceError.invalidResponse
        }

        let summary = CoachReplySanitizer.plainText(decoded.summary)
        guard !summary.isEmpty,
              summary.count <= 600,
              !CoachReplySanitizer.containsRawMarkdown(summary),
              !CoachReplySanitizer.containsMoveNotation(summary)
        else {
            throw InferenceError.invalidResponse
        }

        let validVariationRanks = Set(context.variations.map(\.rank))
        var sections: [CoachReplySection] = []
        for section in decoded.sections {
            let title = CoachReplySanitizer.plainText(section.title)
            let body = CoachReplySanitizer.plainText(section.body)
            guard !body.isEmpty,
                  title.count <= 80,
                  body.count <= 2_000,
                  !CoachReplySanitizer.containsRawMarkdown(title),
                  !CoachReplySanitizer.containsRawMarkdown(body),
                  !CoachReplySanitizer.containsMoveNotation(title),
                  !CoachReplySanitizer.containsMoveNotation(body)
            else {
                throw InferenceError.invalidResponse
            }

            var rank: Int?
            if section.kind == .variation {
                guard let suppliedRank = section.variationRank,
                      validVariationRanks.contains(suppliedRank)
                else {
                    throw InferenceError.invalidResponse
                }
                rank = suppliedRank
            }
            sections.append(
                CoachReplySection(
                    kind: section.kind,
                    title: title.isEmpty ? Self.defaultTitle(for: section.kind) : title,
                    body: body,
                    variationRank: rank
                )
            )
        }

        let reply = CoachReply(summary: summary, sections: sections)
        guard !reply.plainText.isEmpty, reply.plainText.count <= 8_000 else {
            throw InferenceError.invalidResponse
        }
        return reply
    }

    static func redact(_ message: String, secrets: [String] = []) -> String {
        var redacted = message
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        redacted = redacted.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"sk-[A-Za-z0-9_-]{6,}"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        return redacted
    }

    static func classifyHTTPError(
        status: Int,
        selectedModel: String?,
        credentialKnownValid: Bool,
        isCredentialValidation: Bool,
        message: String
    ) -> InferenceError {
        if status == 408 || status == 504 {
            return .timeout
        }
        if isCredentialValidation, status == 401 || status == 403 {
            return .invalidCredentials
        }
        if let selectedModel,
           status == 403 || status == 404 || (status == 401 && credentialKnownValid) {
            return .modelAccessDenied(model: selectedModel, status: status)
        }
        if status == 401 {
            return .invalidCredentials
        }
        return .server(status: status, message: message)
    }

    static func mapTransportError(_ error: Error, key: String = "") -> InferenceError {
        if let inferenceError = error as? InferenceError {
            return inferenceError
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timeout
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return .offline
            default:
                return .server(
                    status: 0,
                    message: redact(urlError.localizedDescription, secrets: [key])
                )
            }
        }
        return .server(
            status: 0,
            message: redact(error.localizedDescription, secrets: [key])
        )
    }

    private func coachReplyInput(
        context: CoachContext,
        history: [CoachMessage]
    ) throws -> [InferenceMessage] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contextData = try encoder.encode(context)
        let contextJSON = String(decoding: contextData, as: UTF8.self)
        var input = [
            InferenceMessage(
                role: "system",
                content: """
                You are Chess Coach, a patient and concise teacher. Stockfish is
                authoritative. Return one JSON object with version 1, a concise
                summary, and zero to 3 sections. The summary is a direct one- or
                two-sentence answer that stands on its own. Every section has
                kind, title, body, and variationRank.
                Allowed kinds: explanation, idea, plan, caution, variation.
                variationRank must be null except for a variation section, where
                it must reference a supplied Stockfish variation rank. Never put
                a move sequence in title or body; the app renders the referenced
                authoritative line. Use plain sentences only: no Markdown,
                headings, bullets, emphasis, code fences, tables, HTML, or links.
                Do not add keys and do not contradict the supplied engine data.
                Grounded context: \(contextJSON)
                """
            )
        ]

        input.append(contentsOf: history.suffix(12).compactMap { message in
            let text = CoachReplySanitizer.plainText(message.text)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return InferenceMessage(role: "user", content: text)
            case .coach:
                return InferenceMessage(role: "assistant", content: text)
            case .system:
                return nil
            }
        })
        if input.count == 1 {
            input.append(
                InferenceMessage(
                    role: "user",
                    content: "Explain the most important idea in this position."
                )
            )
        }
        return input
    }

    private func collectResponseStream(
        baseURL: String,
        key: String,
        model: String,
        input: [InferenceMessage],
        maxOutputTokens: Int,
        structuredReply: Bool = false,
        structuredHintMove: String? = nil
    ) async throws -> String {
        var result = ""
        for try await chunk in responsesStream(
            baseURL: baseURL,
            key: key,
            model: model,
            input: input,
            maxOutputTokens: maxOutputTokens,
            credentialKnownValid: false,
            structuredReply: structuredReply,
            structuredHintMove: structuredHintMove
        ) {
            try Task.checkCancellation()
            result += chunk
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceError.invalidResponse
        }
        return result
    }

    private func completeResponse(
        baseURL: String,
        key: String,
        model: String,
        input: [InferenceMessage],
        maxOutputTokens: Int,
        structuredReply: Bool
    ) async throws -> String {
        do {
            let request = try makeResponsesRequest(
                baseURL: baseURL,
                key: key,
                model: model,
                input: input,
                maxOutputTokens: maxOutputTokens,
                structuredReply: structuredReply,
                stream: false
            )
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            try validate(
                response: response,
                data: data,
                selectedModel: model,
                credentialKnownValid: false,
                isCredentialValidation: false,
                key: key
            )
            guard let envelope = try? JSONDecoder().decode(
                ResponsesCompleteEnvelope.self,
                from: data
            ) else {
                throw InferenceError.invalidResponse
            }
            if let message = envelope.error?.message {
                throw InferenceError.streamFailed(
                    message: Self.redact(message, secrets: [key])
                )
            }
            if let reason = envelope.incompleteDetails?.reason {
                throw InferenceError.streamFailed(
                    message: Self.redact(reason, secrets: [key])
                )
            }
            guard let text = envelope.extractedText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw InferenceError.invalidResponse
            }
            return text
        } catch {
            throw Self.mapTransportError(error, key: key)
        }
    }

    private static func shouldRetryStructuredOutput(after error: InferenceError) -> Bool {
        switch error {
        case .invalidResponse, .malformedStream, .streamFailed:
            return true
        case .server(let status, _):
            return status == 400 || status == 415 || status == 422
        default:
            return false
        }
    }

    private static func completeJSONObjectData(from raw: String) -> Data? {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }
        let candidate = String(cleaned[start...end])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return nil
        }
        return data
    }

    private static func defaultTitle(for kind: CoachReplySectionKind) -> String {
        switch kind {
        case .explanation: "Why it matters"
        case .idea: "What to notice"
        case .plan: "Plan"
        case .caution: "Watch for"
        case .variation: "Engine line"
        }
    }

    private func responsesStream(
        baseURL: String,
        key: String,
        model: String,
        input: [InferenceMessage],
        maxOutputTokens: Int,
        credentialKnownValid: Bool,
        structuredReply: Bool = false,
        structuredHintMove: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeResponsesRequest(
                        baseURL: baseURL,
                        key: key,
                        model: model,
                        input: input,
                        maxOutputTokens: maxOutputTokens,
                        structuredReply: structuredReply,
                        structuredHintMove: structuredHintMove
                    )
                    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedModel = try normalizedModel(model)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Task.checkCancellation()

                    guard let http = response as? HTTPURLResponse else {
                        throw InferenceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw Self.classifyHTTPError(
                            status: http.statusCode,
                            selectedModel: normalizedModel,
                            credentialKnownValid: credentialKnownValid,
                            isCredentialValidation: false,
                            message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                        )
                    }

                    var parser = ResponsesSSEParser()
                    var emittedText = false
                    var completed = false

                    eventLoop: for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let action = try parser.consume(line) else { continue }
                        switch action {
                        case .delta(let text):
                            guard !text.isEmpty else { continue }
                            emittedText = true
                            continuation.yield(text)
                        case .finalText(let text):
                            if !emittedText, !text.isEmpty {
                                emittedText = true
                                continuation.yield(text)
                            }
                        case .completed:
                            completed = true
                            break eventLoop
                        case .failed(let message):
                            throw InferenceError.streamFailed(
                                message: Self.redact(message, secrets: [normalizedKey])
                            )
                        }
                    }

                    if !completed, let finalAction = try parser.finish() {
                        switch finalAction {
                        case .delta(let text), .finalText(let text):
                            if !emittedText, !text.isEmpty {
                                emittedText = true
                                continuation.yield(text)
                            }
                        case .completed:
                            completed = true
                        case .failed(let message):
                            throw InferenceError.streamFailed(
                                message: Self.redact(message, secrets: [normalizedKey])
                            )
                        }
                    }

                    if parser.completionWasReceived {
                        completed = true
                    }
                    let acceptsValidatedEOF = structuredReply || structuredHintMove != nil
                    guard completed || (acceptsValidatedEOF && emittedText) else {
                        throw InferenceError.malformedStream
                    }
                    guard emittedText else { throw InferenceError.invalidResponse }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransportError(error, key: key))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func chatCompletion(
        baseURL: String,
        key: String,
        model: String,
        messages: [InferenceMessage],
        maxTokens: Int,
        isCredentialValidation: Bool
    ) async throws -> String {
        do {
            let request = try makeChatCompletionsRequest(
                baseURL: baseURL,
                key: key,
                model: model,
                messages: messages,
                maxTokens: maxTokens,
                stream: false
            )
            let (data, response) = try await session.data(for: request)
            try validate(
                response: response,
                data: data,
                selectedModel: isCredentialValidation ? nil : model,
                credentialKnownValid: false,
                isCredentialValidation: isCredentialValidation,
                key: key
            )
            guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let content = decoded.choices.first?.message.content,
                  !content.isEmpty
            else {
                throw InferenceError.invalidResponse
            }
            return content
        } catch {
            throw Self.mapTransportError(error, key: key)
        }
    }

    func makeChatCompletionsRequest(
        baseURL: String,
        key: String,
        model: String,
        messages: [InferenceMessage],
        maxTokens: Int,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = endpoint(baseURL: baseURL, path: "/v1/chat/completions") else {
            throw InferenceError.invalidEndpoint
        }
        let model = try normalizedModel(model)
        guard messages.contains(where: {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw InferenceError.invalidResponse
        }
        let body = ChatRequest(
            model: model,
            messages: messages,
            maxTokens: max(1, maxTokens),
            stream: stream
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        applyAuthorization(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func chatCompletionsStream(
        baseURL: String,
        key: String,
        model: String,
        messages: [InferenceMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeChatCompletionsRequest(
                        baseURL: baseURL,
                        key: key,
                        model: model,
                        messages: messages,
                        maxTokens: maxTokens,
                        stream: true
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw InferenceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw Self.classifyHTTPError(
                            status: http.statusCode,
                            selectedModel: model,
                            credentialKnownValid: false,
                            isCredentialValidation: false,
                            message: HTTPURLResponse.localizedString(
                                forStatusCode: http.statusCode
                            )
                        )
                    }
                    var emitted = false
                    var completed = false
                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5))
                            .trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            completed = true
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let envelope = try? JSONDecoder().decode(
                                ChatStreamEnvelope.self,
                                from: data
                              )
                        else {
                            throw InferenceError.malformedStream
                        }
                        for choice in envelope.choices {
                            if let delta = choice.delta.content, !delta.isEmpty {
                                emitted = true
                                continuation.yield(delta)
                            }
                            if choice.finishReason != nil {
                                completed = true
                            }
                        }
                    }
                    guard completed, emitted else {
                        throw emitted
                            ? InferenceError.malformedStream
                            : InferenceError.invalidResponse
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: Self.mapTransportError(error, key: key)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func endpoint(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(),
        scheme == "https" || (scheme == "http" && Self.isLoopback(host))
        else {
            return nil
        }

        var basePath = components.path
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if basePath == "/v1", path.hasPrefix("/v1/") {
            basePath = ""
        }
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func normalizedConfiguration(
        _ configuration: InferenceConfiguration,
        credential: String
    ) throws -> (configuration: InferenceConfiguration, credential: String) {
        let endpoint = configuration.trimmedBaseURL
        guard self.endpoint(baseURL: endpoint, path: "") != nil else {
            throw InferenceError.invalidEndpoint
        }
        let model = try normalizedModel(configuration.modelID)
        let credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.provider.requiresCredential, credential.isEmpty {
            throw InferenceError.missingKey
        }
        return (
            InferenceConfiguration(
                provider: configuration.provider,
                baseURL: endpoint,
                modelID: model,
                apiMode: configuration.apiMode
            ),
            credential
        )
    }

    private func applyAuthorization(_ credential: String, to request: inout URLRequest) {
        guard !credential.isEmpty else { return }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    }

    private func validate(
        response: URLResponse,
        data: Data,
        selectedModel: String?,
        credentialKnownValid: Bool,
        isCredentialValidation: Bool,
        key: String
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw InferenceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let decodedMessage = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))
                .flatMap { $0.error.message }
            let rawMessage = decodedMessage
                ?? String(decoding: data.prefix(500), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = Self.redact(
                rawMessage.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    : rawMessage,
                secrets: [key]
            )
            throw Self.classifyHTTPError(
                status: http.statusCode,
                selectedModel: selectedModel,
                credentialKnownValid: credentialKnownValid,
                isCredentialValidation: isCredentialValidation,
                message: message
            )
        }
    }

    private func normalizedModel(_ model: String) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InferenceError.missingModel }
        return trimmed
    }

    private func validateHint(_ payload: HintPayload, context: CoachContext) throws {
        let fields = [
            payload.recommendedMove,
            payload.concept,
            payload.why,
            payload.plan,
            payload.likelyReply,
            payload.watchFor,
        ]
        guard fields.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw InferenceError.invalidResponse
        }

        let move = context.recommendedMove.lowercased()
        guard move.count >= 4,
              payload.recommendedMove.lowercased() == move
        else {
            throw InferenceError.invalidResponse
        }

        let from = String(move.prefix(2))
        let to = String(move.dropFirst(2).prefix(2))
        let concept = payload.concept.lowercased()
        let recommendedSAN = context.variations.first?.sanLine.first?
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "#", with: "")
            .lowercased()
        guard !concept.contains(move),
              !concept.contains(from),
              !concept.contains(to),
              recommendedSAN.map({ !containsToken($0, in: concept) }) ?? true
        else {
            throw InferenceError.invalidResponse
        }

        if let facts = context.recommendedMoveFacts {
            try validateSemanticGrounding(payload, facts: facts)
        }

        if let suppliedReply = context.variations.first?.sanLine.dropFirst().first,
           !suppliedReply.isEmpty {
            let normalizedReply = suppliedReply
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "#", with: "")
                .lowercased()
            let responseReply = payload.likelyReply
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "#", with: "")
                .lowercased()
            guard responseReply.contains(normalizedReply) else {
                throw InferenceError.invalidResponse
            }
        }
    }

    private func validateSemanticGrounding(
        _ payload: HintPayload,
        facts: RecommendedMoveFacts
    ) throws {
        let concept = payload.concept.lowercased()
        let why = payload.why.lowercased()

        if !facts.givesCheck, !facts.resolvesCheck,
           containsAny(
               [
                   "forcing check", "forcing checks", "checking move",
                   "give check", "giving check", "especially checks",
                   "look for checks",
               ],
               in: concept
           ) {
            throw InferenceError.invalidResponse
        }
        if !facts.isCapture,
           containsAny(
               [
                   "find a capture", "look for a capture", "look for captures",
                   "take material", "win material with a capture",
               ],
               in: concept
           ) {
            throw InferenceError.invalidResponse
        }
        if !facts.isCastling,
           containsAny(["castle now", "castling move"], in: concept) {
            throw InferenceError.invalidResponse
        }
        if !facts.isPromotion,
           containsAny(["promote the pawn", "promotion move"], in: concept) {
            throw InferenceError.invalidResponse
        }

        if facts.resolvesCheck {
            let terms = ["check", "king", "danger", "safe", "safety"]
            guard containsAny(terms, in: concept),
                  containsAny(terms, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if facts.isCastling {
            let terms = ["castle", "castling", "king safety", "safe king", "rook"]
            guard containsAny(terms, in: concept),
                  containsAny(terms, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if facts.isPromotion {
            let terms = ["promot", "new queen", "new piece", "advanced pawn"]
            guard containsAny(terms, in: concept),
                  containsAny(terms, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if facts.isCapture {
            let capturedKind = facts.capturedPiece.map {
                pieceKind(from: $0)
            }
            var terms = [
                "capture",
                "take",
                "remove",
                "exchange",
                "material",
            ]
            if let capturedKind {
                terms.append(capturedKind)
            }
            guard containsAny(terms, in: concept),
                  containsAny(terms, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if facts.givesCheck {
            let terms = ["check", "king", "forcing", "force", "tempo"]
            guard containsAny(terms, in: concept),
                  containsAny(terms, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if let target = facts.newlyAttackedPieces.first {
            let kind = pieceKind(from: target)
            let thematicWords = [
                kind, "challenge", "question", "attack", "harass",
                "dislodge", "drive", "tempo", "pressure",
            ]
            guard concept.contains(kind) || why.contains(kind),
                  containsAny(thematicWords, in: concept),
                  containsAny(thematicWords, in: why)
            else {
                throw InferenceError.invalidResponse
            }
        } else if facts.developsPiece {
            guard containsAny(
                ["develop", "activate", "bring a piece", "coordination"],
                in: concept
            ), containsAny(
                ["develop", "activate", "bring a piece", "coordination"],
                in: why
            ) else {
                throw InferenceError.invalidResponse
            }
        } else if facts.isCentralPawnMove {
            guard containsAny(
                ["center", "central", "space", "open lines"],
                in: concept
            ), containsAny(
                ["center", "central", "space", "open lines"],
                in: why
            ) else {
                throw InferenceError.invalidResponse
            }
        }
    }

    private func containsAny(_ values: [String], in text: String) -> Bool {
        values.contains { text.contains($0) }
    }

    private func pieceKind(from description: String) -> String {
        for kind in ["king", "queen", "rook", "bishop", "knight", "pawn"] {
            if description.lowercased().contains(kind) {
                return kind
            }
        }
        return "piece"
    }

    private func containsToken(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return text.range(
            of: #"(?<![a-z0-9])\#(escaped)(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }
}

struct ResponsesRequest: Encodable, Equatable, Sendable {
    var model: String
    var input: [InferenceMessage]
    var maxOutputTokens: Int
    var stream: Bool
    var text: ResponsesTextConfiguration?

    enum CodingKeys: String, CodingKey {
        case model, input, stream, text
        case maxOutputTokens = "max_output_tokens"
    }
}

struct ResponsesTextConfiguration: Encodable, Equatable, Sendable {
    var format: ResponsesTextFormat

    static func hint(recommendedMove: String) -> ResponsesTextConfiguration {
        ResponsesTextConfiguration(
            format: ResponsesTextFormat(
                type: "json_schema",
                name: "chess_coach_hint",
                strict: true,
                schema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "recommendedMove": .object([
                            "type": .string("string"),
                            "const": .string(recommendedMove),
                        ]),
                        "concept": hintTextSchema(maxLength: 320),
                        "why": hintTextSchema(maxLength: 600),
                        "plan": hintTextSchema(maxLength: 600),
                        "likelyReply": hintTextSchema(maxLength: 240),
                        "watchFor": hintTextSchema(maxLength: 600),
                    ]),
                    "required": .array([
                        .string("recommendedMove"),
                        .string("concept"),
                        .string("why"),
                        .string("plan"),
                        .string("likelyReply"),
                        .string("watchFor"),
                    ]),
                ])
            )
        )
    }

    private static func hintTextSchema(maxLength: Int) -> JSONValue {
        .object([
            "type": .string("string"),
            "minLength": .integer(1),
            "maxLength": .integer(maxLength),
        ])
    }

    static let coachReply = ResponsesTextConfiguration(
        format: ResponsesTextFormat(
            type: "json_schema",
            name: "chess_coach_reply",
            strict: true,
            schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "version": .object([
                        "type": .string("integer"),
                        "const": .integer(CoachReply.currentVersion),
                    ]),
                    "summary": .object([
                        "type": .string("string"),
                        "minLength": .integer(1),
                        "maxLength": .integer(600),
                    ]),
                    "sections": .object([
                        "type": .string("array"),
                        "minItems": .integer(0),
                        "maxItems": .integer(3),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .object([
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array(
                                        CoachReplySectionKind.allCases.map {
                                            .string($0.rawValue)
                                        }
                                    ),
                                ]),
                                "title": .object([
                                    "type": .string("string"),
                                    "maxLength": .integer(80),
                                ]),
                                "body": .object([
                                    "type": .string("string"),
                                    "minLength": .integer(1),
                                    "maxLength": .integer(2_000),
                                ]),
                                "variationRank": .object([
                                    "type": .array([
                                        .string("integer"),
                                        .string("null"),
                                    ]),
                                ]),
                            ]),
                            "required": .array([
                                .string("kind"),
                                .string("title"),
                                .string("body"),
                                .string("variationRank"),
                            ]),
                        ]),
                    ]),
                ]),
                "required": .array([
                    .string("version"),
                    .string("summary"),
                    .string("sections"),
                ]),
            ])
        )
    )
}

struct ResponsesTextFormat: Encodable, Equatable, Sendable {
    var type: String
    var name: String
    var strict: Bool
    var schema: JSONValue
}

indirect enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum ResponsesStreamAction: Equatable, Sendable {
    case delta(String)
    case finalText(String)
    case completed
    case failed(String)
}

struct ResponsesSSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []
    private var receivedCompletion = false

    var completionWasReceived: Bool { receivedCompletion }

    mutating func consume(_ rawLine: String) throws -> ResponsesStreamAction? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return try flush()
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("event:") {
            guard dataLines.isEmpty else {
                throw InferenceError.malformedStream
            }
            eventName = String(line.dropFirst(6))
                .trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(
                String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            )
            // URLSession.AsyncBytes.lines omits the empty separator lines from
            // an SSE stream. OpenAI Responses events contain one complete JSON
            // payload per data line, so emit as soon as that payload is
            // complete while retaining buffering for valid multi-line data.
            if bufferedPayloadIsComplete {
                return try flush()
            }
        }
        return nil
    }

    mutating func finish() throws -> ResponsesStreamAction? {
        try flush()
    }

    private var bufferedPayloadIsComplete: Bool {
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return true
        }
        guard let data = payload.data(using: .utf8) else {
            return false
        }
        return (try? JSONDecoder().decode(ResponsesStreamEnvelope.self, from: data)) != nil
    }

    private mutating func flush() throws -> ResponsesStreamAction? {
        let currentEvent = eventName
        let payload = dataLines.joined(separator: "\n")
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)

        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" {
            return .completed
        }
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResponsesStreamEnvelope.self, from: data)
        else {
            throw InferenceError.malformedStream
        }

        switch envelope.type ?? currentEvent {
        case "response.output_text.delta":
            guard let delta = envelope.delta else { throw InferenceError.malformedStream }
            return .delta(delta)
        case "response.output_text.done":
            guard let text = envelope.text else { throw InferenceError.malformedStream }
            return .finalText(text)
        case "response.completed":
            receivedCompletion = true
            if let text = envelope.response?.extractedText, !text.isEmpty {
                return .finalText(text)
            }
            return .completed
        case "error", "response.failed":
            return .failed(
                envelope.message
                    ?? envelope.error?.message
                    ?? envelope.response?.error?.message
                    ?? "The selected model failed."
            )
        case "response.incomplete":
            return .failed(
                envelope.response?.incompleteDetails?.reason
                    ?? "The selected model returned an incomplete response."
            )
        case "response.refusal.delta", "response.refusal.done":
            return .failed(
                envelope.delta
                    ?? envelope.refusal
                    ?? "The selected model declined the coaching request."
            )
        default:
            return nil
        }
    }
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [InferenceMessage]
    var maxTokens: Int
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String
        }

        var message: Message
    }

    var choices: [Choice]
}

private struct ChatStreamEnvelope: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }

        var delta: Delta
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable {
        var id: String
    }

    var data: [Model]
}

private struct HintPayload: Decodable {
    var recommendedMove: String
    var concept: String
    var why: String
    var plan: String
    var likelyReply: String
    var watchFor: String
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        var message: String?
    }

    var error: APIError
}

private struct ResponsesAPIError: Decodable {
    var message: String?
}

private struct ResponsesIncompleteDetails: Decodable {
    var reason: String?
}

private struct ResponsesOutputContent: Decodable {
    var type: String?
    var text: String?
}

private struct ResponsesOutputItem: Decodable {
    var content: [ResponsesOutputContent]?
}

private func extractedResponsesText(
    from output: [ResponsesOutputItem]?
) -> String? {
    guard let output else { return nil }
    var result = ""
    for item in output {
        for content in item.content ?? [] {
            guard content.type == nil || content.type == "output_text",
                  let text = content.text
            else {
                continue
            }
            result += text
        }
    }
    return result.isEmpty ? nil : result
}

private struct ResponsesCompleteEnvelope: Decodable {
    var outputText: String?
    var output: [ResponsesOutputItem]?
    var error: ResponsesAPIError?
    var incompleteDetails: ResponsesIncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case output, error
        case outputText = "output_text"
        case incompleteDetails = "incomplete_details"
    }

    var extractedText: String? {
        if let outputText, !outputText.isEmpty {
            return outputText
        }
        return extractedResponsesText(from: output)
    }
}

private struct ResponsesStreamEnvelope: Decodable {
    struct ResponseState: Decodable {
        var outputText: String?
        var output: [ResponsesOutputItem]?
        var error: ResponsesAPIError?
        var incompleteDetails: ResponsesIncompleteDetails?

        enum CodingKeys: String, CodingKey {
            case output, error
            case outputText = "output_text"
            case incompleteDetails = "incomplete_details"
        }

        var extractedText: String? {
            if let outputText, !outputText.isEmpty {
                return outputText
            }
            return extractedResponsesText(from: output)
        }
    }

    var type: String?
    var delta: String?
    var text: String?
    var refusal: String?
    var message: String?
    var error: ResponsesAPIError?
    var response: ResponseState?
}
