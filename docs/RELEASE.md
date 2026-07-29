# Release and visual-acceptance gate

Chess Coach releases are intentionally split into three human-visible stages.
There is no one-command path that can build, publish, and install an unreviewed
app.

Each artifact also has a machine-readable lifecycle receipt:

```text
built → capture-failed → captured → candidate-approved
      → installed-approved → runtime-approved → published
```

Stages never move backward. Reaching a stage records the hashes of the evidence
required by that stage.

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

The signed archive is immediately quarantined at:

```text
dist/.candidates/<git-commit>/<signed-executable-sha256>/
├── ChessCoach.xcarchive/
└── receipt.tsv
```

There is deliberately no friendly `dist/ChessCoach.xcarchive` path. The receipt
binds the stage to the source commit/tree, version/build, bundle ID, executable
SHA-256, Code Directory hash, Team ID, and signing authority.

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

The receipt becomes `capture-failed`, and the exact signed artifact can be
retried without rebuilding or re-signing:

```bash
./scripts/release.sh capture
```

A failed candidate may be opened for diagnosis only with
`./scripts/open-candidate-preview.sh`. That explicit path supplies
`--candidate-preview`, isolates games, preferences, and credentials, and keeps
an orange `QA Candidate · Unapproved` banner visible. It is not an approval.

Candidate capture runs the complete scenario list inside one long-lived
shipping process. macOS may require one click to make that window foreground
and key at the start; the runner then resets the app between scenarios without
relaunching it or racing another bundle with the same identifier.

The harness captures these full windows:

- `fresh-default-dark`: the first game at the normal window size in Dark Mode.
- `fresh-compact-dark`: the first game at the minimum supported window size in
  Dark Mode, with the navigation sidebar collapsed to preserve the board and
  Coach.
- `fresh-default-light`: the first game at the normal size in Light Mode.
- `sidebar-collapsed-default-dark`: the native navigation sidebar collapsed
  while the game and Coach remain usable.
- `sidebar-restored-expanded-default-light`: the same native sidebar expanded
  again after a real collapse/expand cycle, guarding restored horizontal
  offsets and leading-edge clipping.
- `sidebar-minimum-width-default-light` and
  `sidebar-maximum-width-default-light`: the expanded native sidebar at its
  190- and 260-point boundaries.
- `sidebar-inactive-selection-default-light` and
  `sidebar-inactive-selection-default-dark`: the selected destination in its
  inactive-window treatment in both appearances.
- `lesson-default-dark`: an unclocked teaching moment with inline Reveal and
  quiet Done controls.
- `lesson-clocked-default-dark`: a clocked teaching moment with its explicit
  paused status and Continue control.
- `completed-default-dark`: a finished game with its compact Coach treatment.
- `missing-inference-key-default-light`: the live Coach warning and working
  route shown when no inference credential is configured.
- `missing-inference-key-minimum-inspector-light`,
  `missing-inference-key-minimum-inspector-large-text-light`, and
  `missing-inference-key-maximum-inspector-light`: the same footer at the
  Coach inspector's 300- and 460-point boundaries, including its vertically
  adapting large-text treatment at the minimum width.
- `inference-settings-default-light`: the main Settings screen scrolled to,
  focused on, and pointer-tested through the provider-neutral Inference key
  field. The process must remain responsive for five seconds afterward.

The candidate harness uses an in-memory credential store. Ordinary coaching
scenes use a keyless custom OpenAI-compatible provider pointed at a closed local
port; the two configuration scenes deliberately use an empty credential. The
release gate never reads a real key or sends a request to an external provider.

The process writes a PNG and a JSON sidecar for each scenario. In addition to
the scenario, capture kind, app version/build, bundle ID, and pixel size, every
sidecar records screen-space frames for the window, navigation and its rows,
game-detail column, board, move history, Coach inspector, and provider footer
when present. Board and move-history probes are owned by game detail, and every
probe is generically checked against its declared owner. Capture fails before
writing evidence when a required probe is missing, has a non-positive frame,
leaves its owner, overlaps another column, or misses a requested boundary
width.

Before any evidence is accepted, a native macOS Vision pass also verifies that
scenario-critical text is visibly present in the pixels. Navigation labels must
be recognized inside the navigation column, so a surviving toolbar title cannot
hide a clipped `Current Game` row. Fresh-game captures also require the Coach,
Hint, Moves, Computer, and You labels; lesson and completed-game captures require
their scene-specific teaching or outcome text. The missing-key and Settings
captures require the provider-neutral warning, route, Inference heading,
provider, secure-key label, and model field. This automated check is a regression
guard, not a substitute for inspecting the contact sheet.

