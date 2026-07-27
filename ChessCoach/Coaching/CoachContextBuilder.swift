import Foundation

struct LearnerSnapshot: Codable, Equatable, Sendable {
    var experience: String
    var estimatedElo: String
    var confidence: Double
    var reviewedGames: Int
    var weaknesses: String
    var strengths: String
    var userNotes: String
}

struct CoachVariation: Codable, Equatable, Sendable {
    var rank: Int
    var move: String
    var sanLine: [String]
    /// Full authoritative UCI line supplied by Stockfish. Optional so older
    /// persisted/test fixtures that only carry the first move remain decodable.
    var uciLine: [String]? = nil
    var depth: Int? = nil
    var centipawns: Int?
    var mate: Int?
    var expectedScore: Double?
}

/// Deterministic facts about Stockfish's authoritative recommendation. These
/// facts let both the local fallback and the language model explain *that
/// move*, rather than choosing a generic theme from unrelated legal moves.
struct RecommendedMoveFacts: Codable, Equatable, Sendable {
    var uci: String
    var san: String
    var movingPiece: String
    var capturedPiece: String?
    var newlyAttackedPieces: [String]
    var resolvesCheck: Bool
    var givesCheck: Bool
    var isCapture: Bool
    var isCastling: Bool
    var isPromotion: Bool
    var developsPiece: Bool
    var isCentralPawnMove: Bool
    var teachingTheme: String
}

struct RecommendedMoveFactsBuilder {
    func build(
        recommendedMove: String,
        from state: ChessGameState
    ) -> RecommendedMoveFacts? {
        guard recommendedMove.count >= 4 else { return nil }
        let source = String(recommendedMove.prefix(2)).lowercased()
        let destination = String(
            recommendedMove.dropFirst(2).prefix(2)
        ).lowercased()
        guard let movingPiece = state.piece(at: source) else { return nil }

        let attackedBefore = Set(
            attackedEnemyPieces(by: movingPiece, in: state).map(\.accessibilityName)
        )
        let resolvesCheck = state.isCheck
        let nextState = ChessGameState(initialFEN: state.fen)
        guard let made = try? nextState.make(uci: recommendedMove),
              let movedPiece = nextState.piece(at: destination)
        else {
            return nil
        }

        let attackedAfter = attackedEnemyPieces(by: movedPiece, in: nextState)
        let newlyAttacked = attackedAfter
            .filter { !attackedBefore.contains($0.accessibilityName) }
            .map(\.accessibilityName)
            .sorted()
        let capturedPiece = capturedPiece(
            for: made,
            movingPiece: movingPiece,
            destination: destination,
            in: state
        )
        let isCapture = made.san.contains("x")
        let isCastling = made.san.hasPrefix("O-O")
        let isPromotion = made.san.contains("=")
        let givesCheck = made.san.hasSuffix("+") || made.san.hasSuffix("#")
        let developsPiece = isDevelopingMove(
            piece: movingPiece,
            source: source,
            destination: destination
        )
        let isCentralPawnMove = movingPiece.kind == "p"
            && ["c", "d", "e", "f"].contains(String(destination.prefix(1)))

        let facts = RecommendedMoveFacts(
            uci: made.uci,
            san: made.san,
            movingPiece: pieceDescription(movingPiece, includeSquare: false),
            capturedPiece: capturedPiece.map {
                pieceDescription($0, includeSquare: false)
            },
            newlyAttackedPieces: newlyAttacked.map {
                shortPieceDescription($0)
            },
            resolvesCheck: resolvesCheck,
            givesCheck: givesCheck,
            isCapture: isCapture,
            isCastling: isCastling,
            isPromotion: isPromotion,
            developsPiece: developsPiece,
            isCentralPawnMove: isCentralPawnMove,
            teachingTheme: ""
        )
        var themedFacts = facts
        themedFacts.teachingTheme = teachingTheme(for: facts)
        return themedFacts
    }

    private func teachingTheme(for facts: RecommendedMoveFacts) -> String {
        if facts.resolvesCheck {
            return "Answer the check while improving the resulting position."
        }
        if facts.isCastling {
            return "Secure the king and connect the rooks."
        }
        if facts.isPromotion {
            return "Convert the advanced pawn into decisive material."
        }
        if facts.isCapture, let captured = facts.capturedPiece {
            return "Use the concrete capture of the \(captured) to improve the material balance."
        }
        if facts.givesCheck {
            return "Use the forcing check to improve piece activity or create a second threat."
        }
        if let target = facts.newlyAttackedPieces.first {
            return "Challenge the opponent's \(pieceKind(from: target)) and gain time for development."
        }
        if facts.developsPiece {
            return "Activate an undeveloped piece while improving coordination."
        }
        if facts.isCentralPawnMove {
            return "Use the pawn move to claim central space and open lines for the pieces."
        }
        return "Improve the recommended piece while limiting the opponent's most useful reply."
    }

