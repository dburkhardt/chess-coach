import CoreGraphics
import Foundation
import Testing
@testable import ChessCoach

struct ChessBoardGeometryTests {
    @Test(arguments: [ChessSide.white, .black])
    func allSquaresRoundTripForBothPerspectives(_ perspective: ChessSide) {
        let geometry = ChessBoardGeometry(
            size: CGSize(width: 640, height: 640),
            perspective: perspective,
            displayScale: 2
        )
        var visited: Set<String> = []

        for row in 0..<8 {
            for column in 0..<8 {
                let square = geometry.square(atColumn: column, row: row)
                #expect(square != nil)
                guard let square, let center = geometry.center(of: square) else { continue }
                #expect(geometry.square(at: center) == square)
                visited.insert(square)
            }
        }

        #expect(visited.count == 64)
        #expect(visited.contains("a1"))
        #expect(visited.contains("h8"))
    }

    @Test func orientationCornersAreCorrect() {
        let white = ChessBoardGeometry(
            size: CGSize(width: 400, height: 400),
            perspective: .white
        )
        #expect(white.square(atColumn: 0, row: 0) == "a8")
        #expect(white.square(atColumn: 7, row: 7) == "h1")

        let black = ChessBoardGeometry(
            size: CGSize(width: 400, height: 400),
            perspective: .black
        )
        #expect(black.square(atColumn: 0, row: 0) == "h1")
        #expect(black.square(atColumn: 7, row: 7) == "a8")
    }

    @Test func a1ParityIsDark() {
        let geometry = ChessBoardGeometry(
            size: CGSize(width: 400, height: 400),
            perspective: .white
        )
        #expect(!geometry.isLight(square: "a1"))
        #expect(geometry.isLight(square: "b1"))
        #expect(geometry.isLight(square: "a2"))
        #expect(!geometry.isLight(square: "h8"))
    }

    @Test func retinaBoardAndOriginArePixelAligned() {
        let geometry = ChessBoardGeometry(
            size: CGSize(width: 503.3, height: 497.7),
            perspective: .white,
            displayScale: 2
        )
        #expect((geometry.boardSide * 2).rounded() == geometry.boardSide * 2)
        #expect((geometry.boardRect.minX * 2).rounded() == geometry.boardRect.minX * 2)
        #expect((geometry.boardRect.minY * 2).rounded() == geometry.boardRect.minY * 2)
    }

    @Test func pointsOutsideBoardDoNotMapToSquares() {
        let geometry = ChessBoardGeometry(
            size: CGSize(width: 500, height: 400),
            perspective: .white,
            displayScale: 2
        )
        #expect(geometry.square(at: CGPoint(x: 1, y: 200)) == nil)
        #expect(geometry.square(at: CGPoint(x: 499, y: 200)) == nil)
    }
}

struct ChessHintArrowPolygonTests {
    @Test func arrowIsOneSevenVertexSilhouetteWithSquaredTail() throws {
        let start = CGPoint(x: 40, y: 120)
        let end = CGPoint(x: 40, y: 40)
        let vertices = ChessHintArrowPolygon.vertices(
            from: start,
            to: end,
            squareSide: 80
        )

        #expect(vertices.count == 7)
        #expect(vertices[3].y > end.y)
        #expect(vertices[3].x == end.x)
        #expect(vertices[0].y == vertices[6].y)
        #expect(vertices[0].x > vertices[6].x)
        #expect(!vertices.contains(start))
        #expect(
            ChessHintArrowPolygon.path(
                from: start,
                to: end,
                squareSide: 80
            ) != nil
        )
    }

    @Test func zeroLengthArrowProducesNoShape() {
        let point = CGPoint(x: 40, y: 40)
        #expect(
            ChessHintArrowPolygon.vertices(
                from: point,
                to: point,
                squareSide: 80
            ).isEmpty
        )
        #expect(
            ChessHintArrowPolygon.path(
                from: point,
                to: point,
                squareSide: 80
            ) == nil
        )
    }
}

struct ChessBoardInteractionTests {
    @Test func clickSelectsAndThenMoves() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot()

