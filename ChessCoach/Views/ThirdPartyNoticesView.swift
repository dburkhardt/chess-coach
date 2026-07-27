import Foundation
import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: NoticeDocument = .notices

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Document", selection: $selection) {
                    ForEach(NoticeDocument.allCases) { document in
                        Text(document.title).tag(document)
                    }
                }
                .pickerStyle(.segmented)

                if selection == .notices {
                    HStack(spacing: 18) {
                        Link(
                            "Stockfish 18 source",
                            destination: URL(string: "https://github.com/official-stockfish/Stockfish/tree/sf_18")!
                        )
                        Link(
                            "ChessKit 2.0.0 source",
                            destination: URL(string: "https://github.com/aperechnev/ChessKit/tree/2.0.0")!
                        )
                        Link(
                            "Chessnut pieces",
                            destination: URL(string: "https://github.com/LexLuengas/chessnut-pieces/tree/2b8eaf14a31edad7e9deb53b1473e1d4857868a9")!
                        )
                    }
                    .font(.callout)
                }

                ScrollView {
                    Text(selection.contents)
                        .font(selection == .notices ? .body : .system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(20)
            .navigationTitle("Third-Party Notices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 580)
    }
}

private enum NoticeDocument: String, CaseIterable, Identifiable {
    case notices
    case stockfish
    case chessKit
    case chessnut
    case merida
    case boardReferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notices: "Notices"
        case .stockfish: "Stockfish GPLv3"
        case .chessKit: "ChessKit MIT"
        case .chessnut: "Chessnut Apache 2.0"
        case .merida: "Merida CC0"
        case .boardReferences: "Board references"
        }
    }

    var resource: (name: String, extension: String) {
        switch self {
        case .notices: ("THIRD_PARTY_NOTICES", "md")
        case .stockfish: ("STOCKFISH_GPLv3", "txt")
        case .chessKit: ("CHESSKIT_MIT", "txt")
        case .chessnut: ("CHESSNUT_APACHE_2.0", "txt")
        case .merida: ("SASHITE_MERIDA_CC0", "txt")
        case .boardReferences: ("SWIFTCHESSTOOLS_NOTICE", "md")
        }
    }

    var contents: String {
        let resource = resource
        let url = Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension,
            subdirectory: "ThirdParty"
        ) ?? Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension
        )
        guard let url,
              let value = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "This notice could not be loaded from the application bundle."
        }
        return value
    }
}