    private func capturedPiece(
        for move: MadeMove,
        movingPiece: BoardPiece,
        destination: String,
        in state: ChessGameState
    ) -> BoardPiece? {
        if let directCapture = state.piece(at: destination) {
            return directCapture
        }
        guard movingPiece.kind == "p", move.san.contains("x"),
              let destinationCoordinate = coordinate(destination),
              let sourceCoordinate = coordinate(movingPiece.square)
        else {
            return nil
        }
        return state.piece(
            at: square(
                file: destinationCoordinate.file,
                rank: sourceCoordinate.rank
            )
        )
    }

    private func isDevelopingMove(
        piece: BoardPiece,
        source: String,
        destination: String
    ) -> Bool {
        guard piece.kind == "n" || piece.kind == "b" else { return false }
        let homeSquares: Set<String> = piece.side == .white
            ? ["b1", "c1", "f1", "g1"]
            : ["b8", "c8", "f8", "g8"]
        return homeSquares.contains(source) && source != destination
    }

    private func attackedEnemyPieces(
        by piece: BoardPiece,
        in state: ChessGameState
    ) -> [BoardPiece] {
        guard let origin = coordinate(piece.square) else { return [] }
        let destinations: [(Int, Int)]
        switch piece.kind {
        case "p":
            let direction = piece.side == .white ? 1 : -1
            destinations = [(-1, direction), (1, direction)].compactMap {
                target(from: origin, offset: $0)
            }
        case "n":
            destinations = [
                (-2, -1), (-2, 1), (-1, -2), (-1, 2),
                (1, -2), (1, 2), (2, -1), (2, 1),
            ].compactMap { target(from: origin, offset: $0) }
        case "k":
            destinations = [
                (-1, -1), (-1, 0), (-1, 1), (0, -1),
                (0, 1), (1, -1), (1, 0), (1, 1),
            ].compactMap { target(from: origin, offset: $0) }
        case "b":
            destinations = rayTargets(
                from: origin,
                directions: [(-1, -1), (-1, 1), (1, -1), (1, 1)],
                in: state
            )
        case "r":
            destinations = rayTargets(
                from: origin,
                directions: [(-1, 0), (1, 0), (0, -1), (0, 1)],
                in: state
            )
        case "q":
            destinations = rayTargets(
                from: origin,
                directions: [
                    (-1, -1), (-1, 1), (1, -1), (1, 1),
                    (-1, 0), (1, 0), (0, -1), (0, 1),
                ],
                in: state
            )
        default:
            destinations = []
        }
        return destinations.compactMap { destination in
            let target = state.piece(
                at: square(file: destination.0, rank: destination.1)
            )
            return target?.side == piece.side.opposite ? target : nil
        }
    }

    private func rayTargets(
        from origin: (file: Int, rank: Int),
        directions: [(Int, Int)],
        in state: ChessGameState
    ) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for direction in directions {
            var file = origin.file + direction.0
            var rank = origin.rank + direction.1
            while (0..<8).contains(file), (0..<8).contains(rank) {
                result.append((file, rank))
                if state.piece(at: square(file: file, rank: rank)) != nil {
                    break
                }
                file += direction.0
                rank += direction.1
            }
        }
        return result
    }

    private func target(
        from origin: (file: Int, rank: Int),
        offset: (Int, Int)
    ) -> (Int, Int)? {
        let file = origin.file + offset.0
        let rank = origin.rank + offset.1
        guard (0..<8).contains(file), (0..<8).contains(rank) else {
            return nil
        }
        return (file, rank)
    }

    private func coordinate(_ square: String) -> (file: Int, rank: Int)? {
        guard square.count == 2,
              let fileASCII = square.utf8.first,
              let rank = Int(String(square.suffix(1)))
        else {
            return nil
        }
        let file = Int(fileASCII) - Int(Character("a").asciiValue!)
        guard (0..<8).contains(file), (1...8).contains(rank) else { return nil }
        return (file, rank - 1)
    }

    private func square(file: Int, rank: Int) -> String {
        let scalar = UnicodeScalar(Int(Character("a").asciiValue!) + file)!
        return "\(Character(scalar))\(rank + 1)"
    }

    private func pieceDescription(
        _ piece: BoardPiece,
        includeSquare: Bool
    ) -> String {
        let color = piece.side.rawValue
        let kind = pieceKind(from: piece.accessibilityName)
        return includeSquare
            ? "\(color) \(kind) on \(piece.square)"
            : "\(color) \(kind)"
    }

    private func shortPieceDescription(_ accessibilityName: String) -> String {
        accessibilityName.lowercased()
    }

    private func pieceKind(from description: String) -> String {
        for kind in ["king", "queen", "rook", "bishop", "knight", "pawn"] {
            if description.lowercased().contains(kind) {
                return kind
            }
        }
        return "piece"
    }
}