        #expect(interaction.tap(
            square: "e2",
            snapshot: snapshot,
            method: .clickAndDrag
        ) == .selectionChanged)
        #expect(interaction.selectedSquare == "e2")

        #expect(interaction.tap(
            square: "e4",
            snapshot: snapshot,
            method: .clickAndDrag
        ) == .move(ChessBoardMoveIntent(source: "e2", destination: "e4")))
        #expect(interaction.selectedSquare == nil)
    }

    @Test func clickingFriendlyPieceSwitchesSelection() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot()
        _ = interaction.tap(square: "e2", snapshot: snapshot, method: .clickAndDrag)
        _ = interaction.tap(square: "g1", snapshot: snapshot, method: .clickAndDrag)
        #expect(interaction.selectedSquare == "g1")
    }

    @Test func clickOnlyRejectsDragAndDragOnlyRejectsTap() {
        var clickOnly = ChessBoardInteraction()
        let snapshot = makeSnapshot()
        let clickOnlyStarted = clickOnly.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickOnly
        )
        #expect(!clickOnlyStarted)

        var dragOnly = ChessBoardInteraction()
        #expect(dragOnly.tap(
            square: "e2",
            snapshot: snapshot,
            method: .dragOnly
        ) == .none)
    }

    @Test func dragStartsOnlyOnMovablePiece() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot()
        let opponentStarted = interaction.beginDrag(
            square: "e7",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(!opponentStarted)
        let emptyStarted = interaction.beginDrag(
            square: "e3",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(!emptyStarted)
        let movableStarted = interaction.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(movableStarted)
    }

    @Test func illegalAndOffBoardDropsEmitNoMove() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot()
        let firstStarted = interaction.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(firstStarted)
        #expect(interaction.endDrag(
            on: "e5",
            snapshot: snapshot
        ) == .invalidDrop(source: "e2"))

        let secondStarted = interaction.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(secondStarted)
        #expect(interaction.endDrag(
            on: nil,
            snapshot: snapshot
        ) == .invalidDrop(source: "e2"))
    }

    @Test func legalDragProducesIntent() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot()
        let started = interaction.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(started)
        #expect(interaction.endDrag(
            on: "e4",
            snapshot: snapshot
        ) == .move(ChessBoardMoveIntent(source: "e2", destination: "e4")))
    }

    @Test func unavailableInputRejectsAllInteraction() {
        var interaction = ChessBoardInteraction()
        let snapshot = makeSnapshot(inputAvailable: false)
        #expect(interaction.tap(
            square: "e2",
            snapshot: snapshot,
            method: .clickAndDrag
        ) == .none)
        let started = interaction.beginDrag(
            square: "e2",
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(!started)
    }

    @Test func promotionIntentCarriesChoice() {
        let intent = ChessBoardMoveIntent(
            source: "a7",
            destination: "a8",
            promotion: "n"
        )
        #expect(intent.uci == "a7a8n")
    }

    @Test func homeRookAliasesNormalizeAllFourCastlesInBothPerspectives() {
        let fixtures: [(fen: String, source: String, rook: String, canonical: String)] = [
            (
                "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
                "e1",
                "h1",
                "g1"
            ),
            (
                "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
                "e1",
                "a1",
                "c1"
            ),
            (
                "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
                "e8",
                "h8",
                "g8"
            ),
            (
                "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
                "e8",
                "a8",
                "c8"
            ),
        ]

        for fixture in fixtures {
            for perspective in ChessSide.allCases {
                let snapshot = snapshot(
                    fen: fixture.fen,
                    perspective: perspective
                )
                #expect(
                    snapshot.destinations(from: fixture.source)
                        .contains(fixture.canonical)
                )

                var click = ChessBoardInteraction()
                #expect(click.tap(
                    square: fixture.source,
                    snapshot: snapshot,
                    method: .clickOnly
                ) == .selectionChanged)
                #expect(click.tap(
                    square: fixture.rook,
                    snapshot: snapshot,
                    method: .clickOnly
                ) == .move(ChessBoardMoveIntent(
                    source: fixture.source,
                    destination: fixture.canonical
                )))
                #expect(click.focusedSquare == fixture.canonical)

                var drag = ChessBoardInteraction()
                let didBeginDrag = drag.beginDrag(
                    square: fixture.source,
                    at: .zero,
                    snapshot: snapshot,
                    method: .dragOnly
                )
                #expect(didBeginDrag)
                #expect(drag.endDrag(
                    on: fixture.rook,
                    snapshot: snapshot
                ) == .move(ChessBoardMoveIntent(
                    source: fixture.source,
                    destination: fixture.canonical
                )))
                #expect(drag.focusedSquare == fixture.canonical)
            }
        }
    }

    @Test func homeRookAliasStaysIllegalWhenCastleIsBlocked() {
        let snapshot = snapshot(
            fen: "4k3/8/8/8/8/8/8/4KB1R w K - 0 1",
            perspective: .white
        )
        #expect(!snapshot.destinations(from: "e1").contains("g1"))
        expectNoAliasMove(
            source: "e1",
            rook: "h1",
            snapshot: snapshot
        )
    }

    @Test func homeRookAliasStaysIllegalWhenCastleCrossesCheck() {
        let snapshot = snapshot(
            fen: "r3k3/8/8/8/8/8/8/3RK3 b q - 0 1",
            perspective: .black
        )
        #expect(!snapshot.destinations(from: "e8").contains("c8"))
        expectNoAliasMove(
            source: "e8",
            rook: "a8",
            snapshot: snapshot
        )
    }

    private func makeSnapshot(inputAvailable: Bool = true) -> ChessBoardSnapshot {
        ChessBoardSnapshot(
            gameID: UUID(),
            revision: 1,
            plyCount: 0,
            pieces: [
                BoardPiece(square: "e2", side: .white, kind: "p"),
                BoardPiece(square: "g1", side: .white, kind: "n"),
                BoardPiece(square: "e7", side: .black, kind: "p"),
            ],
            perspective: .white,
            turn: .white,
            legalDestinations: [
                "e2": ["e3", "e4"],
                "g1": ["f3", "h3"],
            ],
            lastMove: nil,
            checkSquare: nil,
            arrows: [],
            promotionState: nil,
            inputAvailable: inputAvailable
        )
    }

    private func snapshot(
        fen: String,
        perspective: ChessSide
    ) -> ChessBoardSnapshot {
        let state = ChessGameState(initialFEN: fen)
        let destinations = Dictionary(uniqueKeysWithValues: state.pieces.compactMap {
            piece -> (String, Set<String>)? in
            let legal = Set(state.legalMoves(from: piece.square).map {
                String($0.dropFirst(2).prefix(2))
            })
            return legal.isEmpty ? nil : (piece.square, legal)
        })
        return ChessBoardSnapshot(
            gameID: UUID(),
            revision: 1,
            plyCount: 0,
            pieces: state.pieces,
            perspective: perspective,
            turn: state.sideToMove,
            legalDestinations: destinations,
            lastMove: nil,
            checkSquare: nil,
            arrows: [],
            promotionState: nil,
            inputAvailable: true
        )
    }

    private func expectNoAliasMove(
        source: String,
        rook: String,
        snapshot: ChessBoardSnapshot
    ) {
        var click = ChessBoardInteraction()
        _ = click.tap(
            square: source,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        let clickResult = click.tap(
            square: rook,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        if case .move = clickResult {
            Issue.record("Illegal rook-square castle alias emitted a click move.")
        }

        var drag = ChessBoardInteraction()
        let didBeginDrag = drag.beginDrag(
            square: source,
            at: .zero,
            snapshot: snapshot,
            method: .clickAndDrag
        )
        #expect(didBeginDrag)
        #expect(
            drag.endDrag(on: rook, snapshot: snapshot)
                == .invalidDrop(source: source)
        )
    }
}

