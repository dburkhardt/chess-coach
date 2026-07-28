import SwiftUI

struct ChessBoardView: View {
    @Bindable var coordinator: GameCoordinator

    @AppStorage(ChessBoardPreferences.moveMethodKey)
    private var moveMethodRaw = ChessBoardPreferences.MoveMethod.clickAndDrag.rawValue
    @AppStorage(ChessBoardPreferences.showLegalMarkersKey)
    private var showLegalMarkers = true
    @AppStorage(ChessBoardPreferences.showCoordinatesKey)
    private var showCoordinates = true
    @AppStorage(ChessBoardPreferences.animationsEnabledKey)
    private var animationsEnabled = true
    @AppStorage(ChessBoardPreferences.pieceStyleKey)
    private var pieceStyleRaw = ChessBoardPreferences.PieceStyle.merida.rawValue

    var body: some View {
        ChessBoardSurface(
            snapshot: coordinator.chessBoardSnapshot,
            preferences: preferences,
            onMove: coordinator.handleBoardMove,
            onPromotion: coordinator.promote,
            onEscape: coordinator.handleBoardEscape,
            onHistoryStep: { offset in
                guard coordinator.historyPreview != nil else { return false }
                return coordinator.stepHistoryPreview(by: offset)
            }
        )
    }

    private var preferences: ChessBoardPreferences {
        ChessBoardPreferences(
            moveMethod: ChessBoardPreferences.MoveMethod(rawValue: moveMethodRaw)
                ?? .clickAndDrag,
            showLegalMarkers: showLegalMarkers,
            showCoordinates: showCoordinates,
            animationsEnabled: animationsEnabled,
            pieceStyle: ChessBoardPreferences.PieceStyle(rawValue: pieceStyleRaw)
                ?? .merida
        )
    }
}

@MainActor
extension GameCoordinator {
    var chessBoardPresentationContext: ChessBoardPresentationContext {
        if let preview = historyPreview {
            return .historyPreview(
                previewID: preview.id,
                anchor: preview.anchor,
                selectedPly: preview.selectedPly
            )
        }

        guard let moment = teachingMoment else {
            return .live(
                gameID: activeGame?.id,
                revision: boardPositionRevision
            )
        }

        switch moment.phase {
        case .previewing(_, let variationRank, let step):
            return .lessonPreview(
                lessonID: moment.id,
                anchor: moment.anchor,
                variationRank: variationRank,
                step: step
            )
        case .preparing, .concept, .revealed, .failed:
            return .teachingAnchor(
                lessonID: moment.id,
                anchor: moment.anchor
            )
        }
    }

    var isTeachingPreviewActive: Bool {
        switch chessBoardPresentationContext {
        case .historyPreview, .lessonPreview:
            return true
        case .live, .teachingAnchor:
            return false
        }
    }

    var chessBoardSnapshot: ChessBoardSnapshot {
        switch chessBoardPresentationContext {
        case .live:
            return liveChessBoardSnapshot
        case .historyPreview:
            return historyPreviewSnapshot ?? liveChessBoardSnapshot
        case .teachingAnchor(let lessonID, let anchor):
            return teachingAnchorSnapshot(
                lessonID: lessonID,
                anchor: anchor
            ) ?? liveChessBoardSnapshot
        case .lessonPreview:
            return lessonPreviewSnapshot ?? liveChessBoardSnapshot
        }
    }

    var displayedMaterialBalance: MaterialBalance {
        MaterialBalance(pieces: chessBoardSnapshot.pieces)
    }

    var displayedCapturedMaterial: CapturedMaterialLedger {
        guard let game = activeGame else { return .empty }
        var moves = game.sortedPlies.map(\.uci)

        if let preview = historyPreview {
            moves = Array(moves.prefix(preview.selectedPly))
        } else if let moment = teachingMoment {
            moves = Array(moves.prefix(moment.anchor.ply))
            if case .previewing(_, let variationRank, let requestedStep) =
                moment.phase,
               case .ready(let prepared) = coachPreparationState,
               prepared.anchor == moment.anchor,
               let variation = prepared.context.variations.first(where: {
                   $0.rank == variationRank
               }) {
                let line = variation.uciLine
                    ?? (variation.move.isEmpty ? [] : [variation.move])
                let step = min(max(0, requestedStep), line.count)
                moves.append(contentsOf: line.prefix(step))
            }
        }

        return CapturedMaterialLedger(
            initialFEN: game.initialFEN,
            moves: moves
        )
    }

