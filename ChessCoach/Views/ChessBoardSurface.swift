import AppKit
import SwiftUI

struct ChessBoardSurface: View {
    let snapshot: ChessBoardSnapshot
    let preferences: ChessBoardPreferences
    let onMove: (ChessBoardMoveIntent) -> Void
    let onPromotion: (String) -> Void
    let onEscape: () -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @FocusState private var hasKeyboardFocus: Bool
    @State private var interaction = ChessBoardInteraction()
    @State private var hoveredSquare: String?
    @State private var returningPiece: ReturningPiece?
    @State private var presentationFrame: ChessBoardPresentationFrame
    @State private var pendingSnapshots: [ChessBoardSnapshot] = []
    @State private var presentationTask: Task<Void, Never>?
    @State private var presentationGeneration = 0
    @State private var isPresenting = false
    @State private var pendingLocalDrop: PendingLocalDrop?
    @State private var pendingLocalDropTask: Task<Void, Never>?

    init(
        snapshot: ChessBoardSnapshot,
        preferences: ChessBoardPreferences,
        onMove: @escaping (ChessBoardMoveIntent) -> Void,
        onPromotion: @escaping (String) -> Void,
        onEscape: @escaping () -> Bool = { false }
    ) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.onMove = onMove
        self.onPromotion = onPromotion
        self.onEscape = onEscape
        _presentationFrame = State(
            initialValue: ChessBoardPresentationFrame(snapshot: snapshot)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ChessBoardGeometry(
                size: proxy.size,
                perspective: snapshot.perspective,
                displayScale: displayScale
            )

            ZStack {
                boardCanvas(geometry)
                arrowLayer(geometry)
                pieceLayer(geometry)
                coordinateLayer(geometry)
                accessibilityLayer(geometry)
                promotionLayer(geometry)
            }
            .frame(width: geometry.boardRect.width, height: geometry.boardRect.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.black.opacity(0.22), lineWidth: 1 / displayScale)
            }
            .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
            .contentShape(Rectangle())
            .focusable()
            .focused($hasKeyboardFocus)
            .simultaneousGesture(tapGesture(in: geometry))
            .simultaneousGesture(dragGesture(in: geometry))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredSquare = localSquare(at: location, geometry: geometry)
                case .ended:
                    hoveredSquare = nil
                }
            }
            .onKeyPress(.leftArrow) {
                moveKeyboardFocus(column: -1, row: 0, geometry: geometry)
            }
            .onKeyPress(.rightArrow) {
                moveKeyboardFocus(column: 1, row: 0, geometry: geometry)
            }
            .onKeyPress(.upArrow) {
                moveKeyboardFocus(column: 0, row: -1, geometry: geometry)
            }
            .onKeyPress(.downArrow) {
                moveKeyboardFocus(column: 0, row: 1, geometry: geometry)
            }
            .onKeyPress(.space) {
                activateKeyboardSquare()
            }
            .onKeyPress(.return) {
                activateKeyboardSquare()
            }
            .onKeyPress(.escape) {
                if onEscape() {
                    return .handled
                }
                interaction.cancel()
                returningPiece = nil
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chess board, \(snapshot.perspective.displayName) perspective")
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            if interaction.focusedSquare == nil {
                interaction.focusedSquare = snapshot.perspective == .white ? "a1" : "h8"
            }
        }
        .onChange(of: snapshotIdentity) {
            interaction.resetForRevision()
            returningPiece = nil
            if interaction.focusedSquare == nil {
                interaction.focusedSquare = snapshot.perspective == .white ? "a1" : "h8"
            }
            enqueue(snapshot)
        }
        .onDisappear {
            presentationGeneration &+= 1
            presentationTask?.cancel()
            pendingLocalDropTask?.cancel()
        }
    }

    private func boardCanvas(_ geometry: ChessBoardGeometry) -> some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            let localGeometry = ChessBoardGeometry(
                size: size,
                perspective: snapshot.perspective,
                displayScale: displayScale
            )
            for row in 0..<8 {
                for column in 0..<8 {
                    guard let square = localGeometry.square(atColumn: column, row: row),
                          let rect = localGeometry.rect(for: square)
                    else { continue }
                    context.fill(
                        Path(rect),
                        with: .color(localGeometry.isLight(square: square) ? .boardLight : .boardDark)
                    )

                    if snapshot.lastMove?.source == square ||
                        snapshot.lastMove?.destination == square {
                        context.fill(Path(rect), with: .color(.yellow.opacity(0.22)))
                    }
                    if snapshot.checkSquare == square {
                        context.fill(Path(rect), with: .color(.red.opacity(0.48)))
                    }
                    if interaction.selectedSquare == square {
                        context.fill(Path(rect), with: .color(.yellow.opacity(0.38)))
                    }
                    if hoveredSquare == square,
                       interaction.selectedSquare.map({
                           snapshot.destinations(from: $0).contains(square)
                       }) == true {
                        context.fill(Path(rect.insetBy(dx: 2, dy: 2)), with: .color(.white.opacity(0.22)))
                    }
                    if interaction.focusedSquare == square, hasKeyboardFocus {
                        context.stroke(
                            Path(rect.insetBy(dx: 2, dy: 2)),
                            with: .color(.white.opacity(0.9)),
                            style: StrokeStyle(lineWidth: max(2, geometry.squareSide * 0.035))
                        )
                    }
                }
            }

            guard preferences.showLegalMarkers,
                  let source = interaction.selectedSquare
            else { return }
            for destination in snapshot.destinations(from: source) {
                guard let rect = localGeometry.rect(for: destination) else { continue }
                if snapshot.piece(at: destination) == nil {
                    let diameter = rect.width * 0.22
                    let marker = CGRect(
                        x: rect.midX - diameter / 2,
                        y: rect.midY - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.fill(Path(ellipseIn: marker), with: .color(.black.opacity(0.28)))
                } else {
                    let ring = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
                    context.stroke(
                        Path(ellipseIn: ring),
                        with: .color(.red.opacity(0.58)),
                        style: StrokeStyle(lineWidth: max(3, rect.width * 0.065))
                    )
                }
            }
        }
    }

    private func arrowLayer(_ geometry: ChessBoardGeometry) -> some View {
        Canvas { context, _ in
            for arrow in snapshot.arrows {
                guard let start = geometry.center(of: arrow.source),
                      let end = geometry.center(of: arrow.destination)
                else { continue }
                guard let path = ChessHintArrowPolygon.path(
                    from: start,
                    to: end,
                    squareSide: geometry.squareSide
                ) else {
                    continue
                }
                // A single filled silhouette avoids the darker alpha seam
                // produced when a stroked shaft overlaps a separate head.
                context.fill(path, with: .color(.accentColor.opacity(0.82)))
            }
        }
        .allowsHitTesting(false)
    }

    private func pieceLayer(_ geometry: ChessBoardGeometry) -> some View {
        ZStack {
            ForEach(presentationFrame.pieces) { presented in
                let piece = presented.piece
                if let center = geometry.center(of: piece.square) {
                    let isDragged = interaction.drag?.source == piece.square
                    let isLocallyPlaced = pendingLocalDrop?.intent.source == piece.square
                    ChessPieceArtwork(piece: piece, style: preferences.pieceStyle)
                        .frame(width: geometry.squareSide * 0.84, height: geometry.squareSide * 0.84)
                        .opacity(isDragged ? 0.28 : isLocallyPlaced ? 0 : 1)
                        .position(center)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .allowsHitTesting(false)
                }
            }

            if let drag = interaction.drag,
               let piece = snapshot.piece(at: drag.source) {
                ChessPieceArtwork(piece: piece, style: preferences.pieceStyle)
                    .frame(width: geometry.squareSide * 0.9, height: geometry.squareSide * 0.9)
                    .scaleEffect(1.06)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .position(drag.location)
                    .allowsHitTesting(false)
            }

            if let returningPiece,
               let piece = snapshot.piece(at: returningPiece.source) {
                ChessPieceArtwork(piece: piece, style: preferences.pieceStyle)
                    .frame(width: geometry.squareSide * 0.9, height: geometry.squareSide * 0.9)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                    .position(returningPiece.location)
                    .allowsHitTesting(false)
            }

            if let pendingLocalDrop,
               let center = geometry.center(of: pendingLocalDrop.intent.destination) {
                ChessPieceArtwork(
                    piece: pendingLocalDrop.piece,
                    style: preferences.pieceStyle
                )
                .frame(width: geometry.squareSide * 0.9, height: geometry.squareSide * 0.9)
                .position(center)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func coordinateLayer(_ geometry: ChessBoardGeometry) -> some View {
        if preferences.showCoordinates {
            ZStack {
                ForEach(0..<8, id: \.self) { column in
                    if let square = geometry.square(atColumn: column, row: 7),
                       let rect = geometry.rect(for: square) {
                        Text(String(square.first!))
                            .position(
                                x: rect.maxX - max(6, geometry.squareSide * 0.1),
                                y: rect.maxY - max(6, geometry.squareSide * 0.1)
                            )
                            .foregroundStyle(geometry.isLight(square: square) ? Color.boardDark : Color.boardLight)
                    }
                }
                ForEach(0..<8, id: \.self) { row in
                    if let square = geometry.square(atColumn: 0, row: row),
                       let rect = geometry.rect(for: square) {
                        Text(String(square.last!))
                            .position(
                                x: rect.minX + max(6, geometry.squareSide * 0.1),
                                y: rect.minY + max(6, geometry.squareSide * 0.1)
                            )
                            .foregroundStyle(geometry.isLight(square: square) ? Color.boardDark : Color.boardLight)
                    }
                }
            }
            .font(.system(size: max(8, geometry.squareSide * 0.12), weight: .bold, design: .rounded))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func accessibilityLayer(_ geometry: ChessBoardGeometry) -> some View {
        ZStack {
            ForEach(0..<64, id: \.self) { index in
                let column = index % 8
                let row = index / 8
                if let square = geometry.square(atColumn: column, row: row),
                   let rect = geometry.rect(for: square) {
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(for: square))
                        .accessibilityHint(accessibilityHint(for: square))
                        .accessibilityAddTraits(interaction.selectedSquare == square ? .isSelected : [])
                        .accessibilityAction(named: "Select") {
                            handleTap(square)
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func promotionLayer(_ geometry: ChessBoardGeometry) -> some View {
        if let promotion = snapshot.promotionState,
           let destinationRect = geometry.rect(for: promotion.destination) {
            let side = snapshot.piece(at: promotion.source)?.side ?? snapshot.turn
            VStack(spacing: 4) {
                ForEach(promotion.choices, id: \.self) { choice in
                    Button {
                        onPromotion(choice)
                    } label: {
                        ChessPieceArtwork(
                            piece: BoardPiece(square: promotion.destination, side: side, kind: choice),
                            style: preferences.pieceStyle
                        )
                        .frame(width: geometry.squareSide * 0.72, height: geometry.squareSide * 0.72)
                        .frame(width: geometry.squareSide, height: geometry.squareSide)
                        .background(.regularMaterial)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Promote to \(pieceName(choice))")
                }
            }
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.black.opacity(0.2), lineWidth: 1)
            }
            .position(
                x: destinationRect.midX,
                y: min(
                    geometry.boardRect.maxY - geometry.squareSide * 2,
                    max(geometry.boardRect.minY + geometry.squareSide * 2, destinationRect.midY)
                )
            )
            .shadow(radius: 10)
        }
    }

    private func tapGesture(in geometry: ChessBoardGeometry) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                guard !isPresenting, pendingLocalDrop == nil else { return }
                guard let square = localSquare(at: value.location, geometry: geometry) else { return }
                handleTap(square)
            }
    }

    private func dragGesture(in geometry: ChessBoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                guard !isPresenting, pendingLocalDrop == nil else { return }
                if interaction.drag == nil {
                    let source = localSquare(at: value.startLocation, geometry: geometry)
                    guard interaction.beginDrag(
                        square: source,
                        at: value.startLocation,
                        snapshot: snapshot,
                        method: preferences.moveMethod
                    ) else { return }
                }
                interaction.updateDrag(to: value.location)
                hoveredSquare = localSquare(at: value.location, geometry: geometry)
            }
            .onEnded { value in
                guard let drag = interaction.drag else { return }
                let destination = localSquare(at: value.location, geometry: geometry)
                let result = interaction.endDrag(on: destination, snapshot: snapshot)
                hoveredSquare = nil
                switch result {
                case .move(let intent):
                    stageLocalDrop(intent)
                    onMove(intent)
                case .invalidDrop:
                    returnPiece(drag, geometry: geometry)
                default:
                    break
                }
            }
    }

    private func localSquare(at point: CGPoint, geometry: ChessBoardGeometry) -> String? {
        // The surface itself is the board rect, so normalize the parent geometry's origin.
        let normalized = CGPoint(
            x: point.x + geometry.boardRect.minX,
            y: point.y + geometry.boardRect.minY
        )
        return geometry.square(at: normalized)
    }

    private func handleTap(_ square: String) {
        guard !isPresenting, pendingLocalDrop == nil else { return }
        switch interaction.tap(
            square: square,
            snapshot: snapshot,
            method: preferences.moveMethod
        ) {
        case .move(let intent):
            onMove(intent)
        default:
            break
        }
    }

    private func moveKeyboardFocus(
        column: Int,
        row: Int,
        geometry: ChessBoardGeometry
    ) -> KeyPress.Result {
        let current = interaction.focusedSquare
            ?? (snapshot.perspective == .white ? "a1" : "h8")
        if let next = geometry.moving(
            from: current,
            displayColumnDelta: column,
            displayRowDelta: row
        ) {
            interaction.focusedSquare = next
        }
        return .handled
    }

    private func activateKeyboardSquare() -> KeyPress.Result {
        guard !isPresenting, pendingLocalDrop == nil else { return .ignored }
        guard let square = interaction.focusedSquare else { return .ignored }
        handleTap(square)
        return .handled
    }

    private var snapshotIdentity: SnapshotIdentity {
        SnapshotIdentity(
            gameID: snapshot.gameID,
            revision: snapshot.revision,
            plyCount: snapshot.plyCount
        )
    }

    private func enqueue(_ next: ChessBoardSnapshot) {
        if let pendingLocalDrop,
           next.lastMove?.source == pendingLocalDrop.intent.source,
           next.lastMove?.destination == pendingLocalDrop.intent.destination {
            pendingLocalDropTask?.cancel()
            pendingLocalDropTask = nil
            self.pendingLocalDrop = nil
            presentationFrame = presentationFrame.updating(to: next).frame
            return
        }

        let current = presentationFrame.snapshot
        let replacesImmediately =
            current.gameID != next.gameID ||
            next.plyCount <= current.plyCount ||
            next.plyCount > current.plyCount + 1 ||
            reduceMotion ||
            !preferences.animationsEnabled

        if replacesImmediately {
            presentationGeneration &+= 1
            presentationTask?.cancel()
            presentationTask = nil
            pendingSnapshots.removeAll()
            isPresenting = false
            pendingLocalDropTask?.cancel()
            pendingLocalDropTask = nil
            pendingLocalDrop = nil
            presentationFrame = ChessBoardPresentationFrame(snapshot: next)
            return
        }

        guard !pendingSnapshots.contains(where: {
            $0.gameID == next.gameID &&
                $0.revision == next.revision &&
                $0.plyCount == next.plyCount
        }) else {
            return
        }
        pendingSnapshots.append(next)
        startPresentationQueueIfNeeded()
    }

    private func startPresentationQueueIfNeeded() {
        guard presentationTask == nil else { return }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationTask = Task { @MainActor in
            while !Task.isCancelled, !pendingSnapshots.isEmpty {
                let next = pendingSnapshots.removeFirst()
                let update = presentationFrame.updating(to: next)
                let duration = animationDuration(for: update.transition)

                if duration == 0 {
                    presentationFrame = update.frame
                    continue
                }

                isPresenting = true
                withAnimation(.easeInOut(duration: duration)) {
                    presentationFrame = update.frame
                }
                try? await Task.sleep(
                    for: .milliseconds(Int(duration * 1_000) + 12)
                )
            }
            guard generation == presentationGeneration else { return }
            isPresenting = false
            presentationTask = nil
        }
    }

    private func animationDuration(for transition: ChessBoardTransition) -> Double {
        guard !reduceMotion, preferences.animationsEnabled else { return 0 }
        switch transition {
        case .capture, .enPassant:
            return 0.14
        case .castle:
            return 0.20
        case .move, .promotion:
            return 0.18
        case .takeBack, .immediateReplacement:
            return 0
        }
    }

    private func stageLocalDrop(_ intent: ChessBoardMoveIntent) {
        guard let piece = snapshot.piece(at: intent.source) else { return }
        pendingLocalDropTask?.cancel()
        pendingLocalDrop = PendingLocalDrop(intent: intent, piece: piece)
        pendingLocalDropTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard pendingLocalDrop?.intent == intent else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                pendingLocalDrop = nil
            }
            pendingLocalDropTask = nil
        }
    }

    private func returnPiece(
        _ drag: ChessBoardInteraction.Drag,
        geometry: ChessBoardGeometry
    ) {
        guard let origin = geometry.center(of: drag.source) else { return }
        returningPiece = ReturningPiece(source: drag.source, location: drag.location)
        let animation: Animation? = reduceMotion || !preferences.animationsEnabled
            ? nil : .easeOut(duration: 0.12)
        withAnimation(animation) {
            returningPiece?.location = origin
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 1 : 130))
            returningPiece = nil
        }
    }

    private func accessibilityLabel(for square: String) -> String {
        snapshot.piece(at: square)?.accessibilityName ?? "Empty square \(square)"
    }

    private func accessibilityHint(for square: String) -> String {
        if interaction.selectedSquare.map({
            snapshot.destinations(from: $0).contains(square)
        }) == true {
            return "Legal destination. Select to move."
        }
        if snapshot.destinations(from: square).isEmpty == false {
            let destinations = snapshot.destinations(from: square).sorted().joined(separator: ", ")
            return "Select piece. Legal destinations: \(destinations)."
        }
        return ""
    }

    private func pieceName(_ kind: String) -> String {
        switch kind {
        case "q": "queen"
        case "r": "rook"
        case "b": "bishop"
        case "n": "knight"
        default: "piece"
        }
    }
}