struct MaterialBalanceTests {
    @Test func standardPositionIsThirtyNinePointsPerSide() {
        let balance = MaterialBalance(pieces: ChessGameState().pieces)
        #expect(balance.whitePoints == 39)
        #expect(balance.blackPoints == 39)
        #expect(balance.isEven)
        #expect(balance.advantage(for: .white) == .even)
        #expect(balance.advantage(for: .black) == .even)
    }

    @Test func pieceValuesAndPerspectiveProduceTypedAdvantage() {
        let balance = MaterialBalance(pieces: [
            BoardPiece(square: "e1", side: .white, kind: "k"),
            BoardPiece(square: "d1", side: .white, kind: "q"),
            BoardPiece(square: "a1", side: .white, kind: "r"),
            BoardPiece(square: "c1", side: .white, kind: "b"),
            BoardPiece(square: "b1", side: .white, kind: "n"),
            BoardPiece(square: "a2", side: .white, kind: "p"),
            BoardPiece(square: "e8", side: .black, kind: "k"),
            BoardPiece(square: "d8", side: .black, kind: "q"),
            BoardPiece(square: "a8", side: .black, kind: "r"),
            BoardPiece(square: "a7", side: .black, kind: "p"),
        ])

        #expect(balance.whitePoints == 21)
        #expect(balance.blackPoints == 15)
        #expect(balance.advantage(for: .white) == .ahead(points: 6))
        #expect(balance.advantage(for: .black) == .behind(points: 6))
    }

