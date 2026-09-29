# Changes offered upstream

The fork's changes (see [FORK.md](FORK.md)) grouped into pull requests for
`definitelyreal/speakfree`, smallest and most self-contained first. Each PR is a branch on
`origin` (`jamesrisberg/speakfree`), built from the fork's commits with review fixes folded in,
and cut from `upstream/main` (`d29835e`) or stacked on the PR it depends on. Open each PR
against upstream `main`; a stacked branch's PR shows its base's commits until the base merges
(or open it against the base branch in the fork to review only its own commits).

Every branch builds, passes `swift test` and `swiftlint lint --strict` on its own (branches
without PR 5 carry upstream's live API tests, which can fail on a heavily loaded machine exactly
as they do on `upstream/main`). Merged
together they equal `integration/machud` apart from this file and FORK.md; the one overlap is
a single line: `pr/indicator-placement` sets `recordingOverlay.placement` in AppDelegate's old
recording start, which `pr/dictation-session` moves into `present(.starting)`, so whichever
lands second carries that line over (1,462 tests pass on the combination).

Sizes are lines added/removed relative to the branch's base. Every PR keeps SpeakFree's behavior
for its users unless the row says otherwise.

| # | PR | Branch | Base | Commits | Size | Worth it for SpeakFree because | Risk |
|---|---|---|---|---|---|---|---|
| 1 | Pin FluidAudio to 0.15.1 | `pr/fluidaudio-pin` | `upstream/main` | `d6c4b4d` | +1/−1 | `from: "0.15.1"` lets SwiftPM pick 0.17.x, which does not compile (`DownloadUtils` removed). | None. Upstream may prefer porting to 0.17 instead. |
| 2 | Whisper as a vendored static xcframework | `pr/whisper-xcframework` | `upstream/main` | `536e144` | +176/−54, plus a 2.96 MB binary | Removes `unsafeFlags` and the Homebrew link; fixes linking Homebrew whisper 1.9.4 / ggml 0.25.3 against the 1.8.3 headers; reproducible build script with checksums; CI no longer needs `brew install whisper-cpp` for the build job. | Repo grows ~3 MB; release scripts changed (verified with `bundle-app.sh`, not a full release). |
| 3 | Recording indicator placement | `pr/indicator-placement` | `upstream/main` | `26bbff8`, `4ecf566` | +836/−52 | Users choose where the recording banner sits (center, bottom, notch, hidden); render harness for visual checks. | Low; new setting defaults to today's center placement. |
| 4 | Dictation control on the local API | `pr/dictation-api` | `upstream/main` | `71b61f0`, `52bbd50`, `5d9abb7` | +1,264/−21 | Other tools (agents, scripts) can start/stop dictation and get the text back; off by default behind its own toggle; events never carry transcript text. | Low; new surface area on a loopback-only, optionally token-guarded server. |
| 5 | Reliable live API tests | `pr/live-api-tests` | `pr/dictation-api` | `09cefaf` | +69/−47 | `LocalAPIServer` reports real readiness and shutdown; the live tests stop flaking under load (upstream's own suite fails them on a loaded machine). | None for users; small API addition (`onReady`, `stop(completion:)`). |
| 6 | Extract the recording flow into `DictationSession` | `pr/dictation-session` | `pr/dictation-api` | `0cb5960` | +2,581/−1,586 | `AppDelegate` shrinks by ~2,400 lines; the recording state machine is tested end to end with fakes (both destinations, retarget, cancel, post-buffer, failures); finalize work stays off the main thread. | The largest change. Four small intended behavior changes (listed in FORK.md and the commit). Best reviewed with its tests and an afternoon of real dictation. |
| 7 | Capture-failed status stays visible | `pr/capture-failed-state` | `pr/dictation-session` | `8173e4f` | +52/−2 | The 4 s "capture failed" state and red banner were cleared as soon as the alert closed. | None. |
| 8 | Key gesture recognizer (opt-in) | `pr/key-gestures` | `pr/dictation-session` | `3d88ee0`, `16d118a` | +823/−25 | A tested recognizer for hold/toggle with an optional second gesture (double-tap in toggle, tap-then-hold in hold). Off by default; proved identical to today when off. Fixes key-repeat toggling for non-modifier hotkeys. | Low when off. The second gesture needs a consumer (for example, sending to Edit mode or another destination). |
| 9 | Embedding support | `pr/embedding` | `pr/key-gestures` | `357e6d6`, `5ee2f13`, `9cda41f` | +134/−30 | Lets another app use SpeakFree as a library: a `SpeakFreeLib` product, public `HotkeyManager`, Sparkle behind an `AppUpdater` protocol (the app injects it), host-chosen retention. | None for the app; mostly access modifiers. Only valuable if upstream wants SpeakFree embeddable. |

The branches map to the fork's history as follows: 6 also carries the two HotkeyManager comment
fixes that point at `DictationSession` (fork commit `36b8435`); 4's settings toggle and docs
are one commit; 6 folds the off-main finalize fix into the extraction. If a branch needs
changes after review, amend it with new commits on the branch (never force-push a branch
upstream is reviewing) and bring the same change to `integration/machud`.

## Talking points

- Nothing here is MacHUD-specific in code or commits; MacHUD only consumes the library.
- 1, 2, 3 and 7 are plain fixes or features any SpeakFree user benefits from.
- 4 and 8 add capability without changing defaults.
- 6 is the one to discuss: it is a large refactor of the core flow. It makes the rest possible
  and is well tested, but it will conflict with any in-flight upstream work in `AppDelegate`.
- If upstream prefers not to take 6 or 9, the fork keeps them and syncs as described in FORK.md.
