import AppKit
import SwiftUI
import Testing
@testable import ChessCoach

struct GameOverPresentationTests {
    @Test func mapsWinsFromTheLearnerPerspective() throws {
        let whiteWin = try #require(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .whiteWon,
                    reason: .checkmate,
                    message: "Checkmate — White wins."
                ),
                playerSide: .white
            )
        )
        #expect(whiteWin.outcome == .playerWin)
        #expect(whiteWin.title == "You won")
        #expect(whiteWin.reason == "Checkmate")
        #expect(whiteWin.resultNotation == "1-0")

        let blackLoss = try #require(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .whiteWon,
                    reason: .timeout,
                    message: "Black ran out of time."
                ),
                playerSide: .black
            )
        )
        #expect(blackLoss.outcome == .computerWin)
        #expect(blackLoss.title == "Computer won")
        #expect(blackLoss.reason == "You ran out of time")
        #expect(blackLoss.resultNotation == "1-0")
    }

    @Test func mapsEveryDrawReasonToPlainLanguage() throws {
        let cases: [(GameEndReason, String)] = [
            (.stalemate, "Stalemate"),
            (.repetition, "Threefold repetition"),
            (.fiftyMoveRule, "Fifty-move rule"),
            (.insufficientMaterial, "Insufficient material"),
        ]

        for (reason, expected) in cases {
            let presentation = try #require(
                GameOverPresentationMapper.resolve(
                    status: ChessGameStatus(
                        result: .draw,
                        reason: reason
                    ),
                    playerSide: .white
                )
            )
            #expect(presentation.outcome == .draw)
            #expect(presentation.title == "Draw")
            #expect(presentation.reason == expected)
            #expect(presentation.resultNotation == "1/2-1/2")
        }
    }

    @Test func handlesResignationAndLegacyResults() throws {
        let current = try #require(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .blackWon,
                    reason: .resignation,
                    message: "You resigned."
                ),
                playerSide: .white
            )
        )
        #expect(current.title == "Computer won")
        #expect(current.reason == "You resigned")
        #expect(current.resultNotation == "0-1")

        let legacy = try #require(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .resigned,
                    reason: .resignation
                ),
                playerSide: .black
            )
        )
        #expect(legacy.title == "Computer won")
        #expect(legacy.reason == "You resigned")
        #expect(legacy.resultNotation == "1-0")
    }

    @Test func omitsNonResultsAndProvidesSpokenResult() throws {
        #expect(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(),
                playerSide: .white
            ) == nil
        )
        #expect(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .abandoned,
                    reason: .restarted
                ),
                playerSide: .white
            ) == nil
        )

        let draw = try #require(
            GameOverPresentationMapper.resolve(
                status: ChessGameStatus(
                    result: .draw,
                    reason: .repetition
                ),
                playerSide: .white
            )
        )
        #expect(
            draw.accessibilitySummary
                == "Draw. Threefold repetition. Result one half to one half."
        )
    }
}

@MainActor
@Suite(.serialized)
struct GameOverPanelVisualTests {
    @Test func rendersDefaultAndCompactPanels() throws {
        try render(
            status: ChessGameStatus(
                result: .whiteWon,
                reason: .checkmate
            ),
            playerSide: .white,
            size: CGSize(width: 460, height: 190),
            colorScheme: .light,
            name: "game-over-player-win-default"
        )

        try render(
            status: ChessGameStatus(
                result: .blackWon,
                reason: .timeout
            ),
            playerSide: .white,
            size: CGSize(width: 300, height: 230),
            colorScheme: .dark,
            name: "game-over-computer-win-compact"
        )

        try render(
            status: ChessGameStatus(
                result: .draw,
                reason: .repetition
            ),
            playerSide: .black,
            size: CGSize(width: 300, height: 230),
            colorScheme: .light,
            name: "game-over-draw-compact"
        )
    }

    private func render(
        status: ChessGameStatus,
        playerSide: ChessSide,
        size: CGSize,
        colorScheme: ColorScheme,
        name: String
    ) throws {
        let content = GameOverPanel(
            status: status,
            playerSide: playerSide,
            onReview: {},
            onPlayAgain: {}
        )
        .padding(12)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == size)
        try write(image, named: name)
    }

    private func write(_ image: NSImage, named name: String) throws {
        let directory = URL(
            fileURLWithPath: "/tmp/ChessCoachVisualSnapshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(
            representation.representation(using: .png, properties: [:])
        )
        try data.write(
            to: directory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}
