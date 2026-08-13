# Spike 0 — throwaway probes

Both probes passed. Results and their consequences are written up in
[`../PLAN.md`](../PLAN.md) §8a (ASR latency) and §8b (audio capture).

This code exists to produce numbers, not to be built on. Phase 1 starts fresh.

## 0B — audio capture (`tap/`)

```bash
cd tap
swiftc -O tap_probe.swift -o tap_probe -framework CoreAudio -framework AudioToolbox
cp tap_probe TapProbe.app/Contents/MacOS/tap_probe
codesign --force --sign - --identifier dev.mat.subtitles.tapprobe TapProbe.app
open -W --stdout "$PWD/out.log" --stderr "$PWD/out.log" TapProbe.app
```

**It must be launched with `open`.** Running the binary directly makes the terminal the
TCC-responsible process, and the tap then delivers perfectly-timed all-zero buffers with
no error anywhere. See PLAN §8b Finding 2.

- `tap_probe.swift` — RMS/peak meter over a global system-audio tap
- `diag.swift` — interrogates tap UID, stream format, aggregate tap list, IO state
- `diag2.swift` — CATapDescription variant matrix; also enumerates audio processes,
  which is the Phase 3 per-app source picker in embryo

## 0A — ASR latency (`latency/`)

Needs the sherpa-onnx prebuilt libs and at least one model. Neither is committed
(~20 MB + 128–400 MB each).

```bash
cd latency
curl -L -o sherpa-lib.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-osx-arm64-static-no-tts-lib.tar.bz2
tar xjf sherpa-lib.tar.bz2
curl -L -o c-api.h \
  https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.5/sherpa-onnx/c-api/c-api.h
curl -L -o model.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2
tar xjf model.tar.bz2

LIB=sherpa-onnx-v1.13.5-osx-arm64-static-no-tts-lib/lib
clang -O2 -o harness harness.c -I. \
  $LIB/libsherpa-onnx-c-api.a $LIB/libsherpa-onnx-core.a \
  $LIB/libkaldi-native-fbank-core.a $LIB/libkaldi-decoder-core.a \
  $LIB/libsherpa-onnx-kaldifst-core.a $LIB/libsherpa-onnx-fst.a \
  $LIB/libsherpa-onnx-fstfar.a $LIB/libssentencepiece_core.a \
  $LIB/libkissfft-float.a $LIB/libonnxruntime.a \
  -lc++ -framework Foundation -framework CoreML -framework Accelerate
```

Run (audio is fed at real-time pace, so a 23 s clip takes 23 s):

```bash
M=sherpa-onnx-streaming-zipformer-en-2023-06-26
./harness $M path/to/a.wav path/to/b.wav --threads 2 --ref "REFERENCE TRANSCRIPT"
```

Flags: `--int8`, `--provider cpu|coreml`, `--threads N`, `--ref TEXT`,
`--fast` (skip real-time pacing — a control to prove pacing isn't corrupting input),
`DUMP_TOKENS=1` (dump raw tokens with byte values).

Input must be **16-bit PCM WAV**. Any sample rate is accepted and multi-channel is
downmixed, but the models expect 16 kHz.

### Reading the output

- **first-emit** — when a word first appears. What the user perceives as speed.
- **committed** — when it stops changing under LocalAgreement-2.
- Both are measured against the **end** of the spoken word (next token's start time).
  Latency from word *start* is ~180 ms higher; most published benchmarks quote that
  number, so don't compare the two directly.
- **RTF** — decode CPU ÷ audio duration. Above 1.0 the pipeline can never catch up.

### Measure on an idle machine *and* a loaded one

p95 ranged from 489 ms idle to 1816 ms under contention on identical input. WER did not
move at all. Quoting the idle number alone is misleading — the product runs during video
calls. See PLAN §8a Finding 2.

### Don't test with `say`

macOS TTS scored 96.8 % WER against 17.1 % on real speech with the same model. Synthetic
audio is not valid ASR test signal. Use real recordings with reference transcripts.
