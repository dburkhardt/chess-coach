# Release and visual-acceptance gate

Chess Coach releases are intentionally split into three human-visible stages.
There is no one-command path that can build, publish, and install an unreviewed
app.

## 1. Prepare the exact candidate

Start from a clean, committed worktree:

```bash
./scripts/release.sh prepare
```

The release command rejects any history whose sole root is not sanitized public
`main` at `2f8543890a856bbdf91230b6698cefd679abc2fd`. This prevents an obsolete
provider-specific branch from re-entering release ancestry through a merge.

Before any signing operation, Prepare also runs the same public-source and
Gitleaks checks used by CI, anonymously verifies that public `main` is the exact
release commit, rejects the obsolete `codex/tonight-beta` branch or an
anonymously reachable pre-sanitization commit, and builds Release from a clean
public clone after fetching Stockfish and regenerating the Xcode project.
Publish repeats the source, secret, and public-reachability checks against the
already approved commit.

Prepare performs the non-UI unit and snapshot test suite, creates the unsigned
archive, explicitly signs Stockfish and then the app, and runs the signed app's
in-process visual-QA harness. It does **not** create or notarize a DMG, modify
`/Applications`, or launch a replacement app.

Prepare must run from an unlocked, interactive macOS GUI session. Because
macOS can route same-bundle-ID scene activation to an already running copy,
Prepare asks an installed Chess Coach to quit normally before opening the exact
candidate through LaunchServices. It waits without force-quitting and leaves
the prior installed copy closed. Candidate QA never relaunches an older build;
only the separately verified post-install gate launches the replacement.

The in-app harness locates and captures the actual window created by the
shipping SwiftUI `WindowGroup`; it is forbidden from constructing a second
`NSWindow` or re-hosting `RootView`. It also refuses to capture unless that
window is both foreground and key. This is intentional: WindowServer can return
a correctly sized all-black privacy image when an automated or locked session
cannot activate a window. AppKit's offscreen renderer also omits or corrupts
separately composited materials and inspectors, so it is not accepted as a
fallback. If foreground capture is unavailable, Prepare stops before approval,
packaging, notarization, installation, or publication.

The harness captures these full windows:

- `fresh-default-dark`: the first game at the normal window size in Dark Mode.
- `fresh-compact-dark`: the first game at the minimum supported window size in
  Dark Mode.
- `fresh-default-light`: the first game at the normal size in Light Mode.
- `lesson-default-dark`: an open teaching moment with its fixed controls.
- `completed-default-dark`: a finished game with its compact Coach treatment.
- `missing-inference-key-default-light`: the live Coach warning and working
  route shown when no inference credential is configured.
- `inference-settings-default-light`: the main Settings screen scrolled to and
  focused on the provider-neutral Inference section.

The candidate harness uses an in-memory credential store. Ordinary coaching
scenes use a keyless custom OpenAI-compatible provider pointed at a closed local
port; the two configuration scenes deliberately use an empty credential. The
release gate never reads a real key or sends a request to an external provider.

Each process writes a PNG and a JSON sidecar identifying the scenario, capture
kind, app version/build, bundle ID, and pixel size. A release capture is rejected
if an image is missing, cropped below the whole-window minimum, mislabeled, or
does not match its sidecar.

Before any evidence is accepted, a native macOS Vision pass also verifies that
scenario-critical text is visibly present in the pixels. Navigation labels must
be recognized inside the navigation column, so a surviving toolbar title cannot
hide a clipped `Current Game` row. Fresh-game captures also require the Coach,
Hint, Moves, Computer, and You labels; lesson and completed-game captures require
their scene-specific teaching or outcome text. The missing-key and Settings
captures require the provider-neutral warning, route, Inference heading,
provider, secure-key label, and model field. This automated check is a regression
guard, not a substitute for inspecting the contact sheet.

Prepare creates:

```text
dist/visual-qa/<git-commit>/<app-executable-sha256>/
├── <scenario>.png
├── <scenario>.json
├── contact-sheet.png
└── manifest.tsv
```

The manifest binds every file to the exact Git commit and tree, required
scenario-list hash, version/build, executable SHA-256, signed-app Code Directory
hash, Team ID, and signing authority.

## 2. Review and explicitly approve

Run the approval command printed by Prepare:

```bash
./scripts/approve-release-visual-qa.sh \
  --app dist/ChessCoach.xcarchive/Products/Applications/ChessCoach.app
```

The command verifies the evidence, opens the contact sheet, asks for the
reviewer's name, and requires them to type `APPROVE <commit>`. It records the
commit and manifest SHA-256 in `approval.tsv`.

Before approving, inspect all seven labeled windows and confirm:

- The navigation sidebar, game area, move list, and Coach inspector are all
  visible and separated correctly.
- No pane is blank because content was rendered outside its bounds.
- No text, buttons, composer, or history content is clipped or overflowing.
- The board is square, fully visible, correctly oriented, and uses crisp pieces.
- The default and compact layouts remain usable in both tested appearances.
- Hint, teaching, completed-game, and game-over states show the intended focused
  controls without transcript clutter.