`ChessCoachTests/Fixtures/beta9-truncated-navigation.png` is the original
truncated beta.9 window capture. A unit test runs that real pixel artifact
through the same Vision validator and requires rejection, so OCR-region
regressions cannot be replaced by geometry-only fixtures.

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

Successful capture changes the receipt to `captured`; the artifact is still not
approved, installed, ready, or published.

## 2. Review and explicitly approve

Run the approval command printed by Prepare:

```bash
./scripts/approve-release-visual-qa.sh \
  --app "<exact quarantined app path printed by Prepare>"
```

The command verifies the evidence, opens the contact sheet, asks for the
reviewer's name, and requires them to type `APPROVE <commit>`. It records the
commit and manifest SHA-256 in `approval.tsv`, then advances the receipt to
`candidate-approved`.

Before approving, inspect every labeled window in the required scenario list and confirm:

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
promotes it to `Chess-Coach-0.1.0-beta.10.dmg` and writes the checksum only after
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
exact installed executable path. This advances the receipt to
`installed-approved`.

A screenshot cannot prove that macOS did not present a SecurityAgent dialog.
Publish therefore has a final, separate runtime gate. The installed app uses
the provider-isolated credential service and never reads or migrates legacy
provider-specific entries, and explicitly prohibits authentication UI during
credential operations. It also rejects sustained app-process CPU or memory
growth that would indicate a render spin. The gate uses a separate release-QA-only service
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
Successful prompt-free runtime approval advances the receipt to
`runtime-approved`.

Any source edit, rebuild, re-sign, changed capture, or changed scenario
requirement forces a new Prepare → Review → Approve cycle. Neither stage runs
the Xcode UI-test runner.

Development builds and unit tests disable code signing. The release flow invokes
each Developer ID signing command once and stops on failure; it does not retry a
Keychain authorization failure or ask for a password in the terminal.

After runtime approval, Publish atomically records the final DMG and checksum
basenames and SHA-256 hashes while the receipt remains `runtime-approved`. At
that point the accepted `/Applications` installation and those exact package
bytes are durable. A GitHub or network failure does not roll them back or
delete them. Running `./scripts/release.sh publish` again skips signing,
notarization, installation, and human gates and resumes from the preserved
package.

GitHub publication is source-bound and retry-safe:

- The annotated `v0.1.0-beta.10` tag must resolve locally and remotely to the
  receipt commit, whose Git tree must also match.
- A new GitHub release starts as a private draft with canonical provenance for
  the source commit/tree, signed executable SHA-256, Code Directory hash, DMG
  SHA-256, and checksum-asset SHA-256.
- Only missing draft assets are uploaded. A mismatched asset may be replaced
  only while that exact-provenance release is still a draft; a mismatch on a
  public release is a hard failure.
- Both assets must report the expected GitHub SHA-256 digest, download with the
  same byte hash, and the downloaded checksum must validate the downloaded DMG.
- The draft is made public only after those checks, then the public release,
  assets, and remote tag target are verified again.

Only after the verified tag, GitHub release URL, remote asset names, public
asset URLs, and remote digests are atomically recorded does the receipt reach
`published`. If GitHub became public immediately before a local interruption,
the next Publish run verifies the existing release and completes the receipt
without replacing anything. Repeating Publish after `published` is a
verification-only operation.

## Opening Chess Coach safely

For an ordinary “open the app” request, always run:

```bash
./scripts/open-approved-app.sh
```

It targets only `/Applications/Chess Coach.app`, verifies the executable and
Code Directory hashes against installed visual and prompt-free runtime
approvals, then verifies the launched process path. During the beta.8-to-beta.10
transition it can validate beta.8's legacy hash-bound evidence without creating
a synthetic receipt.

Never directly open an app under `dist/.candidates`, an `.xcarchive`,
DerivedData, or another build directory. The repository `AGENTS.md` makes this
rule explicit for automation.

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
6. Preserve the exact runtime-approved app, DMG, and checksum before any remote
   mutation, then verify the source tag and GitHub release assets before the
   receipt can say `published`.

The installation/rollback transition is signal-safe: state is recorded before
each `/Applications` rename, rollback ignores subsequent termination signals
while restoring, and it fingerprints the provisional executable before moving
it. If restoration cannot complete, it preserves a runnable verified copy
instead of deleting an app it cannot identify.
