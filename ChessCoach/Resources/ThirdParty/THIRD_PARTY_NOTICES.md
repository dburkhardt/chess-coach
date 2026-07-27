# Third-party notices

## Stockfish 18

Chess Coach launches Stockfish as a separate executable and communicates with
it through the Universal Chess Interface protocol.

- Project: https://github.com/official-stockfish/Stockfish
- Release: `sf_18`
- Release commit: `cb3d4ee`
- License: GNU General Public License v3.0
- Exact source: https://github.com/official-stockfish/Stockfish/tree/sf_18
- Apple-silicon release asset: `stockfish-macos-m1-apple-silicon.tar`
- Release asset SHA-256: `4d77c4aa3ad9bd1ea8111f2ac5a4620fe7ebf998d6893bf828d49ccd579c8cb0`

The release packaging script includes the upstream `Copying.txt` alongside this
notice.

## ChessKit 2.0.0

- Project: https://github.com/aperechnev/ChessKit
- Version: 2.0.0
- License: MIT
- Local compatibility patch: public initializers for the public FEN and SAN
  serializer classes; no chess behavior was changed.

## Chessnut chess pieces

The default chess-piece artwork is distributed without modification from the
Chessnut vector-piece project.

- Project: https://github.com/LexLuengas/chessnut-pieces
- Pinned commit: `2b8eaf14a31edad7e9deb53b1473e1d4857868a9`
- Copyright: 2015 Alexis Luengas
- License: Apache License 2.0
- Bundled license: `CHESSNUT_APACHE_2.0.txt`

## Sashite Merida chess pieces

The optional Merida piece artwork was downloaded from Sashite's public chess
asset collection on 2026-07-26. The files are unmodified.

- Source: https://sashite.dev/assets/chess/
- Basis: Chess Merida Unicode
- License: CC0 1.0 Universal / public domain
- Bundled notice: `SASHITE_MERIDA_CC0.txt`

## cm-chessboard

Chess Coach's local board interaction reducer was informed by the
MIT-licensed visual-move-input patterns from cm-chessboard. No JavaScript
runtime is embedded in the app.

- Project: https://github.com/shaack/cm-chessboard
- Pinned commit: `600c02fe781702107a398e3d5e2693050cd1e611`
- Copyright: 2017 Stefan Haack
- License: MIT
- Bundled license: `CM_CHESSBOARD_MIT.txt`

## SwiftChessTools

The native board rendering, accessibility, and test structure were informed by
the MIT-licensed SwiftChessTools project. Chess Coach does not import its
ChessCore rules engine; ChessKit remains the sole rules implementation.

- Project: https://github.com/Trickfest/SwiftChessTools
- Pinned commit: `af9cbe6f8185927528cccf9cbe4a7244bc20591b`
- Copyright: 2026 Mark Harris
- License: MIT
- Bundled files: `SWIFTCHESSTOOLS_MIT.txt` and
  `SWIFTCHESSTOOLS_NOTICE.md`
