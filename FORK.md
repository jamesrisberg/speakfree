# This fork

`jamesrisberg/speakfree` is a fork of [definitelyreal/speakfree](https://github.com/definitelyreal/speakfree).
It stays a normal SpeakFree (same app, same behavior for its users) and also serves as the
dictation engine inside [MacHUD](https://github.com/jamesrisberg/machud)'s voice host, which
links `SpeakFreeLib` as a Swift package.

Branches:

| Branch | What it is |
|---|---|
| `main` | Mirrors `upstream/main`. Never committed to directly. |
| `integration/machud` | `main` plus every fork change below. MacHUD builds against this (checked out at `~/dev/speakfree`). |
| `feature/*` | Individual changes, kept so each can be offered upstream on its own. |

Nothing in the fork mentions MacHUD in code, tests or commit messages: every change is written
so it could be merged upstream as is. The candidate pull requests, in the order they would go, are
in [UPSTREAM.md](UPSTREAM.md).

## What the fork changes

Relative to upstream `d29835e` (v1.7.2, 2026-09-17). Each row says whether it is useful to
SpeakFree on its own or only to a host that embeds SpeakFree.

### Useful to SpeakFree itself

| Change | Commits | What users or maintainers get |
|---|---|---|
| Recording indicator placement | `041527a`, `2183a25` | Settings → General → Indicator: center, bottom, under the notch (hanging from the menu bar without one) or hidden. A render harness for checking placement. |
| Dictation control on the local API | `2883352`, `a6d1cca`, `06c7378`, `0d02366` | `POST /v1/dictation/start|stop|cancel`, `GET /v1/dictation/{id}`, `GET /v1/events` (state and mic level, never transcript text), behind a new "Dictation Control" toggle (`localAPIAllowControl`, off by default). Text can come back to the caller instead of being typed. |
| Capture-failed state stays visible | `c88bbec` | After a capture failure the 4-second "capture failed" status and the red banner now show as designed; before, they were cleared the moment the alert closed. |
| Live API tests no longer flake | `6512a91` | `LocalAPIServer.start(onReady:)` and `stop(completion:)` report the listener's real `.ready`/`.cancelled`; the live tests wait on them instead of polling `lsof`, which failed under full-suite load. |
| FluidAudio pinned to the API SpeakFree uses | `da9d5b7` | `Package.swift` said `from: "0.15.1"`, so any other package resolving SpeakFree picked FluidAudio 0.17.x, which removed `DownloadUtils` and does not compile. Pinned to `exact: "0.15.1"`. (Moving the code to FluidAudio 0.17 is the longer-term fix.) |
| Whisper linked from a vendored static xcframework | `9a4c34b` | No more `unsafeFlags` against Homebrew's `libwhisper`. The build had been linking Homebrew whisper.cpp 1.9.4 (ggml 0.25.3) against 1.8.3 headers, a real ABI mismatch. `scripts/vendor/build-whisper-xcframework.sh` rebuilds `whisper.xcframework` (v1.8.3, ggml 0.9.5, the same as the vendored dylibs) reproducibly and checksummed; the app binary no longer links any whisper/ggml dylib. The vendored dylibs remain for the `whisper-cli` fallback. Adds 2.96 MB to the repo. |
| Recording flow extracted into `DictationSession` | `94d0bef`, `ff66669` | `AppDelegate`'s recording state machine (about 2,400 lines) moves into `DictationSession`, which the app, the local API and tests drive. Finalize work (transcription, text pipeline, recording store) runs off the main thread, as before the extraction. Behavior is unchanged except: API cancel during the post-buffer now discards the take (it used to report "cancelled" and still type); streaming partials update the preview on main; the secure-input retry is cancelled after the mic check; mic-unavailable hotkey refusals emit nothing. 1,462 tests pass. |
| Key gesture recognizer | `ca15512`, `fe47372` | A pure, tested `KeyGestureRecognizer` behind `HotkeyManager` (off unless a caller passes `gestures:`). With it off, hold and toggle behave exactly as before (proved by an exhaustive test). Also fixes a held non-modifier hotkey toggling on every key repeat. |

### Useful to hosts that embed SpeakFree

| Change | Commits | Why |
|---|---|---|
| `SpeakFreeLib` library product | `147fe19` | Other packages can depend on the library. |
| Public `HotkeyManager` API | `b190a19` | A host can drive the fn key and gestures itself. |
| Sparkle moved out of the library | `88d4f12` | `AppUpdater` protocol in `SpeakFreeLib`; the Sparkle implementation lives in the `speakfree` app target, so hosts don't link Sparkle. The app behaves as before. |
| Host-supplied retention | `288bffa` | `DictationSession(recorder:inserter:retentionConfig:)` lets a host decide what finished takes keep (for example, nothing). |
| Recorder starts the device catalog | `97c839e` | `AudioRecorder.warmUp()` starts `AudioDeviceCatalog`'s cache (`startCache()` is now idempotent). Without `AppDelegate` the cache stayed empty, so a host's first take was routed to no device and failed with "Capture failed". |

None of the changes are fork-only in the sense of being wrong for upstream; the host-facing ones
simply matter less to an app that is never embedded.

## Staying in sync with upstream

Check once a month (or when upstream tags a release):

```sh
cd ~/dev/speakfree
git fetch upstream
git log --oneline integration/machud..upstream/main   # what's new upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout integration/machud && git merge upstream/main
swift build && swift test && swiftlint lint --strict
```

Then rebuild MacHUD (`cd ~/dev/machud && swift test && ./build.sh`) and run a dictation.

- Merge (don't rebase) `integration/machud`: it is the branch MacHUD builds from, and merges keep
  each sync reviewable.
- Files most likely to conflict: `AppDelegate.swift` (the recording flow moved out of it),
  `DictationSession.swift`, `HotkeyManager.swift`, `Package.swift`, `Config.swift`, the settings
  views. When upstream changes recording behavior in `AppDelegate`, port the change into
  `DictationSession` rather than restoring the old code.
- When upstream merges one of the changes above, the next sync brings it back as upstream's
  commit; resolve any conflict in upstream's favor and delete the matching `feature/*` branch.
- If `Package.swift` upstream moves FluidAudio or whisper, re-check the pin and the vendored
  xcframework (`scripts/vendor/whisper.xcframework.sha256`).
- Keep SpeakFree's comment style (dated, attributed notes) in files upstream owns; don't rewrite it.