    @MainActor
    @Test func explicitPreviewTotalsClampAndBadgeCopyIsAccessible() {
        let balance = MaterialBalance(whitePoints: 42, blackPoints: -1)
        #expect(balance.whitePoints == 42)
        #expect(balance.blackPoints == 0)

        let ahead = MaterialBalanceBadge(
            balance: MaterialBalance(whitePoints: 40, blackPoints: 39),
            playerSide: .white
        )
        #expect(ahead.displayText == "You +1")
        #expect(
            ahead.accessibilityText
                == "Material: White 40 points, Black 39 points. You lead by 1 point."
        )

        let behind = MaterialBalanceBadge(
            balance: MaterialBalance(whitePoints: 42, blackPoints: 39),
            playerSide: .black
        )
        #expect(behind.displayText == "Computer +3")
        #expect(
            behind.accessibilityText
                == "Material: White 42 points, Black 39 points. Computer leads by 3 points."
        )

        let even = MaterialBalanceBadge(
            balance: MaterialBalance(whitePoints: 39, blackPoints: 39),
            playerSide: .white
        )
        #expect(even.displayText == "Material · Even")
        #expect(
            even.accessibilityText
                == "Material: White 39 points, Black 39 points. Material is even."
        )
    }
}

struct ChessBoardPresentationTests {
    private let gameID = UUID()