    private var historyPreviewSnapshot: ChessBoardSnapshot? {
        guard let preview = historyPreview,
              let game = activeGame,
              game.id == preview.anchor.gameID,
              preview.anchor.revision == boardPositionRevision,
              preview.anchor.ply == game.sortedPlies.count,
              (0..<preview.anchor.ply).contains(preview.selectedPly)
        else {
            return nil
        }

        let prefix = Array(game.sortedPlies.prefix(preview.selectedPly))
        let previewState = ChessGameState(
            initialFEN: game.initialFEN,
            moves: prefix.map(\.uci)
        )
        let latestMove = prefix.last.flatMap { ply -> ChessBoardMoveIntent? in
            guard ply.uci.count >= 4 else { return nil }
            return ChessBoardMoveIntent(
                source: String(ply.uci.prefix(2)),
                destination: String(ply.uci.dropFirst(2).prefix(2)),
                promotion: ply.uci.count > 4
                    ? String(ply.uci.suffix(1))
                    : nil
            )
        }
        let checkSquare = previewState.isCheck
            ? previewState.pieces.first(where: {
                $0.side == previewState.sideToMove && $0.kind == "k"
            })?.square
            : nil

        return ChessBoardSnapshot(
            gameID: preview.id,
            revision: preview.selectedPly,
            plyCount: preview.selectedPly,
            pieces: previewState.pieces,
            perspective: playerSide,
            turn: previewState.sideToMove,
            legalDestinations: [:],
            lastMove: latestMove,
            checkSquare: checkSquare,
            arrows: [],
            promotionState: nil,
            inputAvailable: false
        )
    }

    private var liveChessBoardSnapshot: ChessBoardSnapshot {
        let legalDestinations = Dictionary(uniqueKeysWithValues: state.pieces.compactMap { piece in
            let destinations = Set(state.legalMoves(from: piece.square).compactMap { move -> String? in
                guard move.count >= 4 else { return nil }
                return String(move.dropFirst(2).prefix(2))
            })
            return destinations.isEmpty ? nil : (piece.square, destinations)
        })
        let latestMove = activeGame?.sortedPlies.last.flatMap { ply -> ChessBoardMoveIntent? in
            guard ply.uci.count >= 4 else { return nil }
            return ChessBoardMoveIntent(
                source: String(ply.uci.prefix(2)),
                destination: String(ply.uci.dropFirst(2).prefix(2)),
                promotion: ply.uci.count > 4 ? String(ply.uci.suffix(1)) : nil
            )
        }
        let checkSquare = state.isCheck
            ? state.pieces.first(where: {
                $0.side == state.sideToMove && $0.kind == "k"
            })?.square
            : nil
        let promotion = promotionRequest.map { request in
            ChessBoardPromotionState(
                source: request.from,
                destination: request.to,
                choices: request.candidates.compactMap {
                    $0.count > 4 ? String($0.suffix(1)).lowercased() : nil
                }
            )
        }
        let arrows = hintArrow.map {
            [ChessBoardArrow(source: $0.from, destination: $0.to)]
        } ?? []

        return ChessBoardSnapshot(
            gameID: activeGame?.id,
            revision: boardPositionRevision,
            plyCount: state.plyCount,
            pieces: state.pieces,
            perspective: playerSide,
            turn: state.sideToMove,
            legalDestinations: legalDestinations,
            lastMove: latestMove,
            checkSquare: checkSquare,
            arrows: arrows,
            promotionState: promotion,
            inputAvailable: canPlayerMove
        )
    }

