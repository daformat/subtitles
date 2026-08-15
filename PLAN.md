# Universal Subtitles — Plan

Real-time transcription of system audio, rendered as an always-on-top subtitle overlay.
The product only works if the delay is small enough to feel live, so latency is the
primary design constraint and everything below is subordinate to it.

**Status:** FluidAudio only — sherpa-onnx removed (§13). Silero VAD in (§17).
First-run download is visible and interruptible (§18); default is Nemotron 560.
Per-app capture actually switches as of §19. Nine languages as of §20.
Phase 3 complete, published to a repo.
Remaining before this is shippable: stable signing identity, real-world WER,
download integrity check and failure handling.
**Repo:** https://github.com/daformat/subtitles
See §8a (ASR latency) and §8b (capture) for measured results.
**Last updated:** 2026-08-13
**Host used for planning:** macOS 15.7.3, Apple Silicon (arm64)

---

## 1. Decisions

| # | Decision | Choice | Confidence | Revisit when |
|---|---|---|---|---|
| D1 | Native vs cross-platform | **Native per platform**, shared portable core | High | — |
| D2 | Platform scope | **macOS first, Windows later** | High | After v1 ships |
| D3 | Transcription location | **Local only** | High | If accuracy proves unusable |
| D4 | Core language | **Rust** (staticlib + C header) | Medium — FFI still unvalidated | Phase 1 (0A used C to avoid hand-transcribing structs) |
| D5 | ASR engine | **Streaming Zipformer transducer** via sherpa-onnx, model `en-2023-06-26` fp32, CPU provider | **High — confirmed by Spike 0A** | If real-world WER disappoints |
| D6 | Capture API (macOS) | **Core Audio process tap** | **High — confirmed by Spike 0B** | — |
| D7 | Translation | **Deferred**, but designed for | Medium | After v1 |

### D1 rationale — why native

Latency is *not* the argument. The UI framework is not where the delay lives (see §3);
Electron would add ~20–40 ms on top of a 300–3000 ms model. The real reasons:

1. **System audio capture is the whole app, and it is pure platform API.** Chromium's
   loopback story on macOS is poor and pushes you toward ScreenCaptureKit, which triggers
   the much heavier Screen Recording permission prompt.
2. **The overlay window is platform API too.** Borderless, always-on-top, click-through,
   never-takes-focus, visible across Spaces and over fullscreen apps — a handful of
   `NSPanel` properties natively, a pile of half-working flags in Electron.
3. **The app is always on.** A Chromium compositor running all day beside a live ASR model
   is a battery cost that undermines the product.

Cross-platform UI toolkits mostly save work you still have to do per-platform anyway
(capture, permissions, window layer). If D2 is ever revisited toward a single UI,
**Tauri v2, not Electron** — native webview, ~10 MB.

---

## 2. Goals / non-goals

**Goals**
- Subtitles that feel live. Target p95 under ~700 ms speaker-to-screen; ~1.2 s acceptable.
- Fully on-device. System audio never leaves the machine.
- Readable output — text that does not jitter or rewrite itself (see §6).
- Low idle cost. This runs all day.

**Non-goals for v1**
- Translation (designed for, not built — see §7)
- Speaker *labelling* (diarization is used, but only to break the page — §14)
- Transcript history, search, export
- Microphone capture (system audio out only)
- Mobile

---

## 3. Latency budget

One word, speaker to screen:

Estimated at planning time, then **measured in Spike 0** (measured values in bold):

| Stage | Estimate | Measured |
|---|---|---|
| Audio tap callback | 5–20 ms | **10.7 ms** (512 frames @ 48 kHz) |
| Resample 48k stereo → 16k mono f32 | < 1 ms | not yet built |
| VAD frame | ~30 ms | not yet built |
| **ASR emit (p50 / p95)** | **200–3000 ms** | **316 ms / 489 ms** (idle machine) |
| Stabilisation (LocalAgreement-2) | — | **0 ms p50, 3 ms p95** |
| Render / compositing | ~16 ms | not yet built |

Everything that is not the model sums to well under ~100 ms — confirmed. **The ASR
architecture is the latency decision; nothing else comes close.**

The estimate held, but with one correction the planning version missed: the p95 tail
degrades to **~1.8 s under machine load** while p50 barely moves (§8a Finding 2). Budget
against p95-under-load, not p50-when-idle.

---

## 4. Architecture

```
[CoreAudio process tap]  ← platform layer, macOS
        ↓ (copy only, no work in callback)
[lock-free SPSC ring buffer]
        ↓ (ASR thread pulls)
[resample → 16k mono f32]
        ↓
[Silero VAD]            ← gates silence/music to prevent hallucination
        ↓
[streaming ASR engine]
        ↓
[stabilizer: LocalAgreement-2]
        ↓ committed / tentative event stream
[SwiftUI overlay NSPanel]
```

The boxed middle — ring buffer through stabilizer — is the portable Rust core. The tap and
the overlay are platform layers. Porting to Windows means replacing the tap with WASAPI
loopback and the overlay with a Win32 layered window; the core is unchanged.

### Repo layout

```
subtitles/
  core/                    # Rust → libsubs.a + subs.h (cbindgen)
    src/lib.rs             # C ABI surface
    src/ring.rs            # lock-free SPSC, allocation-free
    src/resample.rs        # 48k stereo → 16k mono f32
    src/asr.rs             # sherpa-onnx FFI
    src/stabilize.rs       # LocalAgreement-2 → events
    cbindgen.toml
  platform/
    macos/tap.swift        # Core Audio process tap
    windows/               # later: WASAPI loopback
  app/macos/               # SwiftUI app, NSPanel overlay
  bench/                   # Spike 0A latency harness
```

### Core ABI (sketch)

```c
typedef struct subs_engine subs_engine_t;

subs_engine_t* subs_create(const subs_config_t* cfg);
void  subs_push_audio(subs_engine_t*, const float* interleaved,
                      size_t frames, uint32_t sample_rate, uint16_t channels);
void  subs_set_callback(subs_engine_t*, subs_event_cb cb, void* ctx);
void  subs_destroy(subs_engine_t*);
```

Deliberately tiny — this is the entire porting surface.

### Hard rule

**Do nothing in the Core Audio tap callback except copy into the ring and return.**
No allocation, no lock, no logging, no syscall. ASR runs on its own thread pulling from
the far end. Violating this produces intermittent audio glitches that are miserable to
diagnose after the fact.

### Why Rust for the core (D4)

sherpa-onnx already ships a C API *and* bundles Silero VAD, so the core is thinner than it
looks. Rust is chosen mainly for the deferred Windows story: cargo cross-compiles without
a build-system argument, and `cbindgen` emits one header consumed by both a Swift bridging
module and a future Win32 layer. C++ would avoid an FFI hop but costs that tooling.

---

## 5. ASR engine options

| Engine | Emit latency | Notes |
|---|---|---|
| **Streaming Zipformer transducer** (sherpa-onnx) | **measured 316 / 489 ms p50/p95** | Truly streaming, monotonic output, CPU-viable. **CHOSEN — 0.0 % WER on clean speech (§8a).** Model is 310 MB, not the ~100 MB assumed. |
| Parakeet TDT 0.6b (sherpa-onnx, streaming export) | — | **Measured RTF 10.7–31.8 on CPU: ~100× too slow.** Quality is excellent and it emits punctuation and true casing itself. Needs the ANE — see §11. |
| whisper.cpp + LocalAgreement | 1.5–3 s | Best language coverage, worst latency. Whisper is a 30 s-window encoder-decoder; streaming is a bolt-on. Rejected for v1. |
| Apple `SpeechTranscriber` | few hundred ms | Free, on-device, streaming-native. **Requires macOS 26** — dev host is on 15.7. Revisit on upgrade. |
| Cloud (Deepgram / AssemblyAI) | 300–800 ms | Excellent, but violates D3. Rejected. |

The common default is Whisper, and it is the wrong pick here — it yields ~2 s subtitles.
Streaming transducers emit as you speak and their output is monotonic, which also makes
§6 dramatically easier.

### Known risk — language coverage (mostly retired)

