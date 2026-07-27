import Foundation

struct ChessBoardPreferences: Codable, Equatable, Sendable {
    enum MoveMethod: String, Codable, CaseIterable, Identifiable, Sendable {
        case clickAndDrag
        case clickOnly
        case dragOnly

        var id: String { rawValue }
        var allowsClick: Bool { self != .dragOnly }
        var allowsDrag: Bool { self != .clickOnly }
    }

    enum PieceStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case chessnut
        case merida

        var id: String { rawValue }
    }

    static let moveMethodKey = "chessBoard.moveMethod"
    static let showLegalMarkersKey = "chessBoard.showLegalMarkers"
    static let showCoordinatesKey = "chessBoard.showCoordinates"
    static let animationsEnabledKey = "chessBoard.animationsEnabled"
    static let pieceStyleKey = "chessBoard.pieceStyle"

    var moveMethod: MoveMethod = .clickAndDrag
    var showLegalMarkers = true
    var showCoordinates = true
    var animationsEnabled = true
    var pieceStyle: PieceStyle = .merida

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let registered = defaults.object(forKey: showLegalMarkersKey) != nil
        return Self(
            moveMethod: defaults.string(forKey: moveMethodKey)
                .flatMap(MoveMethod.init(rawValue:)) ?? .clickAndDrag,
            showLegalMarkers: registered
                ? defaults.bool(forKey: showLegalMarkersKey) : true,
            showCoordinates: defaults.object(forKey: showCoordinatesKey) == nil
                ? true : defaults.bool(forKey: showCoordinatesKey),
            animationsEnabled: defaults.object(forKey: animationsEnabledKey) == nil
                ? true : defaults.bool(forKey: animationsEnabledKey),
            pieceStyle: defaults.string(forKey: pieceStyleKey)
                .flatMap(PieceStyle.init(rawValue:)) ?? .merida
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(moveMethod.rawValue, forKey: Self.moveMethodKey)
        defaults.set(showLegalMarkers, forKey: Self.showLegalMarkersKey)
        defaults.set(showCoordinates, forKey: Self.showCoordinatesKey)
        defaults.set(animationsEnabled, forKey: Self.animationsEnabledKey)
        defaults.set(pieceStyle.rawValue, forKey: Self.pieceStyleKey)
    }
}
