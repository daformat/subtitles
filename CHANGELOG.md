# Changelog

Every released version of Subtitles, newest first. Dates are the release commit's.
Versions are the `VERSION` at the top of `build.sh`, which is what the About panel
and the DMG name show.

## 1.3.0 · 2026-08-31

**Live translation, on device.** Captions can now be translated as they are spoken,
into any of the sixteen languages the picker already offers. It runs through Apple's
Translation framework, so nothing leaves the machine and the app keeps the property
it was built around.

- Every ordered pair works, not just the ones involving English. That is what ruled
  out doing this in the recogniser: NVIDIA's canary checkpoint translates speech
  directly, but only to or from English, and half this app's languages are not in its
  set at all. Apple's covers all 240 pairs of the sixteen.
- Two timings, because the interesting cost is not compute. Translating a sentence
  takes 40 to 125 ms here, so the only real question is what to show while a sentence
  is still being spoken. *Live, Then Settle* translates the last second of speech on
  every update and dims it until it settles. *Always Live* retranslates everything
  each update: no lag, and anything on screen may still change.
- Whole clauses are translated, never the box. The overlay breaks pages wherever the
  text happens to overflow, which is routinely mid-sentence, and a fragment translated
  alone loses the case, the gender agreement, or the verb it had not reached yet.
  Translation units and display units are now separate things.
- Boxes overlap by a clause when translating. A page that fills up restarts at the
  last clause it showed rather than at the word that spilled, so there is something
  to re-anchor on when the box turns over instead of a hard cut. Only from a box
  that turned over quickly: one that sat there long enough to be read already gave
  you that time.
- On auto-detect the source language comes from the recogniser's own language tag
  rather than from asking the translator to guess per sentence. It is known within a
  word or two of speech.
- Hold `⌃` to see the original language, live box and `⌥` stack together, for as
  long as the key is down. Translation carries on underneath, so letting go shows
  current text rather than a snapshot. Each language keeps its own page memory, so
  the stack never mixes the two, and a stacked box holds only what it added rather
  than repeating the clause carried into the box below it.
- Translation needs macOS 15. The rest of the app still runs on 14.2, where the menu
  simply does not appear.

**A ghost mode for screen sharing.** "Show Overlay In Screen Share / Capture", on by
default, and unchecking it takes the overlay out of anything capturing through macOS:
calls, recordings, screenshots alike. The `⌥` history stack goes with it. It is not
a promise against a camera pointed at the screen.

**Interrupted model downloads repair themselves.** A download that stopped partway
left a compiled bundle that CoreML refuses, and nothing ever retried it: the model
failed to load on every launch from then on, with no transcript and nothing on screen
to say why. Those bundles are now detected and refetched, and only the broken ones, so
a variant whose encoder alone is truncated costs one encoder rather than 600 MB.

- A recogniser that cannot load says so in the menu, in red, instead of leaving
  "listening" or "no audio" on screen. Both were wrong, and both pointed away from the
  cause.
- `--list-models` reports incomplete bundles too, which is the one way to ask what is
  on disk without starting anything.

## 1.2.0 · 2026-08-30

**Sixteen languages in the picker, up from eight.** The multilingual checkpoint is
`nvidia/nemotron-3.5-asr-streaming-0.6b`, by way of FluidInference's CoreML
conversion, and it reaches 40 language-locales. The menu listed eight of them. It now
carries NVIDIA's transcription-ready tier: Dutch, Turkish, Russian, Arabic, Hindi,
Korean, Vietnamese and Ukrainian join English, Spanish, French, Italian, Portuguese,
German, Mandarin and Japanese.

- The eight new entries need no download. They live in the full-vocabulary pack that
  auto-detect already fetches, so for anyone on the default they cost nothing, and
  moving between them is instant.
- What this adds is pinning rather than reach. Auto-detect already decoded these and
  tagged them itself. Telling the model the language is the more accurate setting
  when the audio is one language: upstream measures Hindi at 7.05 WER told against
  9.26 detected, at the 560 ms tier this app runs.
- Script is not the split between the two packs. Dutch, Turkish and Vietnamese are
  Latin-script and still take the 633 MB one, because the pruned vocabulary was built
  for six named languages and covers nothing past them.
- Every surface now counts languages the same way: `auto` is a detection mode over
  the languages, not one of them.

## 1.1.4 · 2026-08-22

**A settings window with a live preview of the overlay.** The UI pane opens onto a
small screen of its own, because half of what that pane governs describes something
not currently on screen: boxes that have already finished, a hole that follows a
pointer busy holding a slider.

- The preview instantiates the overlay's own views and scales them through a bounds
  transform rather than by shrinking a font, so every proportion comes down together.
  Its captions are scripted: the live transcript is empty exactly when the window is
  open.
- Touch a control and the preview says what that control does, with its current value
  in the sentence. The Recent Boxes controls raise the stack the way ⌥ does, and ⌥
  itself works in there too.
