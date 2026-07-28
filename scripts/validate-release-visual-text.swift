#!/usr/bin/env swift

import AppKit
import Foundation
import Vision

private struct Arguments {
    let scenario: String
    let imageURL: URL

    static func parse(_ arguments: [String]) throws -> Arguments {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1)
            else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let scenario = value(after: "--scenario"), !scenario.isEmpty else {
            throw ValidationError.usage
        }
        guard let imagePath = value(after: "--image"), !imagePath.isEmpty else {
            throw ValidationError.usage
        }
        return Arguments(
            scenario: scenario,
            imageURL: URL(fileURLWithPath: imagePath).standardizedFileURL
        )
    }
}

private enum ValidationError: LocalizedError {
    case usage
    case unsupportedScenario(String)
    case unreadableImage(String)
    case recognitionFailed(String)
    case missingAnchors([String], navigationText: String, fullText: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            usage: validate-release-visual-text.swift \
            --scenario <scenario> --image </absolute/image.png>
            """
        case .unsupportedScenario(let scenario):
            "unsupported visual-QA scenario: \(scenario)"
        case .unreadableImage(let path):
            "could not read a CGImage from \(path)"
        case .recognitionFailed(let message):
            "Vision text recognition failed: \(message)"
        case .missingAnchors(
            let anchors,
            let navigationText,
            let fullText
        ):
            """
            required release text was not visible: \(anchors.joined(separator: ", "))
            navigation OCR: \(navigationText)
            full-window OCR: \(fullText)
            """
        }
    }
}

private struct RecognizedLine {
    let text: String
    let bounds: CGRect
}

private enum TextRegion {
    case navigation
    case coach
    case fullWindow

    func contains(_ line: RecognizedLine) -> Bool {
        switch self {
        case .navigation:
            // The navigation labels live well inside the leading column.
            // Checking their OCR coordinates prevents a still-visible toolbar
            // title ("Current Game") from concealing a clipped navigation row.
            line.bounds.midX < 0.16
        case .coach:
            line.bounds.midX > 0.70
        case .fullWindow:
            true
        }
    }
}

private struct RequiredAnchor {
    let description: String
    let alternatives: [String]
    let region: TextRegion

    init(
        _ description: String,
        alternatives: [String]? = nil,
        region: TextRegion
    ) {
        self.description = description
        self.alternatives = alternatives ?? [description]
        self.region = region
    }
}

private let navigationAnchors = [
    RequiredAnchor("New Game", region: .navigation),
    RequiredAnchor("Current Game", region: .navigation),
    RequiredAnchor("Games", region: .navigation),
    RequiredAnchor("Progress", region: .navigation),
    RequiredAnchor("Settings", region: .navigation),
]

private func requirements(for scenario: String) throws -> [RequiredAnchor] {
    switch scenario {
    case "fresh-default-dark",
         "fresh-compact-dark",
         "fresh-default-light",
         "installed-default-dark":
        return navigationAnchors + [
            RequiredAnchor("Coach", region: .coach),
            RequiredAnchor("Hint", region: .coach),
            RequiredAnchor("Ask about this position", region: .coach),
            RequiredAnchor("Moves", region: .fullWindow),
            RequiredAnchor("Computer", region: .fullWindow),
            RequiredAnchor("You", region: .fullWindow),
        ]
    case "missing-inference-key-default-light":
        return navigationAnchors + [
            RequiredAnchor("Coach", region: .coach),
            RequiredAnchor("Hint", region: .coach),
            RequiredAnchor(
                "No inference key configured",
                region: .coach
            ),
            RequiredAnchor("Configure here", region: .coach),
            RequiredAnchor("Moves", region: .fullWindow),
            RequiredAnchor("Computer", region: .fullWindow),
            RequiredAnchor("You", region: .fullWindow),
        ]
    case "inference-settings-default-light":
        return navigationAnchors + [
            RequiredAnchor("Inference", region: .fullWindow),
            RequiredAnchor("Provider", region: .fullWindow),
            RequiredAnchor("Inference key", region: .fullWindow),
            RequiredAnchor("Model ID", region: .fullWindow),
        ]
    case "lesson-default-dark":
        return navigationAnchors + [
            RequiredAnchor("Coach", region: .coach),
            RequiredAnchor("Teaching moment", region: .coach),
        ]
    case "completed-default-dark":
        return navigationAnchors + [
            RequiredAnchor("Coach", region: .coach),
            RequiredAnchor(
                "completed-game status",
                alternatives: ["Game complete", "Game over"],
                region: .coach
            ),
            RequiredAnchor(
                "game outcome",
                alternatives: [
                    "resigned",
                    "checkmate",
                    "draw",
                    "stalemate",
                    "wins",
                    "timeout",
                    "time out",
                ],
                region: .fullWindow
            ),
        ]
    default:
        throw ValidationError.unsupportedScenario(scenario)
    }
}

private func normalized(_ value: String) -> String {
    let folded = value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
    let scalars = folded.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(scalars)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

private func joinedText(
    from lines: [RecognizedLine],
    in region: TextRegion
) -> String {
    lines
        .filter(region.contains)
        .sorted { lhs, rhs in
            let verticalDifference = abs(lhs.bounds.midY - rhs.bounds.midY)
            if verticalDifference > 0.01 {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        .map(\.text)
        .joined(separator: " ")
}

private func recognizeText(in image: CGImage) throws -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.006

    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
        throw ValidationError.recognitionFailed(error.localizedDescription)
    }

    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else {
            return nil
        }
        return RecognizedLine(text: text, bounds: observation.boundingBox)
    }
}

private func loadImage(at url: URL) throws -> CGImage {
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(
              forProposedRect: nil,
              context: nil,
              hints: nil
          )
    else {
        throw ValidationError.unreadableImage(url.path)
    }
    return cgImage
}

private func validate(_ arguments: Arguments) throws {
    let requirements = try requirements(for: arguments.scenario)
    let lines = try recognizeText(in: loadImage(at: arguments.imageURL))

    let textByRegion: [TextRegion: String] = [
        .navigation: normalized(joinedText(from: lines, in: .navigation)),
        .coach: normalized(joinedText(from: lines, in: .coach)),
        .fullWindow: normalized(joinedText(from: lines, in: .fullWindow)),
    ]

    let missing = requirements.filter { requirement in
        guard let regionText = textByRegion[requirement.region] else {
            return true
        }
        return !requirement.alternatives.contains { alternative in
            regionText.contains(normalized(alternative))
        }
    }

    guard missing.isEmpty else {
        throw ValidationError.missingAnchors(
            missing.map(\.description),
            navigationText: textByRegion[.navigation] ?? "",
            fullText: textByRegion[.fullWindow] ?? ""
        )
    }

    print(
        "Visual text validation passed for \(arguments.scenario): " +
        requirements.map(\.description).joined(separator: ", ")
    )
}

do {
    try validate(Arguments.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(
        Data("Visual text validation failed: \(error.localizedDescription)\n".utf8)
    )
    exit(EXIT_FAILURE)
}
