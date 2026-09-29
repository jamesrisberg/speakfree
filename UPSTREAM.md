# Changes offered upstream

The fork's changes (see [FORK.md](FORK.md)) grouped into pull requests for
`definitelyreal/speakfree`, smallest and most self-contained first. Each PR is cut from
`upstream/main` by cherry-picking the listed commits:

```sh
git fetch upstream
git switch -c pr/<name> upstream/main
git cherry-pick <commits…>
swift build && swift test && swiftlint lint --strict
```

Sizes are lines added/removed. Every PR keeps SpeakFree's behavior for its users unless the row
says otherwise, and each was tested with the full suite (1,462 tests at the tip of the fork).

| # | PR | Commits | Size | Depends on | Worth it for SpeakFree because | Risk |
|---|---|---|---|---|---|---|
| 1 | Pin FluidAudio to 0.15.1 | `da9d5b7` | +1/−1 | — | `from: "0.15.1"` lets SwiftPM pick 0.17.x, which does not compile (`DownloadUtils` removed). | None. Upstream may prefer porting to 0.17 instead. |
| 2 | Whisper as a vendored static xcframework | `9a4c34b` | +176/−54, plus a 2.96 MB binary | — | Removes `unsafeFlags` and the Homebrew link; fixes linking Homebrew whisper 1.9.4 / ggml 0.25.3 against the 1.8.3 headers; reproducible build script with checksums; CI no longer needs `brew install whisper-cpp` for the build job. | Repo grows ~3 MB; release scripts changed (verified with `bundle-app.sh`, not a full release). |
| 3 | Recording indicator placement | `041527a`, `2183a25` | +836/−52 | — | Users choose where the recording banner sits (center, bottom, notch, hidden); render harness for visual checks. | Low; new setting defaults to today's center placement. |
| 4 | Dictation control on the local API | `2883352`, `a6d1cca`, `06c7378`, `0d02366` | +1,264/−21 | — | Other tools (agents, scripts) can start/stop dictation and get the text back; off by default behind its own toggle; events never carry transcript text. | Low; new surface area on a loopback-only, optionally token-guarded server. |
| 5 | Reliable live API tests | `6512a91` | +69/−47 | 4 (touches its tests) | `LocalAPIServer` reports real readiness and shutdown; the live tests stop flaking under load. | None for users; small API addition (`onReady`, `stop(completion:)`). |
| 6 | Extract the recording flow into `DictationSession` | `94d0bef`, `ff66669` | +2,622/−1,628 | 4 | `AppDelegate` shrinks by ~2,400 lines; the recording state machine is tested end to end with fakes (both destinations, retarget, cancel, post-buffer, failures); finalize work stays off the main thread. | The largest change. Four small intended behavior changes (listed in FORK.md). Best reviewed with its tests and an afternoon of real dictation. |
| 7 | Capture-failed status stays visible | `c88bbec` | +52/−2 | 6 | The 4 s "capture failed" state and red banner were cleared as soon as the alert closed. | None. |
| 8 | Key gesture recognizer (opt-in) | `ca15512`, `fe47372`, `36b8435` | +828/−29 | 6 | A tested recognizer for hold/toggle with an optional second gesture (double-tap in toggle, tap-then-hold in hold). Off by default; proved identical to today when off. Fixes key-repeat toggling for non-modifier hotkeys. | Low when off. The second gesture needs a consumer (for example, sending to Edit mode or another destination). |
| 9 | Embedding support | `147fe19`, `b190a19`, `88d4f12`, `288bffa` | +134/−30 | 6, 8 | Lets another app use SpeakFree as a library: a `SpeakFreeLib` product, public `HotkeyManager`, Sparkle behind an `AppUpdater` protocol (the app injects it), host-chosen retention. | None for the app; mostly access modifiers. Only valuable if upstream wants SpeakFree embeddable. |

## Talking points

- Nothing here is MacHUD-specific in code or commits; MacHUD only consumes the library.
- 1, 2, 3 and 7 are plain fixes or features any SpeakFree user benefits from.
- 4 and 8 add capability without changing defaults.
- 6 is the one to discuss: it is a large refactor of the core flow. It makes the rest possible
  and is well tested, but it will conflict with any in-flight upstream work in `AppDelegate`.
- If upstream prefers not to take 6 or 9, the fork keeps them and syncs as described in FORK.md.
