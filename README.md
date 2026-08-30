<img src="docs/icon.png" alt="Subtitles" width="128">

# Subtitles

Live captions for whatever your Mac is playing — videos, calls, podcasts —
rendered as an always-on-top overlay. Everything runs on-device; no audio ever
leaves the machine.

Transcription runs on the **Apple Neural Engine** via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (NVIDIA Parakeet),
at roughly 0.15 real-time factor.

**[subtitles-live.com](https://subtitles-live.com)** is the app itself: built,
signed and notarised, so the audio permission survives updates. Everything
needed to build your own copy is in this repository, and `build.sh` below does
exactly that.

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

Models download themselves on first run — ~633 MB from HuggingFace for the
default, Multilingual on auto-detect — so the first launch takes minutes before
`engine ready` appears. The menu bar shows the progress: a pulsing blue dot on the
icon, and a bar with the percentage and file count in the menu.

`probe.sh` is not ceremony — see below.

## The permission gotcha

macOS will ask for permission to record system audio. **If you skip or miss that
prompt, nothing tells you.** Core Audio returns success from every call, the
device reports itself running, buffers arrive at the correct size and cadence —
and every sample is zero. There is no error anywhere in the stack.

So:

- `./probe.sh` plays a known tone and reports whether real samples arrive. Run it
  after granting permission, and any time the output looks suspiciously empty.
- The app carries a watchdog: if it receives only digital silence while other apps
  are playing audio, it says so in the log. It cannot badge the icon over it —
  a denied grant and an idle machine look identical from inside, and the check it
  relies on misfires at roughly one launch in four.
- **Check Audio Permission…** in the menu is always there, and opens Privacy &
  Security. There is no API for "is capture granted", so the app does not pretend
  to know.
- **Always launch via `./run.sh`.** Running the binary directly makes your terminal
  the TCC-responsible process, and the grant will not apply — you get the silent
  all-zero behaviour above.
- **The grant now survives rebuilds.** `build.sh` signs with a Developer ID
  certificate, so the app keeps one stable identity and TCC keeps its answer.
  This used to be the reverse: ad-hoc signing gave every build a new cdhash,
  which is what macOS identifies an ad-hoc app by, so every single rebuild
  prompted again. Expect one last prompt on the first Developer ID build.
  Machines without the certificate fall back to ad-hoc and get the old
  behaviour — `build.sh` says so when it happens.

## Using it

The app lives in the menu bar (no Dock icon).

| | |
|---|---|
| **⌥⌘S** | pause / resume |
| **Hold ⇧** | make the overlay draggable — it is click-through otherwise |
| **Hold ⌥** | stack the last few boxes back up above the live one; scroll for older |
| **⌘,** | settings — from the menu bar |
| Menu bar | model, source, text size, overlay position, permission state |

The icon badges what the app is doing: **indigo** pulsing while listening, **blue**
while a model downloads, **yellow** if the pipeline falls behind (RTF ≥ 0.8), and
nothing at all when paused, where the icon dims instead. Deliberately never red —
red means recording, and nothing is ever written anywhere.

**Settings** (⌘, from the menu) holds the dials the menu has no room for, in two
panes:

- **UI** — how many lines a box fills before it clears, how solid it is, how much
  of it the pointer dissolves and how far that reach extends, and how many
  finished boxes ⌥ brings back and how far behind the live one they sit, and how
  long a silence forgets them — thirty seconds by default, a slider out to five
  minutes, a field for anything else, or off to keep them until you pause or
  quit. Every control applies to the overlay as you drag it, and the pane opens
  onto a small screen of its own that shows what each one does.
- **Models** — whether non-speech is skipped before it reaches the recogniser,
  whether a speaker change starts a new box, and a **Clear Model Cache** button.
  Every model you try stays downloaded; this removes the ones nothing is using
  and never the one in use. `subtitles --list-models` prints the same answer
  without removing anything.

The UI pane's preview is not a picture of the overlay: it puts the overlay's own
views on a scaled-down desktop, so the paging, the pill, the reveal's falloff and
the ⌥ stack's entrance are the real ones and cannot drift from what the app does.
Point at it and the box dissolves under the pointer; hold ⌥ and the finished
boxes stack up and scroll, and the hole closes — exactly as they do on screen.
Touch a control and the box says what that control does, with its current value
in the sentence.

Its captions are scripted rather than the live transcript, which is deliberate:
the transcript is empty on a quiet machine, and that is most of the time this
window is open — and when it is not, it is somebody else's sentence arriving
mid-drag and re-paging the box under the hand holding the slider.

**Language / Models** is the one setting most people will touch, and language is
the top level of it, because that is the first thing that rules a model in or out:

```
Multilingual                      ← default; detects the language itself
──────────────
English ▸                         ← the only language with a choice of models
──────────────
Latin-script pack · 583 MB
Español  Français  Italiano  Português  Deutsch
──────────────
Full vocabulary · 633 MB
Nederlands  Türkçe  Русский  العربية  हिन्दी
日本語  한국어  Tiếng Việt  Українська  中文
```

The groups are the downloads. The multilingual model ships as two vocabularies —
a pruned Latin-script pack and the full one, which every language outside the six
needs and which auto-detect also takes, having to decode anything. Script is not
the split: Dutch, Turkish and Vietnamese are Latin-script and still sit in the
second group, because the pruned pack was built for the six languages upstream
names and its 2828 tokens cover nothing beyond them. Moving within a group is
instant; crossing between them fetches the other pack. Measured here at RTF
0.08–0.11 on French, the same as Nemotron 560 on English.

**English** opens onto the seven English-only checkpoints, which differ in chunk
size — the latency/accuracy dial. Nemotron at 560 / 1120 / 2240 ms comes first,
then Parakeet EOU at 320 / 1280 / 160 ms, then Parakeet Unified. Each entry
carries its own download size, none of them the packs above: an EOU tier is
215 MB, Nemotron 612 MB, Unified 595 MB.

Punctuation splits the families: the EOU variants emit none, so their output is
unpunctuated lowercase. Nemotron, Unified and Multilingual all punctuate and
capitalise themselves. Unified costs 2.08 s of latency for no advantage over
Nemotron 560 that this project has been able to identify.

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

## Releasing

```bash
./release.sh
```

Builds, packages a DMG, notarizes it with Apple, staples the ticket and verifies
the result the way Gatekeeper will. It stops at the first thing that is wrong
rather than producing a file that fails on someone else's machine — a dirty
working tree, an ad-hoc signature, a rejected notarization.

Needs a `Developer ID Application` certificate in the login keychain, and
notarization credentials stored once:

```bash
xcrun notarytool store-credentials "subtitles-notary" \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
```

Bump `VERSION` (and `BUILD`, which must only ever increase) at the top of
`build.sh` before releasing, and write the release into
[CHANGELOG.md](CHANGELOG.md) while the reasons are still to hand.

## Known limits

- The shipped variants are **not measured by this project** — the numbers in the
  menu are upstream's. The harness in `spike/latency` cannot drive FluidAudio, so
  there is no like-for-like latency/WER comparison yet.
- **Multilingual on auto-detect** is the default. The EOU variants are the ones
  measured; Nemotron 1120 / 2240 are wired but barely tested.
- Non-English needs the **Multilingual** variant; the other six are English-only
  checkpoints. Its sixteen languages are NVIDIA's transcription-ready tier: the
  19 locales its card calls accurate out of the box, 15 languages once the
  regional pairs are folded together, plus Mandarin, which sits a tier down.
  The checkpoint itself reaches ~40 locales via `prompt_id`; the remainder are
  broad-coverage or need fine-tuning first, and adding one is a menu entry plus a
  FLEURS-style code. None of them are measured here.
- Singing is speech as far as the VAD is concerned, so vocal music will be
  transcribed as lyrics.
- Speaker-change breaks are **retrospective**: diarization needs ~1 s of warmup and
  reports on a ~0.5 s cadence, so a word or two of the new speaker can land on the
  outgoing box before it clears. Waiting for the label instead would delay every
  subtitle by the diarizer's cadence.
- First launch downloads ~633 MB, which takes minutes. Switching model downloads
  that variant too — 215 MB for an EOU tier, ~600 MB for the others; each entry
  shows its size. Anything already fetched is kept and skipped, and changing
  language within one Multilingual pack costs nothing.
- Single display; the overlay uses the main screen.

[PLAN.md](PLAN.md) has the measurements, the design decisions, and an honest log of
the things that turned out to be wrong.

## Licence

[FSL-1.1-ALv2](LICENSE) — the [Functional Source License](https://fsl.software).
Read it, build it, modify it, run it for whatever you like. The one thing it
withholds is *competing use*: shipping it as a commercial product that
substitutes for this one. Every release converts to **Apache-2.0 two years after
it is published**, irrevocably — so this is open source on a delay, not a
trapdoor.

Commits up to `dfe4b08` were published under 0BSD and remain so; that grant
cannot be withdrawn, and this is not an attempt to.

That covers the code in this repository. Everything fetched at run time keeps its
own terms — FluidAudio is Apache-2.0, and the models are third-party weights:

| fetched | licence |
|---|---|
| FluidAudio | Apache-2.0 |
| Parakeet EOU 120M, Nemotron Streaming EN | NVIDIA Open Model License |
| Parakeet Unified, Sortformer (speaker change) | CC-BY-4.0 |
| Nemotron 3.5 Multilingual | OpenMDW-1.1 |
| Silero VAD | MIT |

All of them permit commercial use. None is copyleft, and none restricts the field
of use. They do carry conditions — attribution and notice retention, NVIDIA's
requirement not to strip safety guardrails, and defensive patent-termination
clauses in the NVIDIA and OpenMDW terms. Read the model card for whichever
variants you actually ship; this table is a summary, not advice.

Only FluidAudio is compiled in, so it is the only one whose licence has to travel
with the app: `build.sh` assembles `THIRD-PARTY-NOTICES.txt` into the bundle from
the checkout itself — a copy kept here would go stale the next time the dependency
is bumped — and **Acknowledgements…** in the menu opens it. The models are not
distributed with the app; your machine fetches them on first use.