    private func teachingAnchorSnapshot(
        lessonID: UUID,
        anchor: PositionAnchor
    ) -> ChessBoardSnapshot? {
        guard teachingMoment?.id == lessonID,
              teachingMoment?.anchor == anchor
        else {
            return nil
        }

        let anchoredState = ChessGameState(initialFEN: anchor.fen)
        let latestMove = activeGame?.sortedPlies.last.flatMap { ply -> ChessBoardMoveIntent? in
            guard ply.uci.count >= 4 else { return nil }
            return ChessBoardMoveIntent(
                source: String(ply.uci.prefix(2)),
                destination: String(ply.uci.dropFirst(2).prefix(2)),
                promotion: ply.uci.count > 4 ? String(ply.uci.suffix(1)) : nil
            )
        }
        let checkSquare = anchoredState.isCheck
            ? anchoredState.pieces.first(where: {
                $0.side == anchoredState.sideToMove && $0.kind == "k"
            })?.square
            : nil
        let arrows = hintArrow.map {
            [ChessBoardArrow(source: $0.from, destination: $0.to)]
        } ?? []

        return ChessBoardSnapshot(
            gameID: lessonID,
            revision: anchor.revision,
            plyCount: anchor.ply,
            pieces: anchoredState.pieces,
            perspective: playerSide,
            turn: anchoredState.sideToMove,
            legalDestinations: legalDestinations(in: anchoredState),
            lastMove: latestMove,
            checkSquare: checkSquare,
            arrows: arrows,
            promotionState: promotionRequest.map { request in
                ChessBoardPromotionState(
                    source: request.from,
                    destination: request.to,
                    choices: request.candidates.compactMap {
                        $0.count > 4 ? String($0.suffix(1)).lowercased() : nil
                    }
                )
            },
            inputAvailable: canMoveFromTeachingMoment
        )
    }

    private var lessonPreviewSnapshot: ChessBoardSnapshot? {
        guard let moment = teachingMoment,
              case .previewing(_, let variationRank, let requestedStep) = moment.phase,
              case .ready(let prepared) = coachPreparationState,
              prepared.anchor == moment.anchor,
              let variation = prepared.context.variations.first(where: {
                  $0.rank == variationRank
              })
        else {
            return nil
        }

        let line = variation.uciLine
            ?? (variation.move.isEmpty ? [] : [variation.move])
        let step = min(max(0, requestedStep), line.count)
        let previewState = ChessGameState(initialFEN: moment.anchor.fen)
        var acceptedMoves: [MadeMove] = []
        for uci in line.prefix(step) {
            guard let move = try? previewState.make(uci: uci) else { break }
            acceptedMoves.append(move)
        }

        let latestMove = acceptedMoves.last.map { move in
            ChessBoardMoveIntent(
                source: String(move.uci.prefix(2)),
                destination: String(move.uci.dropFirst(2).prefix(2)),
                promotion: move.uci.count > 4 ? String(move.uci.suffix(1)) : nil
            )
        }
        let checkSquare = previewState.isCheck
            ? previewState.pieces.first(where: {
                $0.side == previewState.sideToMove && $0.kind == "k"
            })?.square
            : nil

        return ChessBoardSnapshot(
            gameID: moment.id,
            revision: moment.anchor.revision + acceptedMoves.count,
            plyCount: moment.anchor.ply + acceptedMoves.count,
            pieces: previewState.pieces,
            perspective: playerSide,
            turn: previewState.sideToMove,
            legalDestinations: [:],
            lastMove: latestMove,
            checkSquare: checkSquare,
            arrows: [],
            promotionState: nil,
            inputAvailable: false
        )
    }

    private func legalDestinations(
        in gameState: ChessGameState
    ) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: gameState.pieces.compactMap { piece in
            let destinations = Set(
                gameState.legalMoves(from: piece.square).compactMap {
                    move -> String? in
                    guard move.count >= 4 else { return nil }
                    return String(move.dropFirst(2).prefix(2))
                }
            )
            return destinations.isEmpty
                ? nil
                : (piece.square, destinations)
        })
    }

    func handleBoardMove(_ intent: ChessBoardMoveIntent) {
        dragMove(from: intent.source, to: intent.destination)
        if let promotion = intent.promotion {
            promote(to: promotion)
        }
    }

    func handleBoardEscape() -> Bool {
        if historyPreview != nil {
            returnToLivePosition()
            return true
        }

        guard let moment = teachingMoment,
              case .previewing = moment.phase
        else {
            return false
        }
        returnFromTeachingPreview()
        return true
    }
}