Streaming Zipformer coverage is thinner than Whisper's, but better than feared: a French
streaming model exists and works (17.1 % WER on hard Common Voice audio, p95 753 ms —
§8a Finding 4), and the errors are almost entirely proper nouns, so it reads fine as
subtitles. English is excellent. Other languages remain unverified; check the model zoo
before promising one. The Parakeet fallback tier at ~1.2 s stands if a language is missing.

---

## 6. Text stability — largely a non-problem on this engine

> **Updated after Spike 0A.** This section was written expecting jitter to be a major
> UI problem. Measured: LocalAgreement-2 commit lag is **0 ms p50 / 3 ms p95**, and only
> 4 of 66 words were revised at all. Greedy transducer output is monotonic in practice.
> The two-tier render below is therefore **cosmetic, not required** — build the simple
> version first. The warning stands in full for Whisper, where revision is constant.

Streaming ASR *can* continuously revise its hypothesis. Rendering raw partials then makes
text jitter and rewrite itself, which is unreadable and damages perceived quality far
more than 200 ms of extra latency.

**Approach:**
- Run **LocalAgreement-2** — a token is committed only once two consecutive hypotheses
  agree on it.
- Render committed text at full opacity, tentative tail dimmed. The eye learns to trust
  the solid text and ignore the shimmer at the edge.
- Make commit aggressiveness a tunable. Showing a slightly-wrong word fast and correcting
  it usually beats waiting.
- Scrolling 2–3 line window, not a growing transcript.
- VAD-gate the engine so it does not hallucinate over silence or music. (Whisper is
  notorious for emitting "Thank you for watching" on quiet passages; transducers are
  better behaved but still benefit.)

---

## 7. Translation (deferred)

Not in v1, but do not foreclose it: have the stabilizer emit committed segments as an
**event stream** rather than mutating a shared text buffer. A translation stage then
subscribes downstream without restructuring the pipeline.

Expect it to cost an extra ~200–500 ms and to make stability harder — translations rewrite
more aggressively than transcripts, so §6's commit logic will need separate tuning.

---

## 8. Phases

### Spike 0 — measure before building
Two independent, throwaway probes. Run in parallel. Together they retire nearly all the
risk that could invalidate this plan.

**0A — latency + quality harness.** Rust binary: read a WAV, feed it real-time-paced into
sherpa-onnx streaming Zipformer, log `(audio_sample_time, wall_clock_at_emit)` per token.
Report p50/p95 emit latency and WER against a reference transcript.
- *Gate:* p95 < ~700 ms with acceptable accuracy → proceed on the fast tier.
  Otherwise drop to Parakeet and accept ~1.2 s.
- *Also settles:* the language-coverage risk in §5.

**0B — tap probe.** ~50 lines creating a Core Audio process tap and printing RMS.
- *Confirms:* the API path works on 15.7; which permission prompt the user actually sees.
- *Why it matters:* shapes onboarding, and the ScreenCaptureKit fallback is a much worse
  UX. This should be verified rather than assumed.
- Doubles as the seed of the real capture layer.

### Phase 1 — headless CLI
Tap → ring → VAD → engine → stdout with timestamps. No UI. Most of the remaining risk
lives here. Ends with a binary that prints live subtitles for whatever is playing.

Carried in from Spike 0:
- Must be a **bundle launched via `open`**, not a bare binary (§8b Finding 2).
- Ship the **all-zero watchdog** from day one (§8b Finding 1) — without it a
  permissions failure is invisible.
- Resample 48 kHz stereo f32 → 16 kHz mono f32; the tap format is confirmed.
- **Validate the Rust↔sherpa-onnx FFI here** — 0A deliberately used C, so D4 is
  still unproven. Prefer `bindgen` over hand-written externs.
- Instrument RTF continuously; define the degraded-mode fallback to the 20M model.
- Re-measure latency and WER on **real captured system audio**, not test corpora.

### Phase 1 results (DONE, 2026-08-13)

Built: `core/` (Rust), `app/macos/` (Swift), `build.sh`, `run.sh`, `probe.sh`.
15 unit tests green. **D4 validated** — bindgen over the sherpa C API and cbindgen
for the outward header both work; the FFI never needed hand-written externs.

Verified end to end: audio played through the system, captured by the tap,
resampled 48k stereo → 16k mono, gated, transcribed, rendered live.

| Reference | Output |
|---|---|
| AFTER EARLY NIGHTFALL … THE SQUALID QUARTER OF THE BROTHELS | **exact** |
| YET THESE THOUGHTS AFFECTED HESTER PRYNNE LESS WITH HOPE THAN APPREHENSION | **exact** |

RTF **0.10–0.20** (vs 0.25 in the offline harness — the energy gate skips silence
entirely), 0 dropped samples.

#### Bugs this phase found — all of them ordering/lifecycle, none in the ASR

1. **Startup order.** Capture must not begin until the worker is running. Starting
   the tap first buries the opening seconds of speech behind a model load's worth
   of buffered audio. `SystemAudioTap` is therefore split into `prepare()` (create
   tap, read format) and `start()` (begin IO).
2. **Ring overflow policy.** Dropping the *newest* samples when full means a stall
   leaves the stream permanently seconds behind — a live stream can never be caught
   up. The consumer now skips forward when the backlog exceeds 1.5 s. Done on the
   consumer side because it owns the read index, so it stays race-free and `push`
   stays a plain memcpy.
3. **Pre-roll is mandatory.** ~1 s of audio is replayed whenever the gate opens.
   Fixes two things at once: the gate discards the quiet onset of a word, and a
   streaming Zipformer restarted at an endpoint has no left context and emits
   nothing for a second or more. Without it the second utterance lost its first six
   words while the same model decoding the same clip offline got them all — that
   offline control is what proved the fault was ours, not the model's.
4. **Gate ≠ endpoint.** Two separate timeouts (400 ms / 1600 ms). One timeout means
   an ordinary mid-sentence pause resets the recognizer and chops one utterance
   into several lines.
5. **Endpoints must flush.** Text still tentative at an endpoint was discarded on
   reset, silently truncating the tail of any utterance the model was unsure about.
6. **The watchdog counted itself.** Our own aggregate device registers as a process
   outputting audio, so the permission warning fired during ordinary silence. A
   watchdog that cries wolf is worse than none.
7. **One redraw per update.** Commit and tentative each triggering a redraw painted
   the newly committed word beside a stale tail for one frame.

#### Dev-workflow traps (cost more time than any real bug)

- **`open` reuses a running instance.** It activates the existing app rather than
  launching the new binary, so you silently keep testing the last build and read
  stale behaviour as your fix working. `run.sh` now kills any previous instance
  first. Two conclusions in this session were wrong for exactly this reason.
- **`open` without `-W` loses output.** Once a non-waiting `open` exits, the
  redirected stdout/stderr stop receiving; everything after the first moment
  vanishes and the app looks hung.
- **Verify patches applied.** A silent no-op search-and-replace made unchanged code
  look like a working fix. Prefer edits that fail loudly.

#### Rebuilds re-trigger the permission prompt ⚠️

`build.sh` signs ad-hoc (`codesign -s -`). TCC identifies an ad-hoc-signed app by
its **cdhash**, which changes with every rebuild — so macOS treats each build as a
brand-new app and prompts again. Any test that starts audio without waiting will
race the dialog and read "not yet approved" as a broken pipeline. This wasted time
twice in one session.

**Mitigation now:** `probe.sh` retries for ~60 s and tells you to approve.

**Proper fix (not yet done):** sign with a stable self-signed identity instead of
ad-hoc, so the TCC identity survives rebuilds. Create one in Keychain Access
(Certificate Assistant → Create a Certificate → Code Signing, self-signed), then
point `build.sh` at it via `codesign -s "<name>"`. Not done automatically because
it means creating a certificate in the user's keychain.

#### `probe.sh` — answer the permission question before testing

There is no API for "is audio capture granted". The only reliable test is
empirical: play a known sound, see whether any non-zero sample arrives. Run it
before any transcription test, or you race the permission dialog and misread
"not approved yet" as a broken pipeline. Currently reports **GRANTED, peak −19 dBFS**.

#### Not done in Phase 1

- ~~Silero VAD~~ — done in §17; an energy gate was used until music proved it
  insufficient
- Re-measuring first-emit latency in-app — the harness numbers stand, but the
  in-app path adds the tap and ring and has not been measured