struct DeterministicHintBuilder {
    func build(context: CoachContext) -> CoachHint {
        let facts = context.recommendedMoveFacts
            ?? RecommendedMoveFactsBuilder().build(
                recommendedMove: context.recommendedMove,
                from: ChessGameState(initialFEN: context.fen)
            )
        let concept: String
        let why: String
        let plan: String

        if let facts {
            (concept, why, plan) = groundedCopy(for: facts)
        } else {
            concept = "Compare the engine's principal line with the opponent's most urgent threat."
            why = "The recommendation is the strongest move in the supplied Stockfish analysis."
            plan = "Follow the principal line while checking captures, threats, and king safety."
        }

        let line = context.variations.first?.sanLine.joined(separator: " ")
            ?? "No principal variation available."
        return CoachHint(
            concept: concept,
            why: why,
            plan: plan,
            likelyReply: context.variations.first?.sanLine.dropFirst().first
                ?? "The reply depends on the opponent's choice.",
            watchFor: line,
            recommendedMove: context.recommendedMove,
            source: "Stockfish fallback"
        )
    }

    private func groundedCopy(
        for facts: RecommendedMoveFacts
    ) -> (concept: String, why: String, plan: String) {
        if facts.resolvesCheck {
            return (
                "First answer the check, then compare which legal response leaves your pieces best coordinated.",
                "The recommendation gets the king out of danger and produces Stockfish's strongest resulting position.",
                "After the forced response, restore development and king safety before starting a new plan."
            )
        }
        if facts.isCastling {
            return (
                "Look for a king-safety move that also brings the rooks closer to working together.",
                "The recommendation secures the king and improves rook coordination in one move.",
                "Use the safer king to activate the remaining pieces and contest open files."
            )
        }
        if facts.isPromotion {
            return (
                "Your advanced pawn can be converted into a much stronger piece now.",
                "The recommendation completes the promotion and creates an immediate material gain.",
                "Coordinate the new piece with the king and watch for forcing replies."
            )
        }
        if facts.isCapture {
            let target = facts.capturedPiece ?? "enemy piece"
            return (
                "Check the concrete capture before choosing a slower improving move.",
                "The recommendation removes the \(pieceKind(from: target)) and improves the material balance in the principal line.",
                "After the exchange, stabilize the pieces and anticipate the opponent's best recapture or counterplay."
            )
        }
        if facts.givesCheck {
            return (
                "Look for a forcing check that improves your position rather than checking only for its own sake.",
                "The recommendation forces a reply while preserving the strongest continuation in Stockfish's line.",
                "Use the tempo from the check to improve coordination or add a second threat."
            )
        }
        if let target = facts.newlyAttackedPieces.first {
            let kind = pieceKind(from: target)
            return (
                "Look for a way to challenge the opponent's \(kind) and make it spend a tempo deciding where to go.",
                "The recommendation attacks the \(kind), so the opponent must address that pressure instead of improving freely.",
                "Use the gained tempo to finish development and improve king safety."
            )
        }
        if facts.developsPiece {
            return (
                "Improve an undeveloped piece while keeping the rest of the position flexible.",
                "The recommendation brings a new piece into play and strengthens coordination.",
                "Continue development, prepare king safety, and avoid moving the same piece repeatedly without a concrete reason."
            )
        }
        if facts.isCentralPawnMove {
            return (
                "Consider how a central pawn move can claim space while opening lines for your pieces.",
                "The recommendation increases central influence and gives the pieces more useful squares.",
                "Develop quickly behind the new pawn structure and prepare king safety."
            )
        }
        return (
            "Find the move that improves your least effective piece while limiting the opponent's best reply.",
            "The recommendation produces the strongest evaluated continuation and improves coordination.",
            "Keep checking the opponent's forcing replies as you bring the remaining pieces into play."
        )
    }

    private func pieceKind(from description: String) -> String {
        for kind in ["king", "queen", "rook", "bishop", "knight", "pawn"] {
            if description.lowercased().contains(kind) {
                return kind
            }
        }
        return "piece"
    }
}

