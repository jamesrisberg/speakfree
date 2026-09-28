<p align="center">
  <img src="logo.png" width="100" alt="speakfree logo">
</p>

<h1 align="center">speakfree</h1>

<p align="center">
  Hold a key, speak, release — your words appear at the cursor.<br>
  100% local. No internet. No account. Free forever.
</p>

<p align="center">
  <strong>🌐 Website &amp; downloads: <a href="https://definitelyreal.github.io/speakfree/">definitelyreal.github.io/speakfree</a></strong>
</p>

<p align="center">
  <a href="https://github.com/definitelyreal/speakfree/releases/latest"><img src="https://img.shields.io/github/v/release/definitelyreal/speakfree?label=download&style=flat-square" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT">
</p>

---

## Install

1. Download **[speakfree.dmg](https://github.com/definitelyreal/speakfree/releases/latest)** and open it
2. Drag **speakfree.app** to your Applications folder
3. Open it — **right-click → Open** on the first launch (macOS security step, required once)
4. Grant **Microphone** and **Accessibility** permissions when prompted
5. On first launch, a window appears to download the speech model — **NVIDIA Parakeet (English)** by default, ~600 MB one-time

The speakfree icon appears in your menu bar when it's running.

> **Requires macOS 14 or later on Apple Silicon (M1 or newer).** Intel Macs are not supported — the default Parakeet engine runs on the Neural Engine, and the build links Apple-Silicon Homebrew paths. Older releases ran on macOS 13, but this version moves the minimum up to 14. If you're on macOS 13, the last release that supports you is the previous one — you won't receive updates past it.

## Usage

**Hold** the Globe key (🌐, bottom-left of keyboard), **speak**, then **release**.

Your words are typed wherever your cursor is. If no text field is focused, the transcription is copied to your clipboard instead.

## Settings

Click the menu bar icon → **Settings** to change everything in-app:

| Setting | Options |
|---|---|
| **Hotkey** | Globe 🌐, Left/Right Command ⌘, Left/Right Option ⌥, Left Control ⌃ |
| **Engine & model** | Parakeet English (default), or any Whisper size (see below) |
| **Punctuation** | Hybrid (default), Off, Spoken words |
| **Key Mode** | Hold (default), Toggle |
| **Indicator** | Center of screen (default), Bottom of screen, Under the notch, Hidden |
| **Past Recordings** | Keep everything (default), or cap at the last 10–100 |

Click **Help** in the menu for plain-English explanations of every setting.

## Local API (experimental)

Off by default. Turn on **Local Transcription API** under Settings → Advanced. The server listens on `127.0.0.1:5765` (`localAPIPort`), refuses anything that is not from this Mac, rejects non-loopback `Host` headers, and, when `localAPIToken` is set in `~/.config/speakfree/config.json`, requires `Authorization: Bearer <token>` on every request.

| Endpoint | What it does |
|---|---|
| `POST /v1/audio/transcriptions` | OpenAI-compatible file transcription (multipart `file`, optional `response_format=text`) |

**Dictation control** is a second opt-in (**Dictation Control** in Settings, `localAPIAllowControl` in config), because it turns the microphone on. With it off, these routes answer `403`.

| Endpoint | What it does |
|---|---|
| `POST /v1/dictation/start` | Start recording. JSON body: `destination` = `"caller"` (default; text comes back over the API and is never typed) or `"cursor"` (typed like a hotkey dictation); optional `engine` (must match the active engine, else `422`); optional `timeout_ms` (auto-stop, default 300000, max 1800000). Returns `{id, state, destination}`. `409` if a dictation is already in progress. |
| `POST /v1/dictation/{id}/stop` | Stop and finalize. Waits for transcription, then returns the session; for `caller` it includes `raw` (engine output), `processed` (punctuation and glossary applied) and `styled` (what would have been typed). |
| `POST /v1/dictation/{id}/cancel` | Discard the take. While transcribing, only `caller` sessions can be cancelled (their text is dropped). |
| `GET /v1/dictation/{id}` | Session state: `recording`, `transcribing`, `done`, `error`, or `cancelled`. |
| `GET /v1/events` | Server-sent events for every dictation, hotkey ones included (`id` is `null` for those). `event: state` with `{"state", "id", "error"?}` (`idle`, `recording`, `transcribing`, `done`, `error`, `cancelled`), and `event: level` with `{"level": 0..1}` about 10 times a second while recording. Events never contain transcript text. |

```bash
id=$(curl -s -X POST localhost:5765/v1/dictation/start -d '{"destination":"caller"}' | jq -r .id)
# ...speak...
curl -s -X POST localhost:5765/v1/dictation/$id/stop   # {"state":"done","styled":"…",…}
curl -N localhost:5765/v1/events                         # live state + input level
```

API dictations use the same recording path as the hotkey (buffering, silence checks, text cleanup, the recording banner, and your recordings setting). Pressing the hotkey during an API dictation stops it the same way it would stop your own.

## Microphones — and the AirPods problem

The built-in Mac microphone is the default because it transcribes most reliably. You can pin any mic in **Settings → Microphone**; a pinned mic stays pinned even when you join a call or plug in headphones.

AirPods deserve an honest note, because no dictation app handles them perfectly and we would rather explain the tradeoff than pretend it away:

- **Bluetooth makes you choose.** The moment any app records from an AirPods mic, the headset switches from its high-quality listening profile to its lower-quality call profile. Dictating through AirPods means everything you hear drops to call quality until you stop.
- **Accuracy is situational.** In a quiet room, the Mac's built-in mic transcribes better than AirPods. In a noisy place (a plane, a café, a street), the AirPods mic — built to isolate your voice — is often the best microphone you own.
- **Auto-switching guesses wrong.** We tried automatic behaviors, and they produced surprising results more often than good ones.

The compromise we chose: **you decide, with the cost stated up front.** The built-in mic is the default, and AirPods are never silently substituted. While AirPods are connected, a **Dictation Mode** toggle appears in the menu bar — turn it on to pin the AirPods mic for noisy environments (the toggle itself tells you audio output will drop to call quality while it's on), turn it off and your previous mic comes back.

## Transcription engines

speakfree can transcribe with one of two local engines. Both run entirely on your Mac — no audio or text ever leaves your computer.

| Engine | Parakeet (default) | Whisper |
|---|---|---|
| Maker | NVIDIA | OpenAI (via whisper.cpp) |
| Runs on | Apple Neural Engine | CPU / Metal GPU |
| Speed & accuracy | Higher | Good |
| Live preview | No — text appears when you release | Yes — words appear as you speak |
| Download | ~600 MB, one-time | 75 MB – 3 GB (see Models) |
| Requires | macOS 14+ | macOS 14+ |

**Parakeet** is the default: NVIDIA's speech model running on the Apple Neural Engine — faster and more accurate than Whisper for English. The default model is the English-only variant (`parakeet-tdt-0.6b-v2`); choosing a non-English language switches to the multilingual variant (v3). Parakeet does **not** show a live preview — your text appears all at once when you release the key.

**Whisper** is the alternative if you want a live preview of your words as you speak, or a smaller download — it offers a range of model sizes (see [Models](#models)).

Switch engines in **Settings**. Models download automatically the first time you select them.

## Models

These are the **Whisper** model sizes, for when you switch off the default Parakeet engine. Larger models are more accurate but take longer to transcribe. (Parakeet uses a single ~600 MB model — see [Transcription engines](#transcription-engines).)

| Model | Size | Speed | Best for |
|---|---|---|---|
| tiny.en | 75 MB | Fastest | Quick notes, short phrases |
| base.en | 142 MB | Fast | Small download, decent accuracy |
| small.en | 466 MB | Moderate | Technical terms, longer dictation |
| medium.en | 1.5 GB | Slower | High accuracy |
| **large-v3-turbo** | **1.5 GB** | **Fast** | **Whisper default — best accuracy/speed balance** |
| large | 3 GB | Slowest | Best accuracy (M1 Pro+ recommended) |

Switching models downloads automatically if needed.

## Privacy

speakfree runs entirely on your Mac.

- No audio or text ever leaves your computer
- No servers, no accounts, no subscriptions
- Internet is only needed once — to download a model on first launch (Parakeet by default, or a Whisper model if you switch engines)
- Audio is transcribed locally. Recordings are kept on your Mac (`~/.config/speakfree/recordings`) so you can review past dictations — cap or delete them anytime in Settings

## Build from source

Apple Silicon only — `Package.swift` links whisper-cpp from the Apple-Silicon Homebrew prefix (`/opt/homebrew`), so Intel Macs cannot build this project.

```bash
git clone https://github.com/definitelyreal/speakfree.git
cd speakfree
brew install whisper-cpp
swift build -c release
bash scripts/bundle-app.sh .build/release/speakfree speakfree.app dev
open speakfree.app
```

## Credits

Forked from [open-wispr](https://github.com/human37/open-wispr) by [human37](https://github.com/human37). Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Parakeet speech recognition powered by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).

## License

MIT — see [LICENSE](LICENSE)

The Parakeet engine pulls in third-party components under their own licenses: the FluidAudio SDK (Apache-2.0) and the NVIDIA Parakeet model weights (CC-BY-4.0). Attribution for both is in [Credits](#credits).
