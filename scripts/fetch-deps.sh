#!/bin/bash
# Downloads the two things this repo deliberately does not version: the
# sherpa-onnx prebuilt libraries (~83 MB) and the ASR model (~320 MB).
#
# Both are large, immutable, and re-downloadable from pinned release URLs, so
# committing them would bloat every clone for no benefit. Versions and SHA-256
# digests are pinned here — a silently different model would change transcription
# quality with nothing in the diff to explain it.
#
# Idempotent: skips anything already present and verified.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

SHERPA_VERSION="v1.13.5"
SHERPA_LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}-osx-arm64-static-no-tts-lib.tar.bz2"
SHERPA_LIB_SHA="72379b807bb0c72eb4f56423d768eb3117dc0fbf1133fba780ee56c00b8263a8"

SHERPA_HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_VERSION}/sherpa-onnx/c-api/c-api.h"
SHERPA_HEADER_SHA="bf9843c81b3d533bd7ca9f0f7db666b267bbade4ec41a8399c52156f2018327b"

MODEL_NAME="sherpa-onnx-streaming-zipformer-en-2023-06-26"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
MODEL_SHA="639e25b578e9e997131402199419c13a941f8e4e198e2da1ce57dbf5cf401282"

TMP="$ROOT/.fetch-tmp"
mkdir -p "$TMP" "$ROOT/third_party/sherpa-onnx/lib" "$ROOT/third_party/sherpa-onnx/include" "$ROOT/models"

verify() {   # file expected_sha label
  local actual
  actual=$(shasum -a 256 "$1" | awk '{print $1}')
  if [ "$actual" != "$2" ]; then
    echo "!! $3 checksum mismatch" >&2
    echo "   expected $2" >&2
    echo "   actual   $actual" >&2
    exit 1
  fi
}

# ── sherpa-onnx static libraries ──
if [ -f "$ROOT/third_party/sherpa-onnx/lib/libsherpa-onnx-c-api.a" ]; then
  echo "✓ sherpa-onnx libraries already present"
else
  echo "→ sherpa-onnx ${SHERPA_VERSION} libraries (~19 MB compressed)"
  curl -fL --progress-bar -o "$TMP/sherpa-lib.tar.bz2" "$SHERPA_LIB_URL"
  verify "$TMP/sherpa-lib.tar.bz2" "$SHERPA_LIB_SHA" "sherpa-onnx libraries"
  tar xjf "$TMP/sherpa-lib.tar.bz2" -C "$TMP"
  cp "$TMP"/sherpa-onnx-*/lib/*.a "$ROOT/third_party/sherpa-onnx/lib/"
  echo "✓ sherpa-onnx libraries"
fi

# ── c-api.h (bindgen reads this) ──
if [ -f "$ROOT/third_party/sherpa-onnx/include/c-api.h" ]; then
  echo "✓ c-api.h already present"
else
  echo "→ sherpa-onnx c-api.h"
  curl -fL -o "$TMP/c-api.h" "$SHERPA_HEADER_URL"
  verify "$TMP/c-api.h" "$SHERPA_HEADER_SHA" "c-api.h"
  cp "$TMP/c-api.h" "$ROOT/third_party/sherpa-onnx/include/c-api.h"
  echo "✓ c-api.h"
fi

# ── ASR model ──
if [ -d "$ROOT/models/$MODEL_NAME" ]; then
  echo "✓ model already present ($MODEL_NAME)"
else
  echo "→ $MODEL_NAME (~310 MB) — this is the slow one"
  curl -fL --progress-bar -o "$TMP/model.tar.bz2" "$MODEL_URL"
  verify "$TMP/model.tar.bz2" "$MODEL_SHA" "model"
  tar xjf "$TMP/model.tar.bz2" -C "$ROOT/models"
  echo "✓ model"
fi

rm -rf "$TMP"
echo
echo "dependencies ready — now run ./build.sh"
