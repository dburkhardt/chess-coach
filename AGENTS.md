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
- Before any foreground candidate or installed-app QA, tell the user that
  exactly one Chess Coach window will open and wait for explicit approval.
  Launch that session once. Never poll with `open`, repeatedly activate the
  application, or create additional WindowGroup scenes; if macOS does not
  foreground the window, wait passively for one user click.
- Never describe a candidate as ready, accepted, installed, published, or
  released unless its source-bound receipt has reached the corresponding
  stage.
- Never bypass failed visual capture, OCR, geometry validation, human visual
  approval, installed visual approval, or prompt-free runtime approval.
- After a successful release, verify and launch the exact installed build with
  `./scripts/open-approved-app.sh` before reporting completion.