- Model is loaded from the dev tree, not bundled (§9 distribution question)

### Phase 2 — the overlay
Click-through `NSPanel`, two-tier text rendering per §6, drag to reposition.

### Phase 2 results (DONE, 2026-08-13)

Built: `app/macos/Overlay.swift` (~265 lines). `--headless` keeps the Phase 1
terminal renderer, which remains the better debugging view.

Verified on screen while real audio played: the panel renders bottom-centre over
other applications, translucent rounded background, centred text, wrapping to
multiple lines.

#### Verified, not assumed

- **Does not steal focus.** Frontmost application sampled before, during and after
  a subtitle: unchanged throughout. This is the property that justified going
  native (§1) and it now has a measurement rather than a claim.
- **Floats above other windows.** Confirmed in capture, over a normal app window.
- **Translucency** reads correctly against arbitrary content behind it.

#### Confirms the Spike 0A prediction

No dimmed tentative tail was visible in any captured frame — because with this
engine the tail is almost always empty (commit lag 0 ms p50, 4 of 66 words ever
revised). §6's two-tier render is implemented and costs nothing, but it is
genuinely cosmetic here, exactly as 0A predicted. It stays because it is what
makes a *revising* engine survivable if the model is ever swapped.

#### Design notes

- **Click-through by default** (`ignoresMouseEvents`), so the overlay never
  swallows a click meant for the app underneath. Hold **⇧** to make it grabbable;
  position is remembered in `UserDefaults`. **⇧ and not ⌥** — holding ⌥ during a
  window drag arms the macOS tiling preview, which fights the drag.
- **⇧ is detected by polling `NSEvent.modifierFlags`**, not a global event
  monitor. A keyboard monitor would require Accessibility permission, and asking
  for a second scary prompt just to enable dragging is a bad trade.
- **The anchor lives in memory while running**; `UserDefaults` is persistence,
  read once at startup and written on release. `layout()` used to re-read the
  defaults on every text update, so a word arriving mid-drag snapped the box back
  to where the drag started — the more the speaker talked, the harder it fought
  the mouse. A `didMove` observer feeds the panel's real position back in, and it
  must be registered with `queue: nil` so it runs synchronously inside the posting
  call: on `.main` it lands after the repositioning flag is cleared and re-derives
  the anchor from a frame we just computed, creeping it half a pixel per word.
- `.nonactivatingPanel` + `canBecomeKey/Main = false` + `.accessory` activation
  policy together are what prevent focus theft. All three are needed.
- `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` so the
  overlay follows the user across Spaces.
- Text draws **bottom-aligned** when it overflows `maxLines`, so the newest line
  stays put and older text slides up — how real subtitles behave.
- The endpoint flush emits COMMITTED then ENDPOINT with no TENTATIVE between, and
  only TENTATIVE drives the overlay, so `endpoint()` repaints explicitly. Without
  that the last words of an uncertain utterance never reach the screen.

#### Refinements after first manual use (2026-08-13)

- **Sentence casing.** The models emit unpunctuated ALL CAPS, which is tiring to
  read. `core/src/textcase.rs` lowercases and capitalises sentence starts plus the
  pronoun "I". Done in the core, not the renderer, so the overlay, the terminal
  view and any future translation stage all agree without duplicating the rule.
  **Cost:** proper nouns lose their capitals ("HESTER PRYNNE" → "hester prynne").
  Nothing in the token stream marks a name. The real fix is a punctuation/
  truecasing model (sherpa-onnx ships CT-Transformer ones) after the stabiliser,
  which would restore capitals *and* full stops for another model and some latency.
- **Paging instead of scrolling.** Text never exceeds 3 lines: when the next words
  would overflow, the overlay clears and restarts from those words, the way
  broadcast subtitles behave. Verified on screen — 2 lines → 3 lines → cleared and
  restarted mid-sentence. Line counting uses `NSLayoutManager` line fragments
  rather than dividing a bounding-rect height, because an off-by-one there pages a
  line early or spills a line late.

#### Not verified / not done

- **Behaviour over a fullscreen app is configured but not tested.**
  `.fullScreenAuxiliary` should cover it; testing it would have meant taking over
  the user's screen.
- **Click-through is set but not click-tested** — verifying it would require
  clicking into the user's actual UI.
- Multi-monitor: uses `NSScreen.main` only; no per-display placement.
- Only the current utterance is shown; no scrollback of previous lines.

### Phase 3 — product
Per-app source picker (process taps can target a single process — just Zoom, just Safari —
which is far better than mixing everything), hotkey toggle, font/size/position settings,
permission onboarding.

### Phase 3 results (DONE, 2026-08-13)

Built: `app/macos/MenuBar.swift`, `app/macos/Hotkey.swift`, source selection in
`SystemAudioTap.swift`.

#### The finding that mattered: a source is an app *family*, not a process

The first cut let you pick a process. Enumeration immediately showed why that is
useless: the only thing playing audio was `com.google.Chrome.helper`, not
`com.google.Chrome`. **Browsers and Electron apps never play audio from their main
process**, so picking "Google Chrome" would have captured silence — the feature
would have looked implemented and worked for almost nothing.

Sources are therefore app families: every process whose bundle id is, or is
prefixed by, a `.regular` (Dock-visible) application's bundle id.
`CATapDescription(stereoMixdownOfProcesses:)` takes an array, so the whole family
is tapped at once. `Claude [3 proc]`, `Google Chrome [3 proc]`.

Grouping targets must be `.regular` apps specifically. Matching against all running
applications re-finds the helper — "Google Chrome Helper" is itself a running
application with its own bundle id and localised name — and groups nothing.

**Verified both directions:** with the source set to Firefox (silent), speech from
another process produced **zero** transcript lines; switched to all system audio,
the same clip transcribed in full.

#### Rest of the phase

- **Menu bar** (`NSStatusItem`), the app's only chrome since it is LSUIElement:
  status line with live RTF, pause/resume, source picker, text size, reset overlay
  position, permission state, quit. The source submenu is rebuilt on every open —
  "what is playing right now" is stale a second after you cache it.
- **⌥⌘S global hotkey** via Carbon `RegisterEventHotKey`, *not*
  `NSEvent.addGlobalMonitorForEvents`. The AppKit monitor sees every keystroke
  system-wide and so needs Accessibility permission; the Carbon hotkey needs none.
  For an app whose pitch is "grant me audio access", not asking for keyboard
  access too is worth the older API.
- **Pause** gates the realtime callback on a plain `Bool`. Word-sized, no tearing
  on arm64, and a lock in the audio callback would cost far more than a dropped
  frame at the moment of toggling.
- **Settings persist** (text size, overlay origin, source). Source is stored as a
  bundle prefix, not a pid, so it survives relaunch.
- **`--list-sources`** prints the source table and exits *before* any tap is
  created, so it needs no audio permission — usable even when permission is the
  thing being debugged.

#### Post-Phase-3 refinements

- **Permission failure moved off the overlay.** It now shows as a yellow dot
  badging the menu bar icon — yellow because red reads as "recording" up there,
  and orange and green are already taken by the system's microphone and camera
  indicators. Covering the subtitles with a diagnostic is exactly when the
  user is least able to tell what is wrong. The dot is a subview, not composited
  into the icon — compositing would force `isTemplate = false` and the icon would
  stop adapting to light/dark menu bars.
- **Pages break at pauses.** A new `SUBS_EVENT_PAUSE` fires at `GATE_HANGOVER`
  (400 ms), and the overlay starts a fresh page on the next words. Display-only:
  the recognizer keeps running, so unlike an endpoint this costs no accuracy —
  the same gate/endpoint separation as Phase 1, applied to the renderer.
- **Overlay width hugs its content**, anchored by centre so it expands
  symmetrically. Measurement uses `NSLayoutManager` line fragments.
- **Fetched, not versioned.** `scripts/fetch-deps.sh` pins the sherpa-onnx
  libraries and the 310 MB model by URL *and* SHA-256. A silently different model
  would change transcription quality with nothing in the diff to explain it.

#### Known gap

When a specific (non-"all") source is selected and that app is silent, the tap
delivers no buffers at all, so the worker sleeps on an empty ring and emits no
status events. The menu bar status line then shows the last value rather than
"idle". Harmless, but it wants a heartbeat status independent of audio arriving.

