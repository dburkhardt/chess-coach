# Chess Coach agent release guardrails

- Never launch an app directly from `dist/.candidates`, an `.xcarchive`,
  `DerivedData`, or another build directory with `open` or by executing its
  binary.
- For ordinary user requests to open Chess Coach, run
  `./scripts/open-approved-app.sh`. It verifies and opens only the approved app
  installed at `/Applications/Chess Coach.app`.
- A raw candidate may be opened only through
  `./scripts/open-candidate-preview.sh`. It is an explicitly unapproved,
  isolated QA session and must retain the visible QA Candidate banner. The
  sole non-preview exception is the source-bound
  `./scripts/release.sh prepare` or `capture` visual-QA harness, which launches
  the candidate with `--visual-qa`, captures the required evidence, and exits.
- Never describe a candidate as ready, accepted, installed, published, or
  released unless its source-bound receipt has reached the corresponding
  stage.
- Never bypass failed visual capture, OCR, geometry validation, human visual
  approval, installed visual approval, or prompt-free runtime approval.
- After a successful release, verify and launch the exact installed build with
  `./scripts/open-approved-app.sh` before reporting completion.