enum CoachReplySectionKind: String, Codable, CaseIterable, Sendable {
    case explanation
    case idea
    case plan
    case caution
    case variation
}

/// A deliberately small semantic contract for coach prose. Concrete moves
/// never come from this payload: `.variation` sections reference a Stockfish
/// variation rank that the app renders from `CoachContext`.
struct CoachReplySection: Codable, Equatable, Sendable {
    var kind: CoachReplySectionKind
    var title: String
    var body: String
    var variationRank: Int?
}

struct CoachReply: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// A short, position-specific answer that stands on its own. Older
    /// structured rows decode with an empty summary and continue to render
    /// their sections unchanged.
    var summary: String
    var sections: [CoachReplySection]

    init(
        version: Int = Self.currentVersion,
        summary: String = "",
        sections: [CoachReplySection]
    ) {
        self.version = version
        self.summary = summary
        self.sections = sections
    }

    var plainText: String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionText = sections.map { section in
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "" }
            return title.isEmpty ? body : "\(title): \(body)"
        }
        .filter { !$0.isEmpty }
        return ([cleanSummary] + sectionText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func legacy(text: String) -> CoachReply {
        CoachReply(
            sections: [
                CoachReplySection(
                    kind: .explanation,
                    title: "Coach",
                    body: CoachReplySanitizer.plainText(text),
                    variationRank: nil
                )
            ]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case summary
        case sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
            ?? ""
        sections = try container.decodeIfPresent(
            [CoachReplySection].self,
            forKey: .sections
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(summary, forKey: .summary)
        try container.encode(sections, forKey: .sections)
    }
}

struct CoachMovePresentation: Codable, Equatable, Identifiable, Sendable {
    var uci: String
    var san: String
    var moveNumber: Int
    var side: ChessSide
    var fenBefore: String
    var fenAfter: String

    var id: String { "\(moveNumber)-\(side.rawValue)-\(uci)" }

    var displayLabel: String {
        side == .white ? "\(moveNumber). \(san)" : "\(moveNumber)… \(san)"
    }

    var sourceSquare: String? {
        uci.count >= 4 ? String(uci.prefix(2)) : nil
    }

    var destinationSquare: String? {
        uci.count >= 4 ? String(uci.dropFirst(2).prefix(2)) : nil
    }
}

struct CoachVariationPresentation: Codable, Equatable, Identifiable, Sendable {
    var rank: Int
    var depth: Int
    var centipawnsForPlayer: Int?
    var mateForPlayer: Int?
    var expectedScoreForPlayer: Double?
    var moves: [CoachMovePresentation]

    var id: Int { rank }
}

struct CoachVariationPresentationBuilder {
    func build(from context: CoachContext) -> [CoachVariationPresentation] {
        context.variations.compactMap { variation in
            let authoritativeLine = variation.uciLine
                ?? (variation.move.isEmpty ? [] : [variation.move])
            guard !authoritativeLine.isEmpty else { return nil }

            let state = ChessGameState(initialFEN: context.fen)
            var moves: [CoachMovePresentation] = []
            for uci in authoritativeLine {
                let fenBefore = state.fen
                guard let made = try? state.make(uci: uci) else { break }
                moves.append(
                    CoachMovePresentation(
                        uci: made.uci,
                        san: made.san,
                        moveNumber: Self.fullMoveNumber(from: fenBefore),
                        side: made.side,
                        fenBefore: fenBefore,
                        fenAfter: made.fenAfter
                    )
                )
            }
            guard !moves.isEmpty else { return nil }

            return CoachVariationPresentation(
                rank: variation.rank,
                depth: variation.depth ?? 0,
                centipawnsForPlayer: variation.centipawns,
                mateForPlayer: variation.mate,
                expectedScoreForPlayer: variation.expectedScore,
                moves: moves
            )
        }
    }

    private static func fullMoveNumber(from fen: String) -> Int {
        let fields = fen.split(separator: " ")
        guard fields.count > 5, let value = Int(fields[5]) else { return 1 }
        return max(1, value)
    }
}

enum CoachReplySanitizer {
    static func plainText(_ input: String) -> String {
        var value = input.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?m)^\s*(?:[-*+]\s+|\d+[.)]\s+)"#,
            with: "• ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?m)^\s*>\s?"#,
            with: "",
            options: .regularExpression
        )
        for marker in ["```json", "```JSON", "```", "**", "__", "~~", "`"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = value.replacingOccurrences(
            of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<!_)_([^_\n]+)_(?!_)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsRawMarkdown(_ value: String) -> Bool {
        value.contains("```")
            || value.contains("**")
            || value.contains("__")
            || value.range(
                of: #"(?m)^\s{0,3}#{1,6}\s+"#,
                options: .regularExpression
            ) != nil
            || value.range(
                of: #"!?\[[^\]]+\]\([^)]+\)"#,
                options: .regularExpression
            ) != nil
            || value.range(
                of: #"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#,
                options: .regularExpression
            ) != nil
    }

    /// Concrete moves are rendered from Stockfish/ChessKit. Reject common UCI,
    /// SAN, and castling tokens in model-authored prose so a fluent but
    /// unsupported move can never masquerade as authoritative analysis.
    static func containsMoveNotation(_ value: String) -> Bool {
        let patterns = [
            #"(?i)(?<![A-Za-z0-9])[a-h][1-8][a-h][1-8][qrbn]?(?![A-Za-z0-9])"#,
            #"(?<![A-Za-z0-9])(?:O-O-O|O-O|0-0-0|0-0)(?:[+#])?(?![A-Za-z0-9])"#,
            #"(?<![A-Za-z0-9])(?:[KQRBN](?:[a-h1-8]{0,2})?x?[a-h][1-8]|[a-h](?:x[a-h])?[1-8])(?:=[QRBN])?[+#]?(?![A-Za-z0-9])"#,
        ]
        return patterns.contains {
            value.range(of: $0, options: .regularExpression) != nil
        }
    }
}

struct CoachContext: Codable, Equatable, Sendable {
    var version = 2
    var purpose: String
    var fen: String
    var pgn: String
    var playerColor: String
    var sideToMove: String
    var whiteClock: String
    var blackClock: String
    var recommendedMove: String
    var recommendedMoveFacts: RecommendedMoveFacts? = nil
    var variations: [CoachVariation]
    var positionFacts: PositionFeatures
    var learner: LearnerSnapshot
}

struct CoachContextBuilder {
    func build(
        purpose: String,
        state: ChessGameState,
        analysis: PositionAnalysis,
        playerSide: ChessSide,
        clocks: ClockSnapshot,
        control: TimeControl,
        profile: LearnerProfile
    ) -> CoachContext {
        let variations = analysis.variations.map { variation in
            let score = playerSide == .white
                ? variation.score
                : variation.score.inverted()
            return CoachVariation(
                rank: variation.index,
                move: variation.firstMove ?? "",
                sanLine: sanLine(from: variation.moves, startingAt: state.fen),
                uciLine: variation.moves,
                depth: variation.depth,
                centipawns: score.centipawns,
                mate: score.mate,
                expectedScore: expectedScore(
                    variation.wdl,
                    for: playerSide
                )
            )
        }

        let learner = LearnerSnapshot(
            experience: profile.experience.title,
            estimatedElo: profile.estimateLabel,
            confidence: profile.confidence,
            reviewedGames: profile.reviewedGames,
            weaknesses: profile.weaknessSummary,
            strengths: profile.strengthsSummary,
            userNotes: profile.userNotes
        )

        return CoachContext(
            purpose: purpose,
            fen: state.fen,
            pgn: state.pgn(playerSide: playerSide, result: .inProgress),
            playerColor: playerSide.rawValue,
            sideToMove: state.sideToMove.rawValue,
            whiteClock: format(milliseconds: clocks.whiteMilliseconds, control: control),
            blackClock: format(milliseconds: clocks.blackMilliseconds, control: control),
            recommendedMove: analysis.bestMove,
            recommendedMoveFacts: RecommendedMoveFactsBuilder().build(
                recommendedMove: analysis.bestMove,
                from: state
            ),
            variations: variations,
            positionFacts: PositionFeatures.extract(from: state),
            learner: learner
        )
    }

    private func sanLine(from moves: [String], startingAt fen: String) -> [String] {
        let lineState = ChessGameState(initialFEN: fen)
        var result: [String] = []
        for move in moves.prefix(10) {
            guard let made = try? lineState.make(uci: move) else { break }
            result.append(made.san)
        }
        return result
    }

    private func format(milliseconds: Int, control: TimeControl) -> String {
        guard control.usesClock else { return "No clock" }
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// StockfishService normalizes every variation's WDL to White's
    /// perspective. Coaching payloads are learner-facing, so expose the
    /// expected score from the player's perspective for every candidate.
    private func expectedScore(_ whiteWDL: WDL?, for playerSide: ChessSide) -> Double? {
        guard let whiteWDL else { return nil }
        return playerSide == .white
            ? whiteWDL.expectedScore
            : whiteWDL.inverted().expectedScore
    }
}