    @Test func ordinaryMovePreservesMovingPieceIdentity() throws {
        let before = frame(
            ply: 0,
            pieces: [
                piece("e2", .white, "p"),
                piece("e8", .black, "k"),
            ]
        )
        let movingID = try #require(before.pieces.first {
            $0.piece.square == "e2"
        }?.id)
        let intent = ChessBoardMoveIntent(source: "e2", destination: "e4")
        let update = before.updating(to: snapshot(
            ply: 1,
            pieces: [
                piece("e4", .white, "p"),
                piece("e8", .black, "k"),
            ],
            lastMove: intent
        ))

        #expect(update.transition == .move(intent))
        #expect(update.frame.pieces.first {
            $0.piece.square == "e4"
        }?.id == movingID)
    }

    @Test func captureRemovesCapturedIdentity() throws {
        let before = frame(
            ply: 4,
            pieces: [
                piece("c4", .white, "b"),
                piece("f7", .black, "p"),
            ]
        )
        let bishopID = try #require(before.pieces.first {
            $0.piece.square == "c4"
        }?.id)
        let capturedID = try #require(before.pieces.first {
            $0.piece.square == "f7"
        }?.id)
        let intent = ChessBoardMoveIntent(source: "c4", destination: "f7")
        let update = before.updating(to: snapshot(
            ply: 5,
            pieces: [piece("f7", .white, "b")],
            lastMove: intent
        ))

        #expect(update.transition == .capture(intent, capturedSquare: "f7"))
        #expect(update.frame.pieces.first?.id == bishopID)
        #expect(!update.frame.pieces.contains { $0.id == capturedID })
    }

    @Test func castlingPreservesKingAndRookIdentities() throws {
        let before = frame(
            ply: 8,
            pieces: [
                piece("e1", .white, "k"),
                piece("h1", .white, "r"),
                piece("e8", .black, "k"),
            ]
        )
        let kingID = try #require(before.pieces.first {
            $0.piece.square == "e1"
        }?.id)
        let rookID = try #require(before.pieces.first {
            $0.piece.square == "h1"
        }?.id)
        let kingMove = ChessBoardMoveIntent(source: "e1", destination: "g1")
        let rookMove = ChessBoardMoveIntent(source: "h1", destination: "f1")
        let update = before.updating(to: snapshot(
            ply: 9,
            pieces: [
                piece("g1", .white, "k"),
                piece("f1", .white, "r"),
                piece("e8", .black, "k"),
            ],
            lastMove: kingMove
        ))

        #expect(update.transition == .castle(king: kingMove, rook: rookMove))
        #expect(update.frame.pieces.first {
            $0.piece.square == "g1"
        }?.id == kingID)
        #expect(update.frame.pieces.first {
            $0.piece.square == "f1"
        }?.id == rookID)
    }

    @Test func enPassantRemovesPawnFromCapturedSquare() throws {
        let before = frame(
            ply: 10,
            pieces: [
                piece("e5", .white, "p"),
                piece("d5", .black, "p"),
            ]
        )
        let movingID = try #require(before.pieces.first {
            $0.piece.square == "e5"
        }?.id)
        let capturedID = try #require(before.pieces.first {
            $0.piece.square == "d5"
        }?.id)
        let intent = ChessBoardMoveIntent(source: "e5", destination: "d6")
        let update = before.updating(to: snapshot(
            ply: 11,
            pieces: [piece("d6", .white, "p")],
            lastMove: intent
        ))

        #expect(update.transition == .enPassant(intent, capturedSquare: "d5"))
        #expect(update.frame.pieces.first?.id == movingID)
        #expect(!update.frame.pieces.contains { $0.id == capturedID })
    }

    @Test func promotionPreservesPawnIdentityForReplacementArtwork() throws {
        let before = frame(
            ply: 20,
            pieces: [piece("a7", .white, "p")]
        )
        let pawnID = try #require(before.pieces.first?.id)
        let intent = ChessBoardMoveIntent(
            source: "a7",
            destination: "a8",
            promotion: "q"
        )
        let update = before.updating(to: snapshot(
            ply: 21,
            pieces: [piece("a8", .white, "q")],
            lastMove: intent
        ))

        #expect(update.transition == .promotion(intent))
        #expect(update.frame.pieces.first?.id == pawnID)
        #expect(update.frame.pieces.first?.piece.kind == "q")
    }

    @Test func takebackAndStaleRevisionReplaceImmediately() {
        let current = frame(
            ply: 6,
            revision: 10,
            pieces: [piece("e4", .white, "p")]
        )
        let takeback = current.updating(to: snapshot(
            ply: 4,
            revision: 11,
            pieces: [piece("e2", .white, "p")]
        ))
        #expect(takeback.transition == .takeBack)
        #expect(takeback.frame.snapshot.plyCount == 4)

        let staleSamePly = current.updating(to: snapshot(
            ply: 6,
            revision: 9,
            pieces: [piece("d4", .white, "p")]
        ))
        #expect(staleSamePly.transition == .immediateReplacement)
        #expect(staleSamePly.frame.snapshot.revision == 9)

        let replacementGame = ChessBoardSnapshot(
            gameID: UUID(),
            revision: 1,
            plyCount: 0,
            pieces: [piece("e2", .white, "p")],
            perspective: .white,
            turn: .white,
            legalDestinations: [:],
            lastMove: nil,
            checkSquare: nil,
            arrows: [],
            promotionState: nil,
            inputAvailable: true
        )
        let replacement = current.updating(to: replacementGame)
        #expect(replacement.transition == .immediateReplacement)
    }

    private func frame(
        ply: Int,
        revision: Int? = nil,
        pieces: [BoardPiece]
    ) -> ChessBoardPresentationFrame {
        ChessBoardPresentationFrame(snapshot: snapshot(
            ply: ply,
            revision: revision,
            pieces: pieces
        ))
    }

    private func snapshot(
        ply: Int,
        revision: Int? = nil,
        pieces: [BoardPiece],
        lastMove: ChessBoardMoveIntent? = nil
    ) -> ChessBoardSnapshot {
        ChessBoardSnapshot(
            gameID: gameID,
            revision: revision ?? ply,
            plyCount: ply,
            pieces: pieces,
            perspective: .white,
            turn: ply.isMultiple(of: 2) ? .white : .black,
            legalDestinations: [:],
            lastMove: lastMove,
            checkSquare: nil,
            arrows: [],
            promotionState: nil,
            inputAvailable: true
        )
    }

    private func piece(
        _ square: String,
        _ side: ChessSide,
        _ kind: String
    ) -> BoardPiece {
        BoardPiece(square: square, side: side, kind: kind)
    }
}

@Suite(.serialized)
struct ChessBoardPreferencesTests {
    @Test func defaultsAndPersistenceUseStableSharedKeys() throws {
        let suite = try #require(UserDefaults(
            suiteName: "ChessBoardPreferencesTests.\(UUID().uuidString)"
        ))
        defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }

        let defaults = ChessBoardPreferences.load(from: suite)
        #expect(defaults.moveMethod == .clickAndDrag)
        #expect(defaults.showLegalMarkers)
        #expect(defaults.showCoordinates)
        #expect(defaults.animationsEnabled)
        #expect(defaults.pieceStyle == .merida)

        let changed = ChessBoardPreferences(
            moveMethod: .dragOnly,
            showLegalMarkers: false,
            showCoordinates: false,
            animationsEnabled: false,
            pieceStyle: .chessnut
        )
        changed.save(to: suite)
        #expect(ChessBoardPreferences.load(from: suite) == changed)
        #expect(suite.string(forKey: "chessBoard.moveMethod") == "dragOnly")
        #expect(suite.string(forKey: "chessBoard.pieceStyle") == "chessnut")

        // A user's explicit pre-beta-default choice remains intact.
        #expect(ChessBoardPreferences.load(from: suite).pieceStyle == .chessnut)
    }
}
