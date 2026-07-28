import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing
@testable import ChessCoach

@Suite(.serialized)
struct ModelInferenceClientTests {
    @Test func responsesRequestUsesExpectedEndpointAndWireShape() throws {
        let request = try ModelInferenceClient().makeResponsesRequest(
            baseURL: "https://example.com/v1",
            key: "unit-test-token",
            model: "test-model",
            input: [
                InferenceMessage(role: "system", content: "Grounded context"),
                InferenceMessage(role: "user", content: "Explain the move"),
            ],
            maxOutputTokens: 321
        )

        #expect(request.url?.absoluteString == "https://example.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-token")

        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["model"] as? String == "test-model")
        #expect(json["max_output_tokens"] as? Int == 321)
        #expect(json["stream"] as? Bool == true)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["system", "user"])
        #expect(input.map { $0["content"] as? String } == ["Grounded context", "Explain the move"])
    }

    @Test func defaultBaseURLAddsVersionedResponsesPath() throws {
        let request = try ModelInferenceClient().makeResponsesRequest(
            baseURL: "https://example.com",
            key: "unit-test-token",
            model: "test-model",
            input: [InferenceMessage(role: "user", content: "ping")],
            maxOutputTokens: 1
        )

        #expect(
            request.url?.absoluteString
                == "https://example.com/v1/responses"
        )
    }

    @Test func structuredReplyRequestIncludesStrictThreeSectionSchema() throws {
        let request = try ModelInferenceClient().makeResponsesRequest(
            baseURL: "https://example.com",
            key: "unit-test-token",
            model: "test-model",
            input: [InferenceMessage(role: "user", content: "Explain this position")],
            maxOutputTokens: 700,
            structuredReply: true
        )
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "chess_coach_reply")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let summary = try #require(properties["summary"] as? [String: Any])
        let sections = try #require(properties["sections"] as? [String: Any])
        #expect(summary["minLength"] as? Int == 1)
        #expect(summary["maxLength"] as? Int == 600)
        #expect(sections["minItems"] as? Int == 0)
        #expect(sections["maxItems"] as? Int == 3)
        let required = try #require(schema["required"] as? [String])
        #expect(required.contains("summary"))
    }

    @Test func structuredHintRequestBindsSchemaToAuthoritativeMove() throws {
        let request = try ModelInferenceClient().makeResponsesRequest(
            baseURL: "https://example.com",
            key: "unit-test-token",
            model: "test-model",
            input: [InferenceMessage(role: "user", content: "Explain this move")],
            maxOutputTokens: 450,
            structuredHintMove: "e2e4"
        )
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["max_output_tokens"] as? Int == 450)
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "chess_coach_hint")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: Any])
        let move = try #require(properties["recommendedMove"] as? [String: Any])
        #expect(move["const"] as? String == "e2e4")
        let required = try #require(schema["required"] as? [String])
        #expect(
            Set(required) == Set([
                "recommendedMove",
                "concept",
                "why",
                "plan",
                "likelyReply",
                "watchFor",
            ])
        )
    }

    @Test func configurationValidationEnforcesCredentialsAndTransportRules() throws {
        let client = ModelInferenceClient()
        let openAI = InferenceConfiguration(
            provider: .openAI,
            baseURL: "https://api.openai.com",
            modelID: "",
            apiMode: .automatic
        )
        #expect(throws: InferenceError.missingKey) {
            try client.validate(configuration: openAI, credential: "")
        }
        #expect(throws: InferenceError.missingModel) {
            try client.validate(
                configuration: openAI,
                credential: "unit-test-token"
            )
        }

        var custom = testConfiguration()
        custom.baseURL = "http://localhost:8080/v1"
        try client.validate(configuration: custom, credential: "")

        custom.baseURL = "http://models.example.com/v1"
        #expect(throws: InferenceError.invalidEndpoint) {
            try client.validate(configuration: custom, credential: "")
        }
    }

    @Test func chatCompletionsRequestSupportsStreamingAndOptionalAuthentication() throws {
        let client = ModelInferenceClient()
        let request = try client.makeChatCompletionsRequest(
            baseURL: "http://127.0.0.1:8080/v1",
            key: "",
            model: "local-model",
            messages: [InferenceMessage(role: "user", content: "Hello")],
            maxTokens: 42,
            stream: true
        )
        #expect(
            request.url?.absoluteString
                == "http://127.0.0.1:8080/v1/chat/completions"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let data = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["model"] as? String == "local-model")
        #expect(json["max_tokens"] as? Int == 42)
        #expect(json["stream"] as? Bool == true)
    }

    @Test func automaticModeFallsBackOnceAndCachesChatCompletions() async throws {
        let chatBody = Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        ReplyURLProtocol.reset(
            stubs: [
                .init(status: 404, data: Data()),
                .init(status: 200, data: chatBody),
                .init(status: 200, data: chatBody),
            ]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: sessionConfiguration)
        )

        try await client.testModel(
            configuration: testConfiguration(mode: .automatic),
            credential: ""
        )
        try await client.testModel(
            configuration: testConfiguration(mode: .automatic),
            credential: ""
        )

        #expect(
            ReplyURLProtocol.requests.map(\.url?.path) == [
                "/v1/responses",
                "/v1/chat/completions",
                "/v1/chat/completions",
            ]
        )
    }

    @Test func automaticModeDoesNotFallbackOnAuthenticationFailure() async {
        ReplyURLProtocol.reset(
            stubs: [
                .init(
                    status: 401,
                    data: Data(#"{"error":{"message":"Unauthorized"}}"#.utf8)
                )
            ]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: sessionConfiguration)
        )

        do {
            try await client.testModel(
                configuration: testConfiguration(mode: .automatic),
                credential: ""
            )
            Issue.record("Expected authentication failure")
        } catch {
            #expect(error as? InferenceError == .invalidCredentials)
        }
        #expect(ReplyURLProtocol.requests.count == 1)
    }

    @Test func chatCompletionsStreamingYieldsTextDeltas() async throws {
        let stream = """
        data: {"choices":[{"delta":{"content":"Control "},"finish_reason":null}]}
        data: {"choices":[{"delta":{"content":"the center."},"finish_reason":"stop"}]}
        data: [DONE]
        """
        ReplyURLProtocol.reset(
            stubs: [.init(status: 200, data: Data(stream.utf8))]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: sessionConfiguration)
        )
        var text = ""
        for try await delta in client.streamChat(
            configuration: testConfiguration(mode: .chatCompletions),
            credential: "",
            context: testContext(),
            history: [CoachMessage(role: .user, text: "What matters?", ply: 0)]
        ) {
            text += delta
        }
        #expect(text == "Control the center.")
        let body = try #require(ReplyURLProtocol.requests.first?.body)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["stream"] as? Bool == true)
    }

    @Test func responsesSSEParserEmitsFoundationLinesWithoutBlankSeparators() throws {
        var parser = ResponsesSSEParser()
        var actions: [ResponsesStreamAction] = []
        let lines = [
            "event: response.created",
            #"data: {"type":"response.created"}"#,
            "event: response.output_text.delta",
            #"data: {"delta":"Central "}"#,
            #"data: {"type":"response.output_text.delta","delta":"control"}"#,
            "event: response.completed",
            #"data: {"response":{"status":"completed"}}"#,
        ]

        for line in lines {
            if let action = try parser.consume(line) {
                actions.append(action)
            }
        }

        #expect(actions == [.delta("Central "), .delta("control"), .completed])
    }

    @Test func responsesSSEParserPreservesTerminalAndErrorSemantics() throws {
        var incompleteParser = ResponsesSSEParser()
        #expect(
            try incompleteParser.consume(
                #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
            ) == .failed("max_output_tokens")
        )

        var failedParser = ResponsesSSEParser()
        #expect(try failedParser.consume("event: response.failed") == nil)
        #expect(
            try failedParser.consume(
                #"data: {"response":{"error":{"message":"upstream failed"}}}"#
            ) == .failed("upstream failed")
        )

        var errorParser = ResponsesSSEParser()
        #expect(
            try errorParser.consume(
                #"data: {"type":"error","code":"server_error","message":"service unavailable"}"#
            ) == .failed("service unavailable")
        )

        var doneParser = ResponsesSSEParser()
        #expect(try doneParser.consume("data: [DONE]") == .completed)
        #expect(try doneParser.consume("") == nil)
    }

    @Test func completedEventMayCarryTheOnlySafeCompletePayload() throws {
        var parser = ResponsesSSEParser()
        let json = #"{"version":1,"summary":"Activate your least active piece.","sections":[{"kind":"idea","title":"Notice","body":"Improve the least active piece.","variationRank":null}]}"#
        let escaped = try #require(
            String(
                data: JSONEncoder().encode(json),
                encoding: .utf8
            )
        )
        let event = """
        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":\(escaped)}]}]}}
        """

        #expect(try parser.consume(event) == .finalText(json))
        #expect(parser.completionWasReceived)
    }

    @Test func responsesSSEParserRejectsMalformedDataAndLeavesPrematureCloseIncomplete() throws {
        var brokenParser = ResponsesSSEParser()
        _ = try brokenParser.consume("data: {not-json}")
        #expect(throws: InferenceError.malformedStream) {
            try brokenParser.consume("")
        }

        var prematureCloseParser = ResponsesSSEParser()
        #expect(
            try prematureCloseParser.consume(
                #"data: {"type":"response.output_text.delta","delta":"partial"}"#
            ) == .delta("partial")
        )
        // The stream driver requires a later `.completed` action and maps this
        // nil terminal state to `InferenceError.malformedStream`.
        #expect(try prematureCloseParser.finish() == nil)
    }

    @Test func targetedModelErrorsDistinguishCredentialsFromACL() {
        let invalidKey = ModelInferenceClient.classifyHTTPError(
            status: 401,
            selectedModel: nil,
            credentialKnownValid: false,
            isCredentialValidation: true,
            message: "Unauthorized"
        )
        #expect(invalidKey == .invalidCredentials)

        let aclFailure = ModelInferenceClient.classifyHTTPError(
            status: 401,
            selectedModel: "test-model",
            credentialKnownValid: true,
            isCredentialValidation: false,
            message: "Unauthorized"
        )
        #expect(
            aclFailure
                == .modelAccessDenied(model: "test-model", status: 401)
        )
    }

    @Test func transportFailuresAreTypedAndSecretsAreRedacted() {
        #expect(
            ModelInferenceClient.mapTransportError(URLError(.timedOut))
                == .timeout
        )
        #expect(
            ModelInferenceClient.mapTransportError(URLError(.notConnectedToInternet))
                == .offline
        )
        #expect(
            ModelInferenceClient.mapTransportError(CancellationError())
                == .cancelled
        )

        let secret = "unit-test-secret-value"
        let message = ModelInferenceClient.redact(
            "Bearer \(secret) and sk-placeholder123 were rejected: \(secret)",
            secrets: [secret]
        )
        #expect(!message.contains(secret))
        #expect(!message.contains("sk-placeholder123"))
        #expect(message.contains("[REDACTED]"))
    }

    @Test func structuredHintMustMatchEngineMoveAndHideItFromConcept() throws {
        let context = testContext()
        let valid = """
        {
          "recommendedMove": "e2e4",
          "concept": "Claim central space while opening lines for your pieces.",
          "why": "The supplied principal variation keeps active development.",
          "plan": "Develop quickly and prepare king safety.",
          "likelyReply": "Black is likely to answer e5.",
          "watchFor": "After the reply, develop the king knight."
        }
        """
        let hint = try ModelInferenceClient().decodeHint(
            valid,
            context: context,
            model: "test-model"
        )
        #expect(hint.recommendedMove == "e2e4")
        #expect(hint.source == "test-model")

        let contradictory = valid.replacingOccurrences(
            of: #""recommendedMove": "e2e4""#,
            with: #""recommendedMove": "d2d4""#
        )
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeHint(
                contradictory,
                context: context,
                model: "test-model"
            )
        }

        let revealing = valid.replacingOccurrences(
            of: "Claim central space while opening lines for your pieces.",
            with: "Play e4 to claim central space."
        )
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeHint(
                revealing,
                context: context,
                model: "test-model"
            )
        }
    }

    @MainActor
    @Test func h3StructuredHintRejectsGenericForcingCheckAdvice() throws {
        let state = ChessGameState()
        for move in [
            "e2e4", "d7d5",
            "e4d5", "g8f6",
            "g1f3", "c8g4",
            "f1b5", "b8d7",
        ] {
            _ = try state.make(uci: move)
        }
        let persistence = PersistenceController(inMemory: true)
        let context = CoachContextBuilder().build(
            purpose: "h3 semantic grounding regression",
            state: state,
            analysis: PositionAnalysis(
                fen: state.fen,
                sideToMove: .white,
                bestMove: "h2h3",
                variations: [
                    PrincipalVariation(
                        index: 1,
                        depth: 20,
                        score: EngineScore(centipawns: 100),
                        wdl: WDL(win: 370, draw: 520, loss: 110),
                        moves: ["h2h3", "g4h5"]
                    )
                ]
            ),
            playerSide: .white,
            clocks: .initial(for: .none),
            control: .none,
            profile: persistence.profile
        )
        let generic = """
        {
          "recommendedMove": "h2h3",
          "concept": "Look for forcing moves first, especially checks that improve another piece.",
          "why": "The supplied principal variation is strongest.",
          "plan": "Keep checking forcing replies.",
          "likelyReply": "Black is likely to answer Bh5.",
          "watchFor": "Use the engine line."
        }
        """
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeHint(
                generic,
                context: context,
                model: "test-model"
            )
        }

        let conceptOnly = """
        {
          "recommendedMove": "h2h3",
          "concept": "Challenge the pinning bishop and make it spend a tempo deciding where to go.",
          "why": "This is strongest because Stockfish evaluates it most highly.",
          "plan": "Keep checking forcing replies.",
          "likelyReply": "Black is likely to answer Bh5.",
          "watchFor": "Use the engine line."
        }
        """
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeHint(
                conceptOnly,
                context: context,
                model: "test-model"
            )
        }

        let genericTempo = """
        {
          "recommendedMove": "h2h3",
          "concept": "Look for a move that gains a useful tempo and keeps the pressure.",
          "why": "The recommendation gains a tempo while preserving the strongest continuation.",
          "plan": "Use the tempo to finish development.",
          "likelyReply": "Black is likely to answer Bh5.",
          "watchFor": "After the reply, continue developing."
        }
        """
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeHint(
                genericTempo,
                context: context,
                model: "test-model"
            )
        }

        let grounded = """
        {
          "recommendedMove": "h2h3",
          "concept": "Challenge the pinning bishop and make it spend a tempo deciding where to go.",
          "why": "The pawn attacks the bishop instead of allowing it to maintain pressure freely.",
          "plan": "Use the tempo to finish development and prepare king safety.",
          "likelyReply": "Black is likely to answer Bh5.",
          "watchFor": "After the bishop moves, continue developing."
        }
        """
        let hint = try ModelInferenceClient().decodeHint(
            grounded,
            context: context,
            model: "test-model"
        )
        #expect(hint.recommendedMove == "h2h3")
        #expect(hint.concept.lowercased().contains("bishop"))
    }

    @Test func typedReplyIsSanitizedAndVariationReferencesAreValidated() throws {
        let context = testContext()
        let raw = """
        {
          "version": 1,
          "summary": "## **Improve your least active piece before starting tactics.**",
          "sections": [
            {
              "kind": "idea",
              "title": "## **What to notice**",
              "body": "Develop the `knight` and avoid [external links](https://example.com).",
              "variationRank": null
            },
            {
              "kind": "variation",
              "title": "Engine line",
              "body": "This line keeps the position active.",
              "variationRank": 1
            }
          ]
        }
        """

        let reply = try ModelInferenceClient().decodeReply(raw, context: context)
        #expect(reply.summary == "Improve your least active piece before starting tactics.")
        #expect(reply.sections.count == 2)
        #expect(reply.sections[0].title == "What to notice")
        #expect(reply.sections[0].body == "Develop the knight and avoid external links.")
        #expect(reply.sections[1].variationRank == 1)
        #expect(!reply.plainText.contains("**"))
        #expect(!reply.plainText.contains("`"))
        #expect(!reply.plainText.contains("https://"))

        let invalidRank = raw.replacingOccurrences(
            of: #""variationRank": 1"#,
            with: #""variationRank": 99"#
        )
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeReply(invalidRank, context: context)
        }

        let unsupportedMove = raw.replacingOccurrences(
            of: "Improve your least active piece before starting tactics.",
            with: "Play e4 before starting tactics."
        )
        #expect(throws: InferenceError.invalidResponse) {
            try ModelInferenceClient().decodeReply(
                unsupportedMove,
                context: context
            )
        }
    }

    @Test func variationPresentationReplaysAuthoritativeUCIIntoSANAndFEN() throws {
        var context = testContext()
        context.variations[0].uciLine = ["e2e4", "e7e5", "g1f3"]
        context.variations[0].depth = 18

        let line = try #require(
            CoachVariationPresentationBuilder().build(from: context).first
        )
        #expect(line.rank == 1)
        #expect(line.depth == 18)
        #expect(line.moves.map(\.uci) == ["e2e4", "e7e5", "g1f3"])
        #expect(line.moves.map(\.san) == ["e4", "e5", "Nf3"])
        #expect(line.moves.map(\.displayLabel) == ["1. e4", "1… e5", "2. Nf3"])
        #expect(line.moves[0].fenBefore == ChessGameState.standardInitialFEN)
        #expect(line.moves[0].fenAfter == line.moves[1].fenBefore)
        #expect(line.moves[1].fenAfter == line.moves[2].fenBefore)
    }

    @Test func typedReplyFallsBackFromSchemaStreamToCompletePromptResponse() async throws {
        let expected = CoachReply(
            summary: "Improve the least active piece before committing to tactics.",
            sections: [
                CoachReplySection(
                    kind: .idea,
                    title: "What to notice",
                    body: "Improve the least active piece.",
                    variationRank: nil
                )
            ]
        )
        let expectedJSON = String(
            decoding: try JSONEncoder().encode(expected),
            as: UTF8.self
        )
        let completeBody = try JSONSerialization.data(
            withJSONObject: [
                "status": "completed",
                "output": [
                    [
                        "type": "message",
                        "content": [
                            [
                                "type": "output_text",
                                "text": expectedJSON,
                            ]
                        ],
                    ]
                ],
            ]
        )
        ReplyURLProtocol.reset(
            stubs: [
                .init(
                    status: 400,
                    data: Data(#"{"error":{"message":"text.format unsupported"}}"#.utf8)
                ),
                .init(status: 200, data: completeBody),
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let reply = try await client.generateReply(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext(),
            history: [
                CoachMessage(
                    role: .user,
                    text: "What should I notice?",
                    ply: 0
                )
            ]
        )

        #expect(reply == expected)
        let requests = ReplyURLProtocol.requests
        #expect(requests.count == 2)
        let firstBody = try #require(requests.first?.body)
        let firstJSON = try #require(
            JSONSerialization.jsonObject(with: firstBody) as? [String: Any]
        )
        #expect(firstJSON["stream"] as? Bool == true)
        #expect(firstJSON["text"] != nil)

        let secondBody = try #require(requests.last?.body)
        let secondJSON = try #require(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        #expect(secondJSON["stream"] as? Bool == false)
        #expect(secondJSON["text"] == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func typedReplyAcceptsCompleteJSONAtStructuredStreamEOF() async throws {
        let expected = CoachReply(
            summary: "Complete development before beginning an attack.",
            sections: [
                CoachReplySection(
                    kind: .plan,
                    title: "Plan",
                    body: "Develop, castle, and then improve the least active piece.",
                    variationRank: nil
                )
            ]
        )
        let replyJSON = String(
            decoding: try JSONEncoder().encode(expected),
            as: UTF8.self
        )
        let quotedJSON = String(
            decoding: try JSONEncoder().encode(replyJSON),
            as: UTF8.self
        )
        let event = """
        data: {"type":"response.output_text.delta","delta":\(quotedJSON)}

        """
        ReplyURLProtocol.reset(
            stubs: [.init(status: 200, data: Data(event.utf8))]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let reply = try await client.generateReply(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext(),
            history: []
        )

        #expect(reply == expected)
        #expect(ReplyURLProtocol.requests.count == 1)
    }

    @Test func structuredHintAcceptsCompleteValidatedJSONAtStreamEOF() async throws {
        let hintJSON = validHintJSON()
        let quotedJSON = String(
            decoding: try JSONEncoder().encode(hintJSON),
            as: UTF8.self
        )
        let event = """
        data: {"type":"response.output_text.delta","delta":\(quotedJSON)}

        """
        ReplyURLProtocol.reset(
            stubs: [.init(status: 200, data: Data(event.utf8))]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let hint = try await client.generateHint(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext()
        )

        #expect(hint.recommendedMove == "e2e4")
        #expect(hint.concept == "Claim central space while freeing your pieces.")
        #expect(ReplyURLProtocol.requests.count == 1)
        let body = try #require(ReplyURLProtocol.requests.first?.body)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_output_tokens"] as? Int == 450)
        #expect(json["text"] != nil)
    }

    @Test func structuredHintFallsBackToPromptConstrainedCompleteResponse() async throws {
        let completeBody = try completeResponseBody(text: validHintJSON())
        ReplyURLProtocol.reset(
            stubs: [
                .init(
                    status: 400,
                    data: Data(#"{"error":{"message":"text.format unsupported"}}"#.utf8)
                ),
                .init(status: 200, data: completeBody),
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let hint = try await client.generateHint(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext()
        )

        #expect(hint.recommendedMove == "e2e4")
        let requests = ReplyURLProtocol.requests
        #expect(requests.count == 2)
        let firstBody = try #require(requests.first?.body)
        let firstJSON = try #require(
            JSONSerialization.jsonObject(with: firstBody) as? [String: Any]
        )
        #expect(firstJSON["stream"] as? Bool == true)
        #expect(firstJSON["text"] != nil)
        #expect(firstJSON["max_output_tokens"] as? Int == 450)

        let secondBody = try #require(requests.last?.body)
        let secondJSON = try #require(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        #expect(secondJSON["stream"] as? Bool == false)
        #expect(secondJSON["text"] == nil)
        #expect(secondJSON["max_output_tokens"] as? Int == 450)
        #expect(requests.last?.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func incompleteStructuredHintRetriesOnceWithoutStreaming() async throws {
        let incomplete = """
        data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}

        """
        ReplyURLProtocol.reset(
            stubs: [
                .init(status: 200, data: Data(incomplete.utf8)),
                .init(
                    status: 200,
                    data: try completeResponseBody(text: validHintJSON())
                ),
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let hint = try await client.generateHint(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext()
        )

        #expect(hint.recommendedMove == "e2e4")
        #expect(ReplyURLProtocol.requests.count == 2)
        let secondBody = try #require(ReplyURLProtocol.requests.last?.body)
        let secondJSON = try #require(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        #expect(secondJSON["stream"] as? Bool == false)
    }

    @Test func malformedStructuredHintRetriesOnceWithoutStreaming() async throws {
        ReplyURLProtocol.reset(
            stubs: [
                .init(
                    status: 200,
                    data: Data("data: {not-json}\n\n".utf8)
                ),
                .init(
                    status: 200,
                    data: try completeResponseBody(text: validHintJSON())
                ),
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyURLProtocol.self]
        let client = ModelInferenceClient(
            session: URLSession(configuration: configuration)
        )

        let hint = try await client.generateHint(
            configuration: testConfiguration(),
            credential: "unit-test-token",
            context: testContext()
        )

        #expect(hint.recommendedMove == "e2e4")
        #expect(ReplyURLProtocol.requests.count == 2)
        let secondBody = try #require(ReplyURLProtocol.requests.last?.body)
        let secondJSON = try #require(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        #expect(secondJSON["stream"] as? Bool == false)
    }

    @MainActor
    @Test func settingsPersistenceAndProviderCredentialsAreIsolated() throws {
        let suiteName = "ChessCoachTests.Inference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MemoryKeychain()
        let settings = InferenceSettings(defaults: defaults, keychain: keychain)

        #expect(settings.provider == .openAI)
        #expect(settings.configuration.baseURL == "https://api.openai.com")
        #expect(settings.modelID.isEmpty)
        #expect(settings.apiMode == .automatic)
        #expect(settings.keyForRequest(typedKey: "") == "")

        try settings.saveKey("stored-placeholder")
        #expect(settings.keyForRequest(typedKey: "") == "stored-placeholder")
        #expect(settings.keyForRequest(typedKey: " typed-placeholder ") == "typed-placeholder")

        settings.provider = .customOpenAICompatible
        settings.customEndpoint = "http://localhost:8080/v1"
        settings.modelID = "local-model"
        settings.apiMode = .chatCompletions
        #expect(settings.existingKey().isEmpty)
        try settings.saveKey("custom-placeholder")

        let reloaded = InferenceSettings(defaults: defaults, keychain: keychain)
        #expect(reloaded.provider == .customOpenAICompatible)
        #expect(reloaded.configuration.baseURL == "http://localhost:8080/v1")
        #expect(reloaded.modelID == "local-model")
        #expect(reloaded.apiMode == .chatCompletions)
        #expect(reloaded.existingKey() == "custom-placeholder")
        #expect(reloaded.existingKey(for: .openAI) == "stored-placeholder")
    }

    @MainActor
    @Test func credentialPrecedenceAndConfigurationIssuesAreTyped() throws {
        let suiteName = "ChessCoachTests.Precedence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MemoryKeychain()
        let settings = InferenceSettings(
            defaults: defaults,
            keychain: keychain
        )

        #expect(settings.credentialState == .missing)
        #expect(settings.configurationIssue == .missingKey)

        settings.useKeyForSession(" session-placeholder ")
        #expect(settings.credentialState == .sessionOnly)
        #expect(settings.existingKey() == "session-placeholder")
        #expect(settings.configurationIssue == .missingModel)
        #expect(
            settings.keyForRequest(typedKey: " typed-placeholder ")
                == "typed-placeholder"
        )

        settings.modelID = "test-model"
        #expect(settings.configurationIssue == nil)
        settings.clearSessionKey()
        #expect(settings.credentialState == .missing)

        try settings.savePersistentKey("stored-placeholder")
        #expect(settings.credentialState == .stored)
        #expect(settings.existingKey() == "stored-placeholder")

        settings.useKeyForSession("new-session-placeholder")
        #expect(settings.credentialState == .sessionOnly)
        #expect(settings.existingKey() == "new-session-placeholder")
        settings.clearSessionKey()
        #expect(settings.existingKey() == "stored-placeholder")
    }

    @MainActor
    @Test func persistentCredentialsAreReadOncePerProvider() throws {
        let suiteName = "ChessCoachTests.ReadOnce.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("test-model", forKey: "ai.modelID")
        let keychain = MemoryKeychain(
            values: [
                InferenceProviderKind.openAI.rawValue: "openai-placeholder",
                InferenceProviderKind.customOpenAICompatible.rawValue:
                    "custom-placeholder",
            ]
        )
        let settings = InferenceSettings(
            defaults: defaults,
            keychain: keychain
        )

        #expect(
            keychain.readCount(
                account: InferenceProviderKind.openAI.rawValue
            ) == 1
        )
        for _ in 0..<10 {
            _ = settings.existingKey()
            _ = settings.hasStoredKey
            _ = settings.credentialState
            _ = settings.isConfigured
        }
        #expect(
            keychain.readCount(
                account: InferenceProviderKind.openAI.rawValue
            ) == 1
        )

        settings.provider = .customOpenAICompatible
        settings.customEndpoint = "http://localhost:8080"
        #expect(settings.existingKey() == "custom-placeholder")
        #expect(
            keychain.readCount(
                account:
                    InferenceProviderKind.customOpenAICompatible.rawValue
            ) == 1
        )
        settings.provider = .openAI
        settings.provider = .customOpenAICompatible
        #expect(
            keychain.readCount(
                account:
                    InferenceProviderKind.customOpenAICompatible.rawValue
            ) == 1
        )
    }

    @MainActor
    @Test func sessionOnlyRuntimeNeverTouchesPersistentStore() throws {
        let suiteName = "ChessCoachTests.SessionOnly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("test-model", forKey: "ai.modelID")
        let keychain = MemoryKeychain(
            values: [
                InferenceProviderKind.openAI.rawValue:
                    "must-not-be-read",
            ],
            persistenceAvailability: .sessionOnly
        )
        let settings = InferenceSettings(
            defaults: defaults,
            keychain: keychain
        )

        #expect(settings.credentialState == .missing)
        #expect(keychain.totalReadCount == 0)
        try settings.saveKey("session-placeholder")
        #expect(settings.credentialState == .sessionOnly)
        #expect(settings.existingKey() == "session-placeholder")
        #expect(keychain.totalReadCount == 0)
        #expect(keychain.totalSaveCount == 0)

        try settings.removeKey()
        #expect(settings.credentialState == .missing)
        #expect(keychain.totalDeleteCount == 0)
    }

    @MainActor
    @Test func customProviderCanBeConfiguredWithoutInferenceKey() throws {
        let suiteName = "ChessCoachTests.Keyless.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = InferenceSettings(
            defaults: defaults,
            keychain: MemoryKeychain()
        )

        settings.provider = .customOpenAICompatible
        #expect(settings.configurationIssue == .missingEndpoint)
        settings.customEndpoint = "http://localhost:8080/v1"
        #expect(settings.configurationIssue == .missingModel)
        settings.modelID = "local-model"
        #expect(settings.configurationIssue == nil)
        #expect(settings.isConfigured)
        #expect(settings.credentialState == .missing)
    }

    @Test func keychainQueriesAreProviderIsolatedAndNoninteractive() {
        let store = KeychainStore()
        let query = store.query(
            account: InferenceProviderKind.openAI.rawValue
        )

        #expect(
            query[kSecAttrService as String] as? String
                == "com.dburkhardt.chesscoach.inference.v2"
        )
        #expect(
            query[kSecAttrAccount as String] as? String
                == InferenceProviderKind.openAI.rawValue
        )
        #expect(query[kSecAttrAccessGroup as String] == nil)
        let context =
            query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context?.interactionNotAllowed == true)
    }

    @Test func installedIdentityGateDerivesRatherThanHardcodesTeam() throws {
        for team in ["TEAMONE123", "TEAMTWO456"] {
            let authorization = try InstalledAppIdentityGate.authorize(
                InstalledAppRuntimeIdentity(
                    bundlePath:
                        InstalledAppIdentityGate.requiredBundlePath,
                    bundleIdentifier:
                        InstalledAppIdentityGate.requiredBundleIdentifier,
                    signingIdentifier:
                        InstalledAppIdentityGate.requiredBundleIdentifier,
                    teamIdentifier: team,
                    signatureIsValid: true
                )
            )
            #expect(authorization.teamIdentifier == team)
        }

        let rejected = [
            InstalledAppRuntimeIdentity(
                bundlePath: "/tmp/Chess Coach.app",
                bundleIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                signingIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                teamIdentifier: "TEAMONE123",
                signatureIsValid: true
            ),
            InstalledAppRuntimeIdentity(
                bundlePath: InstalledAppIdentityGate.requiredBundlePath,
                bundleIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                signingIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                teamIdentifier: "",
                signatureIsValid: true
            ),
            InstalledAppRuntimeIdentity(
                bundlePath: InstalledAppIdentityGate.requiredBundlePath,
                bundleIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                signingIdentifier:
                    InstalledAppIdentityGate.requiredBundleIdentifier,
                teamIdentifier: "TEAMONE123",
                signatureIsValid: false
            ),
        ]
        for identity in rejected {
            #expect(throws: KeychainError.self) {
                try InstalledAppIdentityGate.authorize(identity)
            }
        }
    }

    private func testConfiguration(
        mode: InferenceAPIMode = .responses
    ) -> InferenceConfiguration {
        InferenceConfiguration(
            provider: .customOpenAICompatible,
            baseURL: "https://example.com",
            modelID: "test-model",
            apiMode: mode
        )
    }

    private func testContext() -> CoachContext {
        CoachContext(
            purpose: "unit test",
            fen: ChessGameState.standardInitialFEN,
            pgn: "*",
            playerColor: "white",
            sideToMove: "white",
            whiteClock: "10:00",
            blackClock: "10:00",
            recommendedMove: "e2e4",
            variations: [
                CoachVariation(
                    rank: 1,
                    move: "e2e4",
                    sanLine: ["e4", "e5", "Nf3"],
                    centipawns: 24,
                    mate: nil,
                    expectedScore: 0.56
                )
            ],
            positionFacts: PositionFeatures.extract(from: ChessGameState()),
            learner: LearnerSnapshot(
                experience: "Beginner",
                estimatedElo: "Calibrating",
                confidence: 0,
                reviewedGames: 0,
                weaknesses: "Calibrating",
                strengths: "Calibrating",
                userNotes: ""
            )
        )
    }

    private func validHintJSON() -> String {
        """
        {
          "recommendedMove": "e2e4",
          "concept": "Claim central space while freeing your pieces.",
          "why": "The supplied principal variation supports active development.",
          "plan": "Develop quickly and prepare king safety.",
          "likelyReply": "Black is likely to answer e5.",
          "watchFor": "After the reply, develop the king knight."
        }
        """
    }

    private func completeResponseBody(text: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "status": "completed",
                "output": [
                    [
                        "type": "message",
                        "content": [
                            [
                                "type": "output_text",
                                "text": text,
                            ]
                        ],
                    ]
                ],
            ]
        )
    }
}