- The missing-key warning is concise, its Settings route is visible, and the
  Inference destination contains provider, key, and model controls.

Approval is deliberately local release evidence under the ignored `dist/`
directory. Regenerating a capture invalidates its prior approval.

## 3. Publish the approved candidate

```bash
./scripts/release.sh publish
```

Publish refuses to proceed unless all of the following are still identical to
the approved evidence:

- The worktree is clean.
- `HEAD` and its Git tree match the manifest.
- The required scenario list and every PNG/JSON/contact-sheet hash match.
- The candidate's version, build, bundle ID, executable SHA-256, signature,
  Code Directory hash, and Team ID match.
- The approval names a reviewer and matches the exact manifest SHA-256.

Only after that verification does Publish create and sign the DMG, submit it for
notarization, staple and validate it, run Gatekeeper checks, and stage the
mounted and reverified app at `/Applications/Chess Coach.app`. Before
replacement, it asks any existing installed Chess Coach process to quit
normally and waits for it; it never silently force-quits a game.

The package keeps a hidden provisional filename throughout notarization,
installation, installed-window review, and prompt-free runtime review. Publish
promotes it to `Chess-Coach-0.1.0-beta.8.dmg` and writes the checksum only after
every gate passes. A failed or interrupted run removes the provisional package
and restores the prior installed app.

The installation is still provisional. Publish next launches that exact
installed executable in a post-install visual-QA mode which:

- Uses the shipping SwiftUI `WindowGroup`, not a test or re-hosted window.
- Uses the user's real standard preferences, including AppKit window/layout
  restoration, while isolating saved games and the Keychain credential. The
  installed gate preserves that restored frame rather than normalizing it to
  the deterministic candidate size.
- Captures another complete window from the installed app itself.
- Runs the same spatial OCR checks for the navigation column, Coach inspector,
  Hint action, composer, board header, and move list.
- Opens the installed screenshot and requires the reviewer to type
  `APPROVE INSTALLED <commit>`.

If capture, OCR, or installed-app approval fails, Publish rolls back to the
previous app and never reports the release complete. Only after installed visual
approval does it launch the app normally and require a stable process at the
exact installed executable path.

A screenshot cannot prove that macOS did not present a SecurityAgent dialog.
Publish therefore has a final, separate runtime gate. Beta 8 uses a fresh,
provider-isolated credential service, never reads or migrates legacy
provider-specific entries, and explicitly prohibits authentication UI during
credential operations. The gate also uses a separate release-QA-only service
and a UUID-scoped disposable account; neither can overlap an inference provider
service or account. The gate:

- Requires `START PROMPT-FREE CHECK <commit>`, gracefully quits the app, and freshly
  invokes the exact installed executable to seed a disposable credential.
- Invokes the executable in a fresh process to read the same credential and
  delete it, then verifies that it is gone. Every probe phase has a 15-second
  timeout. Failure or interruption runs a bounded best-effort cleanup against
  only that UUID-scoped release-QA account.
- Freshly relaunches the exact installed app normally after the persistent
  credential round trip.
- Gives the reviewer a ten-second observation window and explicitly says not to
  approve if any Chess Coach Keychain or password prompt appears.
- Requires `APPROVE PROMPT-FREE <commit>` and records a local
  `runtime-approval.tsv` bound to the installed visual-manifest hash, installed
  visual-approval hash, executable SHA-256, Code Directory hash, version, build,
  bundle ID, Git commit, Git tree, and successful seed/read/delete result.
- Never reads, changes, prints, or asks for an inference key or password. The
  disposable QA value is generated and checked internally by the installed app
  and is removed before the normal relaunch.

Any repeated Keychain/password prompt fails publication and triggers rollback.
The release is not committed merely because the app process remained alive.

Any source edit, rebuild, re-sign, changed capture, or changed scenario
requirement forces a new Prepare → Review → Approve cycle. Neither stage runs
the Xcode UI-test runner.

Development builds and unit tests disable code signing. The release flow invokes
each Developer ID signing command once and stops on failure; it does not retry a
Keychain authorization failure or ask for a password in the terminal.

## Post-install proof

The publish command enforces all of these before it can report completion:

1. Verify the installed version/build, nested signatures, and Gatekeeper result.
2. Capture and OCR the actual installed app under standard window/layout
   preferences.
3. Require separate human approval of that installed whole-window image.
4. Launch normally and verify the stable running process path is exactly
   `/Applications/Chess Coach.app/Contents/MacOS/ChessCoach`.
5. Gracefully relaunch the same artifact, observe it for Keychain/password
   prompts, and require a hash-bound human `APPROVE PROMPT-FREE` decision.

The installation/rollback transition is signal-safe: state is recorded before
each `/Applications` rename, rollback ignores subsequent termination signals
while restoring, and it fingerprints the provisional executable before moving
it. If restoration cannot complete, it preserves a runnable verified copy
instead of deleting an app it cannot identify.