Selecting a source also did not actually take effect until §19 — the picker was
correct all along, and a leaked device from startup was overriding it.

### Phase 4 — Windows (if ever)
Swap the two platform layers. Core unchanged.

---

## 8a. Spike 0A results — ASR latency (DONE, 2026-08-13)

**Verdict: gate PASSED.** Streaming Zipformer hits p95 489 ms with 0.0 % WER on
clean read speech. D5 confirmed — but see the load-sensitivity caveat, which is
the real finding.

Code: `spike/latency/harness.c`. Test audio: two LibriSpeech clips (23.34 s) shipped
with the model, with reference transcripts.

### Method

Audio is fed to the recognizer at **real-time pace** (20 ms chunks, wall-clock
gated) and every token's first appearance is timestamped. Latency is reported
**relative to the end of the spoken word** (approximated by the next token's start
time) — you cannot emit a word before it has been said, so lag-after-end is the
honest "how far behind the audio am I" figure. Latency from word *start* is ~180 ms
higher and is the number most benchmarks quote; don't confuse the two.

Harness validated by a `--fast` control: unpaced and paced runs produce byte-identical
transcripts, so pacing is not corrupting the input.

### Headline (idle machine, en-2023-06-26, fp32, CPU, 2 threads)

| Metric | Value |
|---|---|
| first-emit p50 | **316 ms** |
| first-emit p95 | **489 ms** |
| first-emit max | 624 ms |
| WER | **0.0 %** (66/66 words) |
| RTF | 0.251 → 4.0× headroom |

### Finding 1 — the transducer needs no stabilisation ✅

LocalAgreement-2 commit delay: **p50 0 ms, p95 3 ms, max 22 ms**; only 4 of 66 words
committed later than their first appearance at all.

Greedy transducer output is monotonic in practice — it essentially never retracts a
token. **§6's two-tier rendering is therefore not needed for correctness.** Keep a
dimmed tail as a cosmetic touch if desired, but the feared text-jitter problem does
not exist on this engine. This removes the largest piece of unknown UI work from the
plan and further vindicates choosing a transducer over Whisper (where the problem is
real and severe).

### Finding 2 — latency is load-sensitive; WER is not ⚠️

The same model, same audio, varying only machine contention:

| Condition | p50 | p95 | RTF | WER |
|---|---|---|---|---|
| Idle (settled) | 316 ms | **489 ms** | 0.25 | 0.0 % |
| Isolated single run | 335 ms | 631 ms | 0.33 | 0.0 % |
| Back-to-back runs | 487 ms | **1816 ms** | 0.70 | 0.0 % |
| Competing with a large download | 279 ms | 952 ms | 0.42 | — |

Accuracy never budged. **Only latency degrades, and the p95 tail degrades ~4×.**

This matters more than the headline: the intended use case is subtitling a video
call, i.e. precisely when the machine is already busy. RTF 0.70 leaves ~1.4×
headroom; if RTF reaches 1.0 the pipeline falls permanently behind, since a
real-time stream cannot be caught up.

**Consequences for Phase 1:**
- Instrument RTF continuously and expose it; treat sustained RTF > 0.8 as a
  degraded state.
- Have a defined fallback when it degrades (drop to the 20M model, or int8).
- The ASR thread should run at elevated (not realtime) QoS.
- Never benchmark on an idle machine and quote that as the product number.

### Finding 3 — CoreML is a negative result ❌

`--provider coreml` was *worse* than CPU: RTF 0.414 vs 0.251, p95 650 ms vs 489 ms,
plus a 10 s model-load penalty (vs ~1–6 s). Per-inference overhead dominates on
20 ms streaming chunks. **Use the CPU provider.** Do not spend more time here.

### Model comparison

| Model | p50 | p95 | RTF | WER | Size |
|---|---|---|---|---|---|
| en-20M-2023-02-17 | 224 ms | 416 ms | 0.19 | 9.1 % | 128 MB |
| **en-2023-06-26** | 316 ms | 489 ms | 0.25 | **0.0 %** | 310 MB |
| en-2023-06-26 int8 | 429 ms | 975 ms | 0.57 | 0.0 % | — |

The 20M model is faster but drops words (it lost "AFTER EARLY NIGHTFALL" entirely and
rendered "BROTHELS" as "BRAFFLELS"). The full model is both accurate and fast enough.
**Ship en-2023-06-26 fp32; keep 20M as the degraded-mode fallback.** int8 showed no
benefit in these runs and is not worth the accuracy risk.

### Finding 4 — French is viable; the §5 language risk is largely retired ✅

`sherpa-onnx-streaming-zipformer-fr-2023-04-14` exists and works. Tested on the
**Common Voice** clips it ships (crowd-sourced real speech — substantially harder
than LibriSpeech):

| Metric | Value |
|---|---|
| first-emit p50 / p95 | 419 ms / **753 ms** |
| WER | 17.1 % |
| RTF | 0.609 → 1.6× headroom |

WER overstates the damage here. Almost every error is a proper noun:

```
hyp: ... DYNASTIE ASHÉMÉNIDE ET SEPT DES SASSANDIDES ... SAINT PIERRE ET MICHELIN
ref: ... DYNASTIE ACHÉMÉNIDE ET SEPT DES SASSANIDES  ... SAINT PIERRE ET MIQUELON
```

As subtitles this is entirely readable. Note the French model is older
(2023, stateless7 rather than zipformer2) and is a fair bit slower — p95 753 ms
against English's 489 ms, with thinner RTF headroom. Usable, not equal.

**The comparison is not apples-to-apples**: English was measured on LibriSpeech
(easy), French on Common Voice (hard). Some of the gap is the test set, not the model.

### Finding 5 — never validate ASR with TTS ⚠️

The same French model scored **96.8 % WER** on speech generated by macOS `say`
(14 hypothesis words against 31 reference), while scoring 17.1 % on real human
speech. ASR models are trained on human acoustics and fall apart on synthetic
audio. `say` is attractive because it gives free ground-truth text — **do not build
a test corpus on it.** Use real recorded speech with reference transcripts.

### Caveat on the 0.0 % WER — do not over-read it

The test audio is clean, read, single-speaker LibriSpeech: close to the easiest
possible input. Real system audio — podcasts with music beds, video calls with
crosstalk, compressed streams, accents, overlapping speakers — will be materially
worse. **0.0 % here means "the pipeline is correct", not "the product is accurate."**
Re-measure on real captured audio during Phase 1.

---

## 8b. Spike 0B results — capture (DONE, 2026-08-13)

**Verdict: process taps work on macOS 15.7.** No virtual audio driver, no
ScreenCaptureKit, no Screen Recording prompt. D6 confirmed.

Code: `spike/tap/` — `tap_probe.swift` (meter), `diag.swift` / `diag2.swift` (variant matrix).

### Measured facts

| Property | Value |
|---|---|
| Tap stream format | 48 000 Hz, 2 ch, 32-bit float packed (flags `0x9`), 8 bytes/frame |
| IOProc granularity | 512 frames ≈ **10.7 ms** |
| Continuity | 2 159 616 frames over 45 s = 44.99 s — zero dropouts |

Capture-side latency is ~11 ms, at the low end of §3's 5–20 ms estimate. The
resample target (48k stereo f32 → 16k mono f32) is confirmed as the real conversion.

### Finding 1 — permission failure is completely silent ⚠️

System audio capture requires the TCC audio-capture grant. When it is **missing**:

- `AudioHardwareCreateProcessTap` → `noErr`
- aggregate device creation → `noErr`, reports `input: [2] ch`
- `AudioDeviceStart` → `noErr`, device reports running
- IOProc fires at the correct rate with correctly-sized buffers
- **every sample is 0.0**

There is no error anywhere in the stack. Verified with one bundle, one grant,
varying only the launch path:

| Launch | Frames | Samples |
|---|---|---|
| `open TapProbe.app` | 5120 / 100 ms | real audio, −31 dB |
| direct exec of the same binary | 5120 / 100 ms | all zeros |

**Consequence for the app:** ship an explicit all-zero watchdog — if N consecutive
seconds of frames arrive with peak == 0 while a process is known to be outputting
audio, surface a "grant audio permission" state. Without it the app looks perfectly
healthy and silently never produces a subtitle. This is a first-run UX landmine.