private final class ReplyURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var data: Data
    }

    struct CapturedRequest: Sendable {
        var url: URL?
        var headers: [String: String]
        var body: Data?

        func value(forHTTPHeaderField name: String) -> String? {
            headers.first {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            }?.value
        }
    }

    private struct State: Sendable {
        var stubs: [Stub] = []
        var requests: [CapturedRequest] = []
    }

    private static let state = Mutex(State())

    static var requests: [CapturedRequest] {
        state.withLock { $0.requests }
    }

    static func reset(stubs: [Stub]) {
        state.withLock {
            $0.stubs = stubs
            $0.requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let captured = CapturedRequest(
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(from: request)
        )
        let stub: Stub? = Self.state.withLock {
            $0.requests.append(captured)
            return $0.stubs.isEmpty ? nil : $0.stubs.removeFirst()
        }
        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class MemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readCounts: [String: Int] = [:]
    private var saveCount = 0
    private var deleteCount = 0
    let persistenceAvailability: CredentialPersistenceAvailability

    init(
        values: [String: String] = [:],
        persistenceAvailability: CredentialPersistenceAvailability = .persistent
    ) {
        self.values = values
        self.persistenceAvailability = persistenceAvailability
    }

    func read(account: String) throws -> String? {
        lock.withLock {
            readCounts[account, default: 0] += 1
            return values[account]
        }
    }

    func save(_ value: String, account: String) throws {
        lock.withLock {
            saveCount += 1
            values[account] = value
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            deleteCount += 1
            values[account] = nil
        }
    }

    func readCount(account: String) -> Int {
        lock.withLock { readCounts[account, default: 0] }
    }

    var totalReadCount: Int {
        lock.withLock { readCounts.values.reduce(0, +) }
    }

    var totalSaveCount: Int {
        lock.withLock { saveCount }
    }

    var totalDeleteCount: Int {
        lock.withLock { deleteCount }
    }
}