- Windows that do not fit the screen scroll rather than running off the bottom of it,
  where there is no title bar to drag them back by. Settings keeps its header put;
  Welcome re-fits as the demo reports its height and as displays change.
- The welcome demo's web view had been swallowing every wheel event whether or not its
  page had anywhere to scroll. It now hands the event to the window, unless ⌥ is down.
- The overlay follows a resolution change instead of waiting for the next word to
  notice one.

## 1.1.3 · 2026-08-20

- Re-vendored the caption demo from the site, mostly the ⌥ stack learning not to fight
  the caption history's own scroll container.
- Fixed the vendor script's guards, which all looked at the start of each slice, so a
  section that had grown a new tail satisfied every one of them and vendored a demo
  with its newest half missing, silently. Each range is now checked at the line it
  stops on too.
- The welcome screen says what the pointer does before what the modifiers do, and every
  line of that block is a keycap tall whether or not it holds a key.

## 1.1.2 · 2026-08-19

- Re-vendored the site's caption demo: the ⌘-tab switcher, the scrolling caption
  history and the ⌥ stack it had grown since 1.1.0.
- The welcome screen says what the two modifiers do and what the pointer does, one line
  each. `KeycapView` watches the modifier it draws rather than always ⇧, so the ⌥ cap
  lights up for ⌥.

## 1.1.1 · 2026-08-19

**The ⌥ stack forgets after a spell of silence.** It had been answering with whatever
was last said, however long ago: press it after lunch and the stack was still the
morning's meeting. It now clears after 30 seconds with no new text, configurable, and
switchable off.

Measured from the last text rather than the last audio: a backing track holds the voice
gate open indefinitely, so "is the room quiet" is the wrong question. It will not fire
while the stack is on screen, since somebody holding ⌥ is reading it.

## 1.1.0 · 2026-08-19

**Hold ⌥ to bring back the last few boxes, and a settings window to tune them.** The
overlay pages like broadcast subtitles. It fills, clears, starts again, so a sentence
you glanced away from was simply gone. The last few closed pages now stack above the
live box, scrollable when the stack is taller than the room above it.

A second panel rather than a taller live one: the live pill carries the cursor reveal,
the ⇧ drag ring and the hugging resize, all written against there being exactly one
box. Pill geometry moved to `Pill.swift` so the two cannot drift.

## 1.0.3 · 2026-08-17

- Point at the subtitle box and it dissolves around the cursor, so whatever it covers
  can be read without moving it. Hold ⇧ and it goes solid again, which is also when it
  becomes grabbable.
- Re-vendored the welcome demo from the site, bringing its I18N with it.

## 1.0.2 · 2026-08-16

- A welcome screen for first launch, which downloads ~600 MB before a single caption
  can appear. Until now the app's entire first impression was a menu bar icon with a
  dot on it.
- An About window of its own, after a first pass at AppKit's standard panel.

## 1.0.1 · 2026-08-16

- A dashed ring while ⇧ makes the overlay draggable, so it is visible that the box is
  catching clicks rather than passing them through.
- The readme points at the website, since the packaged app carries the Developer ID
  identity that keeps the audio permission across updates.
- Fixed the DMG layout script running a word inside an AppleScript comment: the heredoc
  is unquoted, and the comment held backticks.

## 1.0 · 2026-08-15

First paid release. Live on-device subtitles for macOS system audio: a Core Audio
process tap into a lock-free ring, transcribed by streaming Parakeet/Nemotron on the
Apple Neural Engine through FluidAudio, rendered as a click-through overlay.

What went into it, in the order it happened:

- **The engine.** sherpa-onnx and a streaming Zipformer first, then Parakeet on the
  ANE via CoreML, unusable on CPU at RTF 10.7–31.8 and fine on the Neural Engine. sherpa
  came out again once FluidAudio was the only engine worth keeping. Punctuation and
  capitalisation come from the model rather than a casing pass.
- **Silero VAD**, so music never reaches the recogniser. An energy gate only knows loud
  from quiet, so a backing track was poisoning the encoder's context and losing the
  first words after every musical passage.
- **The overlay.** Pages anchored on audio time rather than word counts, a fade driven
  by text inactivity rather than audio silence, ⇧ to drag, and a position that survives
  the next word arriving.
- **Model switching from the menu bar**, with on-demand download, visible progress, and
  a switch that can cancel the load already running. The picker leads with language and
  is grouped by the download each choice triggers, sized in megabytes rather than
  parameter counts. Multilingual on auto-detect is the default, because a default
  should work before it is configured.
- **Per-app capture** that actually switches, after a leaked tap made "Listen To" look
  flaky rather than broken.
- **A menu bar badge that says something true**, and an audio permission the app tests
  empirically rather than infers: a denial is silent and looks exactly like quiet.
- **Developer ID signing, notarization and a DMG pipeline.** Ad-hoc signing gave every
  build a fresh cdhash, which is how macOS identifies an ad-hoc app, so TCC threw the
  audio grant away on every rebuild.
- **FSL-1.1-ALv2**, replacing 0BSD once the plan was to charge for the binary.