### Finding 2 — TCC attribution follows the launch path

A binary exec'd from a shell inherits the *terminal's* responsible process, which
does not hold the grant → silent zeros. Launched via `open` (launchd), the app is
its own responsible process and the grant applies.

**Consequence for dev workflow:** the app must be run as a bundle via `open`, never
`swift run` or a bare exec, or you will chase phantom silence. Requires a bundle
with `NSAudioCaptureUsageDescription` and a signature that binds the Info.plist
(ad-hoc `codesign -s -` is sufficient for local dev).

### Finding 3 — `isExclusive` gotcha

Do **not** override `isExclusive` on a description built by
`CATapDescription(stereoGlobalTapButExcludeProcesses:)`. That initializer sets it
to `true` ("the list is an exclusion list"); with an empty list that means tap
everything. Forcing it to `false` reinterprets the empty list as an *inclusion*
list of zero processes — the tap builds cleanly, reports 2 input channels, starts
without error, and then never runs. Cost several hours of misdiagnosis; the
comment in `tap_probe.swift` records it.

### Bonus — the per-app picker is basically free

`kAudioHardwarePropertyProcessObjectList` enumerates every audio process with its
PID and bundle ID, and `kAudioProcessPropertyIsRunningOutput` flags which are
*currently* playing. That is the Phase 3 source picker with no extra research.
`CATapDescription(stereoMixdownOfProcesses:)` then taps just that process — but
note process object IDs are short-lived, so resolve one immediately before
creating the tap (a stale ID returns `'!obj'`).

### Not yet confirmed

- Tap-only aggregate (no output sub-device) with the corrected config — only tested
  under the broken `isExclusive` variant, so its viability is unknown. The
  with-output-sub-device shape is proven and is what Phase 1 should use.
- Behaviour on output-device change mid-capture (headphones plugged in).

---

## 9. Open questions

- **Which languages** does the audio actually need to cover? Nine are now
  selectable (§20) and French measures at the same RTF as English, so this no
  longer blocks anything — but it still shapes the product, because the answer
  decides whether the 633 MB full-vocab pack is needed at all or whether the
  583 MB Latin one covers every real user. The §8a Finding 4 numbers are sherpa-on-
  CPU and no longer apply.
- ~~Exact TCC prompt for process taps~~ — answered in §8b. Requires bundle +
  `NSAudioCaptureUsageDescription` + launch via `open`.
- Model distribution — **partly settled** (§18). The sherpa figure below is dead;
  FluidAudio downloads CoreML bundles from HuggingFace on first run, **613 MB** for
  the default Nemotron 560. Bundling was considered and rejected: it would take the
  app from 7.4 MB to ~620 MB, and the download path has to exist regardless for the
  other six variants. Progress UI is done; **integrity check and failure handling
  are still open**.
- What is the real-world WER on actual system audio (podcast, video call, YouTube)?
  The 0.0 % figure is clean read speech only.
- Does RTF stay under ~0.8 while a video call is running? This is the load case that
  matters and it has not been measured (§8a Finding 2).
- Signing / notarization path — needed before anyone else can run it.
- Where should subtitles sit by default, and should position be per-app?

---

## 11. Model switching, and the Parakeet result (2026-08-13)

The app can now switch models at runtime from the menu bar. `ModelCatalog.swift`
holds the catalogue (URL + SHA-256 + measured characteristics); uninstalled models
download on demand with checksum verification. Selection persists.

Verified: switching between Zipformer EN and EN-20M live reproduces exactly the
harness difference (20M dropped "AFTER EARLY NIGHTFALL" and rendered "BROTHELS" as
"braffls"), and the French model downloaded, verified, extracted and transcribed
without a restart.

`SIGUSR1` cycles the catalogue, so A/B comparison is scriptable:
`pkill -USR1 -f Subtitles.app`.

**Swap safety.** Clearing the engine pointer is not enough — the realtime callback
may already have loaded it and be inside `subs_push_audio`, so destroying it there
is a use-after-free. The swap therefore stops the tap first: `AudioDeviceStop` is
synchronous, so once it returns no IOProc is in flight.

### Parakeet does not work on CPU ❌

sherpa-onnx ships streaming Parakeet 0.6b exports at 240/560/1120 ms latency.
Quality is excellent — on the same LibriSpeech clip it produced *"After early
nightfall, the yellow lamps would light up here and there the squalid quarter of
the brothels"*, **with punctuation and true casing**, which would remove this
project's sentence-casing hack and its lowercased proper nouns.

But measured on this machine:

| Config | RTF |
|---|---|
| Zipformer EN | **0.10** |
| Parakeet 240 ms, 2 threads | 14.7 |
| Parakeet 240 ms, 4 threads | 10.8 |
| Parakeet 240 ms, 8 threads | 31.8 (thread thrashing) |

Roughly 100× too slow. The model's own metadata explains it: the export is
`buffered_streaming=1` with `left_feature_frames=560` — it re-encodes 5.6 s of
left context for every 80 ms chunk. That assumes an accelerator.