private struct ReturningPiece {
    let source: String
    var location: CGPoint
}

private struct SnapshotIdentity: Equatable {
    let gameID: UUID?
    let revision: Int
    let plyCount: Int
}

private struct PendingLocalDrop {
    let intent: ChessBoardMoveIntent
    let piece: BoardPiece
}

struct ChessHintArrowPolygon {
    static func path(
        from start: CGPoint,
        to end: CGPoint,
        squareSide: CGFloat
    ) -> Path? {
        let vertices = vertices(
            from: start,
            to: end,
            squareSide: squareSide
        )
        guard let first = vertices.first else { return nil }
        var path = Path()
        path.move(to: first)
        for point in vertices.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func vertices(
        from start: CGPoint,
        to end: CGPoint,
        squareSide: CGFloat
    ) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1, squareSide > 0 else { return [] }

        let unit = CGVector(dx: dx / distance, dy: dy / distance)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let tailCenter = point(
            start,
            offset: unit,
            amount: min(squareSide * 0.18, distance * 0.16)
        )
        let tip = point(
            end,
            offset: unit,
            amount: -min(squareSide * 0.08, distance * 0.07)
        )
        let usableLength = hypot(tip.x - tailCenter.x, tip.y - tailCenter.y)
        guard usableLength > 4 else { return [] }

        let shaftHalfWidth = max(2.5, squareSide * 0.045)
        let headLength = min(squareSide * 0.30, usableLength * 0.38)
        let headHalfWidth = max(shaftHalfWidth * 2.25, squareSide * 0.115)
        let neck = point(tip, offset: unit, amount: -headLength)

        return [
            point(tailCenter, offset: normal, amount: shaftHalfWidth),
            point(neck, offset: normal, amount: shaftHalfWidth),
            point(neck, offset: normal, amount: headHalfWidth),
            tip,
            point(neck, offset: normal, amount: -headHalfWidth),
            point(neck, offset: normal, amount: -shaftHalfWidth),
            point(tailCenter, offset: normal, amount: -shaftHalfWidth),
        ]
    }

    private static func point(
        _ point: CGPoint,
        offset: CGVector,
        amount: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: point.x + offset.dx * amount,
            y: point.y + offset.dy * amount
        )
    }
}

private struct ChessPieceArtwork: View {
    let piece: BoardPiece
    let style: ChessBoardPreferences.PieceStyle

    var body: some View {
        Group {
            if let image = NSImage(named: assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                Text(piece.glyph)
                    .font(.system(size: 64, weight: .regular, design: .serif))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .shadow(
                        color: .black.opacity(piece.side == .white ? 0.25 : 0.08),
                        radius: 1,
                        y: 1
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var assetName: String {
        let styleName = style == .chessnut ? "Chessnut" : "Merida"
        let color = piece.side == .white ? "White" : "Black"
        let kind = switch piece.kind {
        case "k": "King"
        case "q": "Queen"
        case "r": "Rook"
        case "b": "Bishop"
        case "n": "Knight"
        default: "Pawn"
        }
        return "\(styleName)\(color)\(kind)"
    }
}

extension Color {
    static let boardLight = Color(red: 0.91, green: 0.86, blue: 0.74)
    static let boardDark = Color(red: 0.43, green: 0.56, blue: 0.43)
}
