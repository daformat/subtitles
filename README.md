# Subtitles

Live captions for whatever your Mac is playing — videos, calls, podcasts —
rendered as an always-on-top overlay. Everything runs on-device; no audio ever
leaves the machine.

Transcription runs on the **Apple Neural Engine** via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (NVIDIA Parakeet),
at roughly 0.15 real-time factor.

![status](https://img.shields.io/badge/platform-macOS%2014.2%2B-blue)

---

## Requirements

- macOS 14.2 or later (Core Audio process taps), Apple Silicon
- Xcode command line tools
- Rust (stable)

## Quick start

```bash
./build.sh   # Rust core, Swift app, signed .app bundle
./probe.sh   # confirm the audio permission actually took
./run.sh     # go
```

Models download themselves on first run — ~613 MB from HuggingFace for the default
Nemotron 560, so the first launch takes minutes before `engine ready` appears. The
menu bar shows the progress: a pulsing blue dot on the icon, and a bar with the
percentage and file count in the menu.

`probe.sh` is not ceremony — see below.

## The permission gotcha

macOS will ask for permission to record system audio. **If you skip or miss that
prompt, nothing tells you.** Core Audio returns success from every call, the
device reports itself running, buffers arrive at the correct size and cadence —
and every sample is zero. There is no error anywhere in the stack.

So:

- `./probe.sh` plays a known tone and reports whether real samples arrive. Run it
  after any rebuild.
- The app carries a watchdog: if it receives only digital silence while other apps
  are playing audio, the menu bar icon gets a red dot.
- **Always launch via `./run.sh`.** Running the binary directly makes your terminal
  the TCC-responsible process, and the grant will not apply — you get the silent
  all-zero behaviour above.
- Each `./build.sh` re-signs ad-hoc, which changes the binary's cdhash. macOS
  identifies ad-hoc-signed apps by that hash, so **every rebuild prompts again**.
  Signing with a stable self-signed identity fixes this permanently; see
  [PLAN.md](PLAN.md).

## Using it

The app lives in the menu bar (no Dock icon).

| | |
|---|---|
| **⌥⌘S** | pause / resume |
| **Hold ⇧** | make the overlay draggable — it is click-through otherwise |
| Menu bar | model, source, text size, overlay position, permission state |

**Model** switches between Parakeet variants at runtime and remembers your choice.
They differ in chunk size, which is the latency/accuracy dial: Parakeet EOU at
160 / 320 / 1280 ms, Nemotron at 560 / 1120 / 2240 ms (**560 is the default**),
plus **Parakeet Unified** and **Multilingual**.

Punctuation splits the families: the EOU variants emit none, so their output is
unpunctuated lowercase. Nemotron, Unified and Multilingual all punctuate and
capitalise themselves. Unified costs 2.08 s of latency for no advantage over
Nemotron 560 that this project has been able to identify.

**Multilingual** is the one variant that is not English-only, so its language is
the choice — pick a language from its submenu and you get the model with it.
Auto-detect, or pin one of English, Español, Français, Italiano, Português,
Deutsch, 中文, 日本語. Measured here at RTF 0.08–0.11 on French, the same as
Nemotron 560 on English.

The submenu is grouped by download, because the model ships as two vocabularies:
the six Latin-script languages share a pruned 583 MB pack, while zh/ja — and
Auto-detect, which has to be able to decode anything — need the full 633 MB one.
Moving within a group is instant; crossing between them fetches the other pack.

Picking a variant that has not been downloaded starts its download there and then.
Changing your mind mid-download cancels it and starts the new one immediately;
files already fetched are kept, so switching back resumes rather than restarts.

The overlay fades four seconds after the last *new* text, not after the audio goes
quiet — so a backing track no longer pins a stale subtitle on screen.

**Skip Non-Speech (VAD)** runs Silero ahead of the recogniser so music never
reaches it — without this, a backing track fills the encoder's context and the
first words after it are lost. Measured at ~0.01 RTF, and it identified a 12 s tone
as non-speech to within one percent. On by default. The status line shows what
fraction of the audio it considers speech.

**New Box On Speaker Change** starts a fresh subtitle box when someone else starts
talking, the same way a pause or end-of-utterance does. Off by default because it
runs a second model (Sortformer) on the Neural Engine: measured RTF went from
0.13–0.18 to 0.27–0.33 with it on.
`pkill -USR1 -f Subtitles.app` cycles them, which makes A/B comparison scriptable.
`pkill -USR2 -f Subtitles.app` does the same for sources, cycling over whatever is
audible right now.

**Listen To** picks a source. Entries are app *families*: selecting "Google Chrome"
captures Chrome and all its helper processes, which matters because browsers and
Electron apps never play audio from their main process. Switching clears whatever
is on screen and resets the recogniser, so the new app starts a fresh sentence
rather than continuing the last one.

### Command line

```
--variant NAME     eou160 | eou320 | eou1280 | nemotron560 | nemotron1120 | nemotron2240
                   | unified | multilingual
--headless         no overlay, terminal output only
--font-size N      overlay text size
--reset-position   recentre the overlay
--list-sources     print audio sources and exit (needs no permission)
--quiet            suppress status lines
```

## How it works

```
[Core Audio process tap]      48 kHz stereo f32, ~10.7 ms per callback
        ↓                     realtime thread: copy into the ring, nothing else
[lock-free SPSC ring buffer]
        ↓                     worker thread
[resample 48k stereo → 16k mono]
        ↓
[energy gate + pre-roll]      skips silence; replays ~1 s so no word starts cold
        ↓                     ── C ABI: the core hands frames out here ──
[FluidAudio · Parakeet]       CoreML on the Apple Neural Engine
        ↓
[overlay]                     3-line pages, clears and restarts like broadcast subs
```

Everything from the ring buffer to the C ABI is a portable Rust core (`core/`).
The core deliberately does **not** transcribe — it hands 16 kHz mono frames out
and FluidAudio takes them from there. The tap and the overlay are the only other
macOS-specific parts, so a Windows port means replacing those, not the pipeline.

Two choices worth knowing about:

- **The Neural Engine, not the CPU.** Parakeet's streaming export re-encodes 5.6 s
  of left context per 80 ms chunk. On CPU that measured RTF 10.7–31.8 — about
  100× too slow. On the ANE it runs comfortably faster than real time.
- **A streaming model, not Whisper.** Whisper is a 30-second-window
  encoder-decoder; streaming it is a bolt-on that lands around 1.5–3 s.

## Layout

```
core/          Rust: ring buffer, resampler, voice gate, pre-roll, C ABI
app/macos/     Swift: process tap, FluidAudio engine, overlay, menu bar, hotkey
spike/         throwaway probes from the measurement phase
PLAN.md        design decisions, measurements, and everything that went wrong
```

## Development

```bash
cargo test --manifest-path core/Cargo.toml   # 11 tests
./build.sh && ./probe.sh && ./run.sh
tail -f build/subtitles.log
```

`--headless` gives a terminal renderer that is often easier to debug than the
overlay. The status line shows RTF; sustained values above ~0.8 mean the pipeline
is close to falling behind permanently, since a live stream cannot be caught up.

## Known limits

- The shipped variants are **not measured by this project** — the numbers in the
  menu are upstream's. The harness in `spike/latency` cannot drive FluidAudio, so
  there is no like-for-like latency/WER comparison yet.
- **Nemotron 560 ms** is the default and the tier in daily use; the EOU variants
  are the ones measured. Nemotron 1120 / 2240 are wired but barely tested.
- Non-English needs the **Multilingual** variant; the other six are English-only
  checkpoints. Its nine languages are the ones exposed here — the model itself
  reaches ~40 via `prompt_id`, and adding one is a menu entry plus a FLEURS-style
  code.
- Singing is speech as far as the VAD is concerned, so vocal music will be
  transcribed as lyrics.
- Speaker-change breaks are **retrospective**: diarization needs ~1 s of warmup and
  reports on a ~0.5 s cadence, so a word or two of the new speaker can land on the
  outgoing box before it clears. Waiting for the label instead would delay every
  subtitle by the diarizer's cadence.
- First launch downloads ~613 MB, which takes minutes. Switching model downloads
  that variant too — 215 MB for an EOU tier, ~600 MB for the others; each entry
  shows its size. Anything already fetched is kept and skipped, and changing
  language within one Multilingual pack costs nothing.
- Single display; the overlay uses the main screen.

[PLAN.md](PLAN.md) has the measurements, the design decisions, and an honest log of
the things that turned out to be wrong.

## Licence

[0BSD](LICENSE) — do whatever you like with it, no attribution required.

That covers the code in this repository. Everything fetched at build or run time
keeps its own terms: sherpa-onnx and FluidAudio are Apache-2.0, and the ASR models
are third-party weights with their own licences (check the model card before
shipping anything built on them).