**The ANE is the answer, via CoreML.** That is exactly what
[FluidAudio](https://github.com/FluidInference/FluidAudio) exists for (fully local,
Parakeet TDT v2/v3 on the ANE, SwiftPM), and what
[VoiceInk](https://github.com/Beingpax/VoiceInk) uses for the same reason. VoiceInk
is GPL-3.0 and a mic-dictation app rather than a library — useful as a reference
for *approach*, not something to lift code from.

Integrating FluidAudio is a genuinely different shape of work: a SwiftPM dependency
and a second engine implementation on the **Swift** side of the C ABI, whereas
every engine today lives in the Rust core. The core would need to expose resampled
16 kHz frames outward and accept transcript text back, rather than owning the
recognizer. Not started.

**This does not contradict Spike 0A Finding 3.** That measured ONNX Runtime's
CoreML *execution provider* running a Zipformer on 20 ms chunks, where
per-inference overhead dominates. A model exported specifically for the ANE is a
different proposition and needs its own measurement.

---

## 12. FluidAudio engine (DONE, 2026-08-13)

Parakeet now runs, on the Apple Neural Engine, selectable from the menu bar
alongside the sherpa models. Verified end to end: engine switches, models download
from HuggingFace, and live transcription reaches the overlay.

### The seam

The Rust core keeps capture, resampling, gating and pre-roll — that pipeline is
measured and worth keeping. Only the *recogniser* moves out, via a new
`external_engine` config flag: the core then emits gated, pre-rolled 16 kHz mono
frames through `subs_set_audio_callback` instead of transcribing them, and Swift
drives FluidAudio and the overlay directly. The core's stabiliser and sentence
casing sit idle, which is correct — Parakeet punctuates and cases its own output.

### Configurations exposed

| Manager | Variants |
|---|---|
| `StreamingEouAsrManager` (Parakeet EOU 120M) | 160 / 320 / 1280 ms |
| `StreamingNemotronAsrManager` (0.6B) | 560 / 1120 / 2240 ms |

### Findings

**External engines must not be re-primed with pre-roll.** The core replays ~1 s of
history whenever the gate opens, which is right for a recogniser that gets reset at
endpoints. FluidAudio keeps its own rolling buffer across gate cycles, so the
replay fed it the same audio twice and it stuttered — *"whose place was play on
play on play on leonard for ever"* instead of *"whose place was on that same
dishonoured bosom to connect her parent for ever"*. Pre-roll is now sent only after
a reset, when the engine's context is genuinely empty.

**Do not pass a bare `MLModelConfiguration()`.** FluidAudio's own source notes that
its default is `.cpuAndNeuralEngine`, and that under `.all` CoreML routes the int8
encoder to the GPU and runs ~10× slower — i.e. it would silently undo the entire
reason for using it.

**Loading is slow and was silently swallowing audio.** First run downloads ~440 MB
from HuggingFace and then compiles CoreML models; `feed` dropped everything until
`loaded` flipped, with nothing to show for it. There is now an explicit ready
signal and a dropped-frame counter.

### Build-system consequences

FluidAudio is only distributed as a Swift package, so the app moved from raw
`swiftc` to SwiftPM (`Package.swift`). Two traps worth recording:

- **Never name the package directory after a dependency.** SPM derives the root
  package's identity from its directory, so a `fluidaudio/` directory made it look
  for FluidAudio's products *inside itself*, failing with the thoroughly confusing
  `product 'FluidAudio' not found in package 'FluidAudio'`.
- swift-tools-version 6 switches the target to the Swift 6 language mode, which
  the existing AppKit code fails under (main-actor isolation). Pinned to
  `.swiftLanguageMode(.v5)`; migrating properly is worth doing, but not as a side
  effect of adding a dependency.
- The C ABI is exposed as a clang module (`core/include/module.modulemap`) rather
  than `-import-objc-header`, whose relative path only resolves from the right
  working directory.

### Overlay parity fixes

Two behaviours diverged from the sherpa path and are now aligned:

- **Paging.** `showFullText` trimmed words off the front to make the text fit,
  which *scrolls*. Broadcast subtitles deliberately do not scroll, and the delta
  path already pages. It now tracks a page start word, fills to `maxLines`, then
  clears and restarts from the first word that did not fit.
- **The overlay could stay up forever.** FluidAudio's final transcript arrives
  asynchronously, *after* the endpoint armed the fade — and painting it called
  `show()`, which cancelled that timer. Final text now goes through its own
  `onFinal` callback that re-arms the fade. On top of that there is an
  engine-agnostic safety net: the core reports the gate state every second, and an
  `idle` report arms a fade if none is pending, so no late or repeated update can
  strand the overlay on screen.

A third bug surfaced while fixing the first: anchoring a fresh page to
`words.count - 1` showed only the last word, and after an engine reset hid almost
the entire transcript. The new page now starts at the word count recorded when the
pause happened, or at zero if the engine restarted its transcript.

### Not done

- Not measured. The sherpa numbers in this document come from this repo's harness;
  the FluidAudio variants have only been smoke-tested. A like-for-like latency/WER
  comparison is the obvious next step, and the harness cannot currently drive them.
- Only EOU 320 ms and Nemotron 560 ms have actually been exercised; the rest are
  wired but unverified.
- ~~`Parakeet Unified` is not exposed~~ — exposed since, as a third manager with
  its own context-window contract. Costs 2.08 s latency against EOU's 320 ms.

---

## 13. sherpa-onnx removed (2026-08-13)

The app now has exactly one engine: FluidAudio, Parakeet on the Neural Engine.
Everything sherpa is gone — the vendored archives, the bindgen build step, the
model catalogue and downloader, and the sherpa recogniser in the core.

What that deleted, and why it was safe:

| Removed | Why it became dead |
|---|---|
| `core/src/asr.rs` | the core no longer transcribes |
| `core/src/stabilize.rs` | LocalAgreement-2 stabilised sherpa hypotheses; FluidAudio emits whole transcripts |
| `core/src/textcase.rs` | sentence casing fixed sherpa's ALL CAPS output |
| `app/macos/ModelCatalog.swift` | catalogue + downloader for sherpa checkpoints; FluidAudio fetches its own |
| `scripts/fetch-deps.sh`, `third_party/` | nothing left to vendor |
| bindgen in `core/build.rs` | no C API to bind; cbindgen for the outward header stays |

The core went from 1303 to 702 lines and is now purely the audio front end:
capture → ring → resample → gate → pre-roll → frames out. Its C ABI lost
`model_dir`, `num_threads`, `int8` and `external_engine` (there is no longer an
alternative to being external), and the COMMITTED/TENTATIVE events (text no longer
originates in the core).

**RTF moved.** The core measured decode cost, which was the "am I falling behind"
signal — and it can no longer see it. `FluidAudioEngine` now tracks its own
compute-versus-audio ratio over a rolling window and reports it, so the health
signal survives the move. Measured 0.13–0.15 on the ANE.

Verified after removal: builds clean, 11 core tests pass, and live transcription
still reaches the overlay.

**The measurements in §8a and §11 are kept deliberately.** They are why the
project ended up here — particularly the CPU-versus-ANE result, which is the whole
justification for depending on FluidAudio at all. `spike/latency` still contains
the harness that produced them, and still needs sherpa to run; see
`spike/README.md`.

---

## 14. Punctuation, and breaking on speaker change (2026-08-13)

**Punctuation and capitalisation** come from `StreamingUnifiedAsrManager`, now
exposed as the `unified` variant. It is the only Parakeet export that emits them
itself, and it capitalises proper nouns — *"God as a direct consequence…"* — which
the old sentence-casing pass fundamentally could not do. The cost is latency: its
`[70,13,13]` window is 2.08 s against EOU's 320 ms. That is a big enough trade to
be a visible choice rather than a silent default.

**Speaker change breaks the page.** Sortformer runs alongside the recogniser on the
same 16 kHz frames; when the active speaker index changes, the overlay is told to
start fresh on the next words — exactly the treatment a pause already gets.

Deliberately *not* labelling or colouring speakers: all the overlay needs is an
edge. That keeps it cheap, and means a wrong speaker index costs a page break
rather than a wrong name on screen.

| | RTF |
|---|---|
| Recogniser only | 0.13–0.18 |
| With Sortformer | 0.27–0.33 |

Roughly double, so it is **off by default** and toggled from the menu.

**Verified against a control.** Two LibriSpeech utterances butt-joined with no
silence between them, so no pause or endpoint could fire. With the feature on, the
box cleared and restarted at the second speaker's first words; with it off, they
ran straight into the same box (*"…a blessed soul in heaven after early nightfall
the"*). The control happened to run a different ASR variant, which does not affect
the comparison — page-breaking is overlay behaviour, independent of the model
producing the text.

**Known limitation: it is retrospective.** Diarization needs ~1 s of warmup and
reports on a ~0.5 s cadence, so the change is detected *after* the new speaker
starts and a word or two of theirs can land on the outgoing page. The alternative —
holding text until the speaker is known — would delay every subtitle by the
diarizer's cadence, which is the wrong trade for a latency-first app.

---

## 15. Fading on text, not audio (2026-08-13)

The overlay used to fade off the *audio* gate: no sound → endpoint → fade. That
fails on the case that matters most. **Music keeps the voice gate open
indefinitely**, so the endpoint never fires and the last thing anyone said stays
frozen on screen over the soundtrack.

Fading is now driven by **text inactivity** — four seconds without a *changed*
transcript. Verified with 6.6 s of speech followed by a continuous tone: the gate
reported `listening -23dB` throughout, and the overlay still faded.

Two details that matter:

- Only a *changed* transcript counts. Engines resend identical partials, and
  treating those as activity would keep the overlay alive forever on a stuck
  hypothesis.
- It is a **poll**, not a one-shot timer. The previous design had to cancel and
  re-arm on every text change, and anything that forgot to re-arm stranded the
  overlay on screen — which is precisely the bug that had to be fixed once
  already. A poll cannot be forgotten.

### A worse bug this uncovered ⚠️

Testing with `eou160` collapsed the pipeline: RTF climbed past 380, the core's ring
dropped 1.6M samples, and no audio got through at all.

Cause was in the FluidAudio hand-off, not the fade. `onAudioFrames` spawned a
`Task { await engine.feed(samples) }` **per callback**. When the engine falls
behind real time those tasks queue without bound, each holding a sample array, and
the resulting memory pressure drags down the whole process. The actor's internal
`maxPending` bounded the samples it had already accepted — it could not bound the
tasks waiting to hand samples over.

Replaced with a bounded `FrameQueue` (3 s ceiling, drops oldest) drained by a
single long-lived pump task. Same discipline the Rust ring already used: a fixed
ceiling, and drop stale audio rather than accumulate latency that can never be
repaid. Re-tested on the config that broke it — no drops, graceful degradation.

### Clearing on fade

Fading alone was not enough: the page state survived it, so the next words resumed
a paragraph nobody could still see. When the fade *completes* the box is now
emptied and the next words start a new page.

Two details:

- The clear runs in the animation's completion handler and re-checks that the
  panel is still hidden — new text can arrive mid-fade, and discarding the page
  then would throw away what is back on screen.
- `lastFullWordCount` is deliberately **kept**. Engines that never reset keep
  growing a single transcript, so "fresh" has to mean *the words after this point*,
  not *replay everything from the beginning*.
- An unchanged transcript no longer resurrects a faded overlay. Engines resend
  identical partials freely; without that guard the box blinks back and fades again
  on the timer.

Verified with speech → 12 s tone → speech, continuous so no endpoint could fire:
the box showed the first utterance, faded mid-tone despite the gate reporting
`listening` throughout, and the second utterance opened a clean box with no trace
of the first.

Same boundary caveat as the speaker-change break: a word or two arriving in the
same update as the anchor can be skipped, so the new box may start slightly into
the sentence.

### And a finding about the variants

`eou160` is **not viable on this machine**: RTF 0.63–2.22, at or past real time,
because 160 ms chunks double the model invocations per second. `eou320` runs at
0.13–0.15 on the same hardware. Upstream advertises 160 ms as the lowest-latency
tier; on this Mac it is the slowest thing here. The menu now shows the measured
figure rather than the advertised one.

---

## 16. Paging on audio time (2026-08-13)

Page anchors are now **audio timestamps**, not word counts. A count anchor skips
any words that arrive in the same update as the anchor point, so a new page could
start part-way into a sentence. `showWords([TimedWord])` replaces
`showFullText(String)`, and the fade, the pause and the speaker-change break all
anchor the same way.

**All three managers can do this**, contrary to what I said first — Unified via
`consumeWordTimings()`, Nemotron via `getTokenTimings()`, EOU via
`getTokenTimestampsMs()` + `getRawTokenStrings()`. Unified is the only one giving
word boundaries ready-made; on the others words are reassembled from tokens using
the leading-space convention. One asymmetry that matters for an always-on app:
Unified's accessor *drains*, so the running transcript must be accumulated locally,
while EOU's is a plain getter that returns everything every time.

### Three bugs found doing it

**The overlay flashed during music.** Reported by the user, and the key diagnostic.
The unchanged-text guard only skipped re-showing when alpha was exactly 0; mid-fade
the alpha is between 0 and 1, so the guard missed, `show()` animated back to full,
and the poll faded again — a flash loop several times a second. Worse, `show()`
interrupting the fade meant its completion handler kept seeing a non-zero alpha and
**never cleared the page**, which is why the next speaker appended to text that
should long since have gone. Fixed by returning on unchanged text before touching
visibility at all.

**`build.sh` shipped a stale binary.** The `swift build` output was piped through
`grep … || true`, which masked a failed compile; the script then copied the
*previous* binary into the bundle and signed it. A fix that never compiled was
tested and appeared not to work. `build.sh` now checks the exit status, prints the
errors, and refuses to package. Worth remembering as a class: never let `|| true`
sit on a build step.

**The word-start marker was drawn on screen.** `getRawTokenStrings()` returns
tokens with a literal U+2581 prefix — the C API translated it to a space, the Swift
accessor does not — so subtitles rendered as `▁after ▁early ▁nightfall`. Both forms
are stripped now.

### The missing words were not a paging bug at all

The new page still started several words into the second utterance, and I had
guessed at the anchor arithmetic. Instrumenting it (`SUBS_DEBUG_PAGING=1`, still in
the code) settled it in one run:

```
[page] anchor=12.80 total=61 visible=43 firstVisible=of
```

Paging was correct — it filtered exactly the 18 words of the first utterance and
showed all 43 the engine produced. **The recogniser never transcribed the missing
words.** Its own output ran `…the squalid quarter of the brothels of the sin which
man thus punished…`, skipping "god as a direct consequence" entirely.

Cause: the recogniser had just been fed **12 seconds of tone**. The energy gate
cannot tell music from speech, so the encoder ingests it, and when someone speaks
again the opening words are lost to a context still full of music.

Fix: when the overlay concludes speech has stopped — text went idle, even though
audio is still flowing — the engine's context is dropped (`resetContext()`). The
second utterance now transcribes in full, from "god".

**This is the cheap version of the right fix.** The proper one is a real VAD
(Silero) so non-speech never reaches the recogniser at all, which has been an
outstanding item since Phase 1 and now has a concrete symptom attached to it.

The lesson is the recurring one in this document: I twice guessed at an anchor
arithmetic bug that did not exist. One `err()` line found it immediately.

---

## 17. Silero VAD (2026-08-13)

The energy gate only knows loud from quiet, so a backing track was fed straight to
the recogniser and poisoned its encoder context (§16). Silero VAD now decides what
is speech before anything reaches Parakeet.

### Wired as a parallel gate, never in the delay path

Silero decides on 4096-sample chunks — **256 ms** at 16 kHz. Buffering audio until
a verdict arrives would have added that to *every* subtitle. Instead the verdict
only decides whether to keep feeding: audio is never held up, so 256 ms is decision
*granularity*, not latency. At worst a quarter-second of music slips through, or
the cut lands a quarter-second late.

Gating on a detector can clip word onsets, so the engine keeps its own ~1 s
pre-roll and replays it at each speech onset — the same mechanism that fixed cold
starts in the core. Silero's own hysteresis (`state.triggered`) is used rather than
thresholding a raw probability, so brief dips mid-word do not shred the audio.

### Measured

| | Value |
|---|---|
| Speech detected | **65 %** of gated-on audio |
| Actual speech in the test file | 66 % (23.3 s of 35.3 s) |
| RTF with VAD | 0.10–0.11 |
| RTF without | 0.10 |

It identified the 12 s tone as non-speech almost exactly, and costs about **0.01
RTF** — the "another model must cost something" worry does not materialise, because
Silero is ~200k parameters against Parakeet's 0.6B.

### A measurement bug of my own making ⚠️

The first comparison read **0.13 with VAD against 0.10 without**, and I nearly
reported that the VAD cost 30 % more. It was an artefact: `processedSeconds`
counted only audio that reached the recogniser, while `computeSeconds` included
VAD work on *all* audio. Rejecting 35 % of the stream shrank the denominator and
inflated RTF exactly when the pipeline was doing *less* work. RTF is now measured
against all audio seen.

Worth remembering as a class: when adding a stage that *removes* work, check that
the health metric's denominator did not move with it.

### Consequence

§16's context reset is now belt-and-braces rather than the fix — with music never
reaching the recogniser there is no polluted context to drop. It is kept because it
costs nothing and covers non-speech the VAD lets through.

Off/on from the menu (**Skip Non-Speech (VAD)**), default on. The status line now
reports the speech fraction alongside RTF, so "how much of what I am hearing is
actually speech" is visible.

---

## 18. First-run download, made visible (2026-08-14)

First launch fetches ~613 MB and said only "Loading Nemotron · 560 ms…" for the
several minutes that took — indistinguishable from hung. The default also moved to
**Nemotron 560**, so the bundle a cold cache pulls is the one the app goes on
running rather than an EOU one it never touches.

### Bundling was considered and rejected

`StreamingNemotronAsrManager.loadModels(from:)` loads straight from a directory, so
shipping the model inside the `.app` is possible. It was not taken:

- 613 MB for the 560 ms bundle against a **7.4 MB** app — an 84x increase, and every
  rebuild would re-copy and re-sign it.
- The download path has to exist anyway. Switching variants pulls EOU (1.3 GB),
  Unified (595 MB) or another Nemotron size (~600 MB each).
- The bytes do not disappear, they move from first-run to install-time. What
  bundling actually buys is that first run cannot fail halfway — which is an
  argument for handling that failure, not for a 620 MB app.

### The progress scale is not what it looks like ⚠️

FluidAudio reserves the **top half** of its 0…1 scale for compiling CoreML models
(`downloadPhaseWeight: 0.5`). Our bundles ship precompiled, so that phase never
fires and a fully finished download reports **50% forever**. Each phase is rescaled
locally to fill the bar; the headline says which phase is running, so nothing is
lost by not sharing the range.

Byte-granular progress *within* each file was worth confirming: the encoder alone is
578 MB of the 613 MB, so a file-boundary-only bar would have sat near zero for the
entire meaningful wait.

### Menu items do not update while a menu is open

Three separate causes, all found on screen rather than by reading:

- A menu's contents are frozen while it is displayed. A timer fixes it, but it must
  be registered in **`.eventTracking`** — `.common` alone was silent for exactly as
  long as the menu was up, which is the only time it matters.
- A custom item view needs `displayIfNeeded()`. Marking it dirty defers the redraw
  to a display cycle an open menu is not reliably running, so the values updated
  underneath while the pixels stayed put.
- Finishing with the menu open left the bar parked, since the menu only rebuilds on
  open. The item is swapped for the status line in place — one item, not a
  `rebuild()`, which would tear every item out from under a menu being read.

Two presentation notes. The badge is a **pulsing dot, not an `NSProgressIndicator`**:
at 6pt, matching the health dot, a spinner is an illegible smudge. And it waits
**1.5 s** before appearing, because a cached model loads in about two seconds and
flashed the badge on and straight back off, which reads as a glitch.

### Switching now cancels the pending load

`applyVariant` opened with a guard on the busy flag, so picking a model mid-load did
nothing at all — silently. Removing that guard exposed three things it had been
hiding:

- **Stale callbacks.** A cancelled load kept writing status for a model no longer
  selected. Callbacks now carry the generation they were built with.
- **Concurrent teardown.** Two overlapping switches would run their destroy/create
  pairs at once — precisely the use-after-free §Phase-3 warns about. Core swaps go
  through a serial queue, and a superseded switch bails before touching the core.
- **Leaked engines.** `shutdown()` existed but was never called on a switch, so each
  one stranded the outgoing engine's pump task and its loaded CoreML models.

Cancellation reaches the engine as a *thrown error* — `CancellationError` or
`URLError.cancelled` depending how far in it got — so the catch checks
`Task.isCancelled` first. Without that, every switch flashed "failed to load".

Nothing already fetched is wasted: completed files are kept and skipped as
`.alreadyPresent`, so switching back resumes rather than restarts.

---

## 19. The tap that would not switch (2026-08-14)

Picking a different app in **Listen To** mostly did nothing — you kept hearing
whatever was selected when the app launched. It presented as *flaky* rather than
broken, which is what made it slow to pin down: switching away from an app that
happened to be silent looked like it worked perfectly.

### Nothing on the failure path was wrong ⚠️

Every suspect checked out, which is the point of writing this down:

- `CATapDescription(stereoMixdownOfProcesses:)` sets `exclusive=false` with the
  processes populated — an inclusion list, as intended. Verified directly, since
  the symmetric trap for the *exclude* initializer already cost hours in §8b
  Finding 3.
- Family resolution was correct: `Claude [com.anthropic.claudefordesktop]` resolved
  to its three process objects, distinct from Chrome's two helpers.
- The aggregate device was built with the *new* tap's UUID every time.
- Teardown reported no errors at all.
- No fallback fired, and `menu.currentSource` reads the tap's real source, so the
  checkmark could not drift from reality.

The tap being created was right. A second one was overriding it.

### The bug: startup creates the tap twice

`prepare()` runs at load and `start()` a few lines later. Then
`applyVariant(initial:)`'s async tail lands *after* the run loop starts and calls
`prepare()` + `start()` again. The second pair overwrote `tapID`, `aggID` and
`procID` while the first aggregate and its IOProc were **still running** — now
unreachable by any later `stop()`, and still pumping the original tap's audio into
the same sink. Every subsequent switch tore down only the tracked device.

Hence the dependence on launch source, and hence "unreliable".

`prepare()` and `start()` are idempotent now: `prepare()` tears down whatever is
live before building, `start()` refuses to stack a second aggregate on one tap.

`stop()` also discarded every `OSStatus`, and cleared `procID` whether or not the
IOProc had actually gone — which is precisely how a live IOProc becomes
unreachable. It reports each failure now and only forgets what is genuinely gone.
Teardown was innocent this time; the same silence would have hidden the next one.

### What made it findable

- **Log what actually got tapped** — family, exclusive flag, and every process
  object with its pid and bundle id. A scoping bug is invisible otherwise: the tap
  builds and runs either way, and the only symptom is hearing the wrong app.
- **`SIGUSR2` cycles sources**, the way `SIGUSR1` already cycles variants, so the
  switch path can be exercised without a hand on the menu. The menu and the signal
  share one `selectSource()`, so a test drives the same code the menu does.
- **Test against a silent app.** Two apps both playing cannot distinguish "switched"
  from "did not switch" when both are talking over each other; scoping to something
  guaranteed silent turns the question into "does any word arrive at all".

A false negative to remember: testing this by *launching* scoped to the silent app
passes for the wrong reason. The leaked tap is then also the silent app, and
everything looks correct.

### Switching now clears what was on screen

The overlay was already cleared; the recogniser was not. FluidAudio reports the
whole transcript on every update, so its accumulated words and encoder context
carried across the switch and the new app's first words arrived appended to a
sentence nobody was saying any more. `resetContext()` runs on switch too, and the
terminal line is *discarded* rather than committed — `endpoint()` prints what it
has before clearing, which is right at an utterance boundary and wrong here.

---

## 20. Multilingual (2026-08-14)

`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, exposed as a
single **Multilingual · 560 ms** entry whose submenu is the language picker. This
answers §9's "which languages" question with "whichever you pick" rather than
settling it.

Measured here: **RTF 0.08–0.11 on French**, indistinguishable from Nemotron 560 on
English, and nowhere near the ~0.8 line. Real French transcription, punctuated and
accented, first try. Errors cluster on technical vocabulary ("des canta" for *des
quanta*), consistent with the model card's 9.68 % FLEURS WER for French.

### Two packs, and the menu has to show it

The repo ships two vocabularies and the download follows the language:

| pack | vocab | languages | download |
|---|---|---|---|
| `latin` | 2828 | en · es · fr · it · pt · de | **583 MB** |
| `multilingual` | 13087 | zh · ja (+~40 via `prompt_id`), and `auto` | **633 MB** |

`auto` routes to the full pack — it has to be able to decode anything. So the
worst case is a user trying Auto-detect and then pinning French: two downloads,
1.2 GB, for what feels like one decision.

Always pulling the full pack would avoid that, since its vocab covers the Latin
languages too and `setLanguage` is only a decode hint. **Rejected deliberately**:
the pruned pack is smaller and its joint is faster, and the download UI already
explains itself. The menu instead separates the two groups with a rule, so the
boundary that costs 633 MB is at least visible before it is crossed.

### Language belongs to the model entry, not beside it

A top-level Language menu would allow a state the app cannot honour — French
selected while an English-only model is running — and representing that needs
either a greyed control or a Model list that changes behind your back. Hanging the
languages off the one entry that supports them makes a language *be* a model
choice: one click, one complete request, no invalid states. The parent shows the
active language so it reads without opening the third level.

This is also why only one chunk tier is exposed. Four tiers would repeat the whole
language submenu four times.

**560 ms over the card's recommended 2240 ms.** The card's tier scores marginally
better (English 8.96 % vs 9.43 % WER) for 1.7 s more latency, which is the trade
this project exists to refuse.

### Two claims that turned out to be wrong ⚠️

**"Unified is the only variant that emits punctuation and capitalisation itself"**
— stated in the README and in `isUnified`'s own doc comment, and false. This
session's transcripts settle it: EOU 1280 produced *"blue checks because they pay
me for it the pro tier"*, while Nemotron 560 produced *"Good Lord, what have I
done?"* and *"…the likelihood that the output is better too is much, much
higher."* Punctuation splits **EOU (none) against everything else**, not Unified
against the rest. Every menu note now states its punctuation status, and Unified —
2.08 s of latency with no remaining differentiator — says so.

**FluidAudio's own docs say the model is local-path-only**: *"no HuggingFace repo
yet. Convert it yourself … (Linux + CUDA required)"*. The repo exists and
`downloadVariant` fetches from it happily. Vendored documentation is a snapshot;
the code and the registry were the truth here.

---

## 10. References

- sherpa-onnx — streaming Zipformer transducer models, C API, bundled Silero VAD
- `AudioHardwareCreateProcessTap` / `CATapDescription` — Core Audio process taps, macOS 14.2+
- LocalAgreement-2 — hypothesis commit policy, from the whisper_streaming line of work
- NVIDIA Parakeet TDT v3 — multilingual fallback tier
- Apple `SpeechAnalyzer` / `SpeechTranscriber` — macOS 26+, revisit on upgrade
