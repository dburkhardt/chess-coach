# Chess Coach

Chess Coach is a native macOS training app that pairs local Stockfish analysis
with grounded, position-aware explanations from OpenAI or a custom
OpenAI-compatible model endpoint.

Current prerelease: **0.1.0-beta.6**

## Requirements

- Apple silicon Mac running macOS 26 or later
- Xcode 26
- Optional: an API key for OpenAI, or an endpoint, model ID, and optional API
  key for a custom OpenAI-compatible service

## Build

```bash
./scripts/fetch-stockfish.sh
./scripts/generate-project.sh
xcodebuild -project ChessCoach.xcodeproj -scheme ChessCoach \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The app remains fully playable without a model provider. Stockfish supplies
opponent moves, evaluations, principal variations, and deterministic coaching
fallbacks locally. Model-generated coaching never chooses moves or overrides
Stockfish.

Provider settings support the OpenAI Responses API, Chat Completions, and an
Automatic mode that prefers Responses and falls back only when an endpoint
explicitly reports that protocol as unsupported. Custom endpoints may be
keyless; when supplied, credentials are sent as Bearer authentication. Remote
endpoints must use HTTPS, while HTTP is permitted for loopback development
servers.

Model discovery is optional. A manually entered model ID can always be tested
and used.

ChessKit 2.0.0 is vendored from its upstream tag for reproducible builds. The
only source compatibility change adds public zero-argument initializers to its
public FEN and SAN serializer classes.

## Tests

The default test path runs unit tests only and disables code signing:

```bash
./scripts/test-unit.sh
```

UI automation is isolated in the `ChessCoach-UI` scheme. Run it manually on a
Mac account where you intend to grant Xcode UI-testing access.

## Coaching estimate

The Progress rating range is an informal coaching estimate. It appears after
five completed, clocked, unassisted games and is not a FIDE, Chess.com, or
Lichess rating. Stockfish level anchors range from 700 at level 1 to 2400 at
level 10 and are calibration inputs, not authoritative human-equivalent
ratings.

## Privacy

Games and the learner profile are stored locally with SwiftData. If a model
provider is configured, that provider receives the current coaching context
for background hint preparation and explicit chat requests. API credentials
are stored in macOS Keychain under provider-specific accounts. The app has no
accounts, telemetry, ads, or cloud sync.

Review the privacy and data-handling terms of any provider you configure.

## Signed packaging

Signed packaging is optional and is not required to build or test the source.
The release script has no embedded signing identity, team, or notarization
profile. Supply all three explicitly:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARYTOOL_PROFILE="your-profile" \
./scripts/release.sh
```

The script creates and verifies `dist/Chess-Coach-0.1.0-beta.6.dmg`. No packaged
binary is part of this source release.

The app icon is reproducible with:

```bash
swift scripts/generate-app-icon.swift
```

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance and
[SECURITY.md](SECURITY.md) for private vulnerability reporting.

## License

Chess Coach is MIT licensed. The bundled Stockfish executable is a separate
GPLv3 program invoked through UCI. Complete license text, exact source links,
asset checksums, and build provenance are available from the in-app Third-Party
Notices view and in `ChessCoach/Resources/ThirdParty`.
