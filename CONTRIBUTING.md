# Contributing

Thank you for helping improve Chess Coach.

## Development

1. Use an Apple silicon Mac with macOS 26 and Xcode 26.
2. Run `./scripts/fetch-stockfish.sh`.
3. Run `./scripts/generate-project.sh`.
4. Run `./scripts/test-unit.sh` before opening a pull request.

Keep Stockfish authoritative for move selection and preserve the deterministic
coaching fallback so the app remains playable without network access or a model
provider.

## Provider changes

Provider integrations must use `InferenceConfiguration`, keep credentials out
of logs and persisted non-secret settings, require HTTPS for remote endpoints,
and retain local schema and semantic validation. Add tests for request formats,
fallback behavior, error handling, and credential redaction.

## Pull requests

Keep changes focused, explain user-visible behavior, and include test evidence.
Do not commit API keys, signing identities, private endpoints, confidential
material, generated Stockfish binaries, build output, or notarized artifacts.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
