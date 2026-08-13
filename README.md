# Subtitles

Live captions for whatever your Mac is playing — videos, calls, podcasts —
rendered as an always-on-top overlay. Everything runs on-device; no audio ever
leaves the machine.

Measured **316 ms median / 489 ms p95** from word spoken to word on screen, at
0.25 real-time factor on Apple Silicon.

![status](https://img.shields.io/badge/platform-macOS%2014.2%2B-blue)

---

## Requirements

- macOS 14.2 or later (Core Audio process taps), Apple Silicon
- Xcode command line tools
- Rust (stable)

## Quick start

```bash
./scripts/fetch-deps.sh   # sherpa-onnx libs + ASR model (~400 MB, not versioned)
./build.sh                # Rust core, Swift app, signed .app bundle
./probe.sh                # confirm the audio permission actually took
./run.sh                  # go
```

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
| **Hold ⌥** | make the overlay draggable — it is click-through otherwise |
| Menu bar | source, text size, overlay position, permission state |

**Listen To** picks a source. Entries are app *families*: selecting "Google Chrome"
captures Chrome and all its helper processes, which matters because browsers and
Electron apps never play audio from their main process.

### Command line

```
--model DIR        model directory
--threads N        ASR threads (default 2)
--int8             int8 weights
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
        ↓
[streaming Zipformer transducer]   sherpa-onnx, greedy
        ↓
[LocalAgreement-2 stabiliser]
        ↓
[sentence casing]
        ↓
[overlay]                     3-line pages, clears and restarts like broadcast subs
```

Everything from the ring buffer through casing is a portable Rust core
(`core/`) behind a small C ABI. The tap and the overlay are the only
macOS-specific parts, so a Windows port means replacing those two, not the
pipeline.

Two choices worth knowing about:

- **A streaming transducer, not Whisper.** Whisper is a 30-second-window
  encoder-decoder; streaming it is a bolt-on that lands around 1.5–3 s. A
  transducer emits as you speak and its output is monotonic, which also makes the
  text stable enough that no anti-jitter machinery is needed.
- **CPU, not CoreML.** Measured: CoreML was *worse* (RTF 0.41 vs 0.25) plus a 10 s
  model-load penalty. Per-inference overhead dominates on 20 ms chunks.

## Layout

```
core/          Rust: ring buffer, resampler, ASR binding, stabiliser, casing
app/macos/     Swift: process tap, overlay panel, menu bar, hotkey
third_party/   sherpa-onnx (fetched)
models/        ASR model (fetched)
spike/         throwaway probes from the measurement phase
PLAN.md        design decisions, measurements, and everything that went wrong
```

## Development

```bash
cargo test --manifest-path core/Cargo.toml   # 21 tests
./build.sh && ./probe.sh && ./run.sh
tail -f build/subtitles.log
```

`--headless` gives a terminal renderer that is often easier to debug than the
overlay. The status line shows RTF; sustained values above ~0.8 mean the pipeline
is close to falling behind permanently, since a live stream cannot be caught up.

## Known limits

- Accuracy is measured on clean read speech (0.0 % WER on LibriSpeech clips). Real
  podcasts, calls, and noisy audio will be meaningfully worse.
- Sentence casing lowercases proper nouns — "Hester Prynne" becomes "hester
  prynne". Fixing it properly needs a truecasing model.
- English only as shipped. A French streaming model exists and works (~17 % WER on
  Common Voice); other languages need checking against the sherpa-onnx model zoo.
- Single display; the overlay uses the main screen.

[PLAN.md](PLAN.md) has the measurements, the design decisions, and an honest log of
the things that turned out to be wrong.
