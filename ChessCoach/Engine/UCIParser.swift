import Foundation

struct UCIParser {
    struct Info: Equatable {
        var depth: Int = 0
        var multipv: Int = 1
        var score = EngineScore()
        var wdl: WDL?
        var moves: [String] = []
    }

    static func parseInfo(_ line: String) -> Info? {
        guard line.hasPrefix("info ") else { return nil }
        let tokens = line.split(separator: " ").map(String.init)
        var result = Info()
        var index = 1

        while index < tokens.count {
            switch tokens[index] {
            case "depth" where index + 1 < tokens.count:
                guard let depth = Int(tokens[index + 1]), depth >= 0 else { return nil }
                result.depth = depth
                index += 2
            case "multipv" where index + 1 < tokens.count:
                guard let multipv = Int(tokens[index + 1]), multipv > 0 else { return nil }
                result.multipv = multipv
                index += 2
            case "score" where index + 2 < tokens.count:
                if tokens[index + 1] == "cp" {
                    guard let centipawns = Int(tokens[index + 2]) else { return nil }
                    result.score.centipawns = centipawns
                } else if tokens[index + 1] == "mate" {
                    guard let mate = Int(tokens[index + 2]) else { return nil }
                    result.score.mate = mate
                } else {
                    return nil
                }
                index += 3
            case "wdl" where index + 3 < tokens.count:
                if let win = Int(tokens[index + 1]),
                   let draw = Int(tokens[index + 2]),
                   let loss = Int(tokens[index + 3]),
                   win >= 0, draw >= 0, loss >= 0 {
                    result.wdl = WDL(win: win, draw: draw, loss: loss)
                } else {
                    return nil
                }
                index += 4
            case "pv":
                let moves = Array(tokens.dropFirst(index + 1))
                guard !moves.isEmpty, moves.allSatisfy(isUCIMove) else { return nil }
                result.moves = moves
                index = tokens.count
            default:
                index += 1
            }
        }
        return result.moves.isEmpty ? nil : result
    }

    static func parseBestMove(_ line: String) -> (move: String, ponder: String?)? {
        guard line.hasPrefix("bestmove ") else { return nil }
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2, isUCIMove(tokens[1]) else { return nil }
        let ponderIndex = tokens.firstIndex(of: "ponder")
        let ponder: String? = ponderIndex.flatMap {
            guard $0 + 1 < tokens.count, isUCIMove(tokens[$0 + 1]) else { return nil }
            return tokens[$0 + 1]
        }
        return (tokens[1], ponder)
    }

    static func whitePerspective(_ info: Info, sideToMove: ChessSide) -> Info {
        guard sideToMove == .black else { return info }
        var transformed = info
        transformed.score = transformed.score.inverted()
        transformed.wdl = transformed.wdl?.inverted()
        return transformed
    }

    private static func isUCIMove(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 4 || bytes.count == 5 else { return false }
        guard (97...104).contains(bytes[0]),
              (49...56).contains(bytes[1]),
              (97...104).contains(bytes[2]),
              (49...56).contains(bytes[3])
        else {
            return false
        }
        return bytes.count == 4 || [UInt8(ascii: "q"), UInt8(ascii: "r"), UInt8(ascii: "b"), UInt8(ascii: "n")]
            .contains(bytes[4])
    }
}
