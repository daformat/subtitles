// Spike 0A — streaming ASR latency + quality harness.
//
// Feeds a WAV into a sherpa-onnx streaming recognizer at REAL-TIME PACE and
// measures how long after a word is spoken it actually appears.
//
// Two latencies are reported, because they answer different questions:
//
//   first-emit  — when the word first appears on screen at all. It may still
//                 change afterwards. This is what the user perceives as speed.
//   commit      — when the word stops changing, under LocalAgreement-2 (a token
//                 is committed once two consecutive hypotheses agree on it).
//                 This is what the user perceives as *settled* text.
//
// Both are measured relative to the END of the spoken word (approximated by the
// next token's start time), not its start — you cannot emit a word before it has
// finished being said, so lag-after-end is the honest "how far behind the audio
// am I" number. Latency from word start is also printed for reference.
//
// Usage: harness <model_dir> <wav>... [--int8] [--provider cpu|coreml] [--threads N]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>
#include <dirent.h>
#include "c-api.h"

#define CHUNK_MS 20
#define MAX_SAMPLES (16000 * 60 * 10)
#define MAX_EVENTS 20000

// ── monotonic clock ──
static double now_sec(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void sleep_until(double target) {
  double d = target - now_sec();
  if (d <= 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)d;
  ts.tv_nsec = (long)((d - ts.tv_sec) * 1e9);
  nanosleep(&ts, NULL);
}

// ── minimal 16-bit PCM mono WAV reader ──
static int read_wav(const char *path, float *out, int max, int *sample_rate) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); return -1; }
  char riff[12];
  if (fread(riff, 1, 12, f) != 12 || memcmp(riff, "RIFF", 4) || memcmp(riff + 8, "WAVE", 4)) {
    fprintf(stderr, "%s: not a RIFF/WAVE file\n", path); fclose(f); return -1;
  }
  int16_t bits = 0, channels = 0;
  int32_t rate = 0;
  int n = 0;
  for (;;) {
    char id[4]; uint32_t sz;
    if (fread(id, 1, 4, f) != 4 || fread(&sz, 4, 1, f) != 1) break;
    if (!memcmp(id, "fmt ", 4)) {
      int16_t fmt;
      fread(&fmt, 2, 1, f); fread(&channels, 2, 1, f); fread(&rate, 4, 1, f);
      fseek(f, 6, SEEK_CUR);            // byte rate + block align
      fread(&bits, 2, 1, f);
      if (sz > 16) fseek(f, sz - 16, SEEK_CUR);
    } else if (!memcmp(id, "data", 4)) {
      if (bits != 16) { fprintf(stderr, "%s: need 16-bit PCM, got %d\n", path, bits); fclose(f); return -1; }
      uint32_t frames = sz / 2 / (channels ? channels : 1);
      for (uint32_t i = 0; i < frames && n < max; i++) {
        int32_t acc = 0;
        for (int c = 0; c < channels; c++) { int16_t s; fread(&s, 2, 1, f); acc += s; }
        out[n++] = (float)acc / channels / 32768.0f;   // downmix to mono
      }
      break;
    } else {
      fseek(f, (sz + 1) & ~1u, SEEK_CUR);
    }
  }
  fclose(f);
  *sample_rate = rate;
  return n;
}

// ── stats ──
static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}
static double pct(double *v, int n, double p) {
  if (n == 0) return NAN;
  int i = (int)(p / 100.0 * (n - 1) + 0.5);
  if (i < 0) i = 0; if (i >= n) i = n - 1;
  return v[i];
}

// ── word tracking ──
// tokens.txt marks word starts with U+2581 ("▁"), but the C API hands them back
// translated to a plain ASCII space. Accept either.
static int is_word_start(const char *tok) {
  if (tok[0] == ' ') return 1;
  return (unsigned char)tok[0] == 0xE2 && (unsigned char)tok[1] == 0x96
      && (unsigned char)tok[2] == 0x81;
}

typedef struct {
  double first_emit;    // wall time (rel. t0) when token first appeared
  double committed;     // wall time when it entered the agreed prefix (-1 = never)
  double audio_ts;      // token start time in the audio
  int    word_start;
  char   text[64];
} TokenEvent;

// ── locate a model file by prefix, honouring the int8 preference ──
static int find_model(const char *dir, const char *prefix, int want_int8,
                      char *out, size_t outsz) {
  DIR *d = opendir(dir);
  if (!d) return 0;
  char best[512] = "";
  struct dirent *e;
  while ((e = readdir(d))) {
    const char *n = e->d_name;
    size_t ln = strlen(n);
    if (strncmp(n, prefix, strlen(prefix))) continue;
    if (ln < 5 || strcmp(n + ln - 5, ".onnx")) continue;
    int is_int8 = (ln > 10 && !strcmp(n + ln - 10, ".int8.onnx"));
    if (want_int8 != is_int8) continue;
    if (!best[0]) snprintf(best, sizeof best, "%s", n);
  }
  closedir(d);
  if (!best[0]) return 0;
  snprintf(out, outsz, "%s/%s", dir, best);
  return 1;
}

// ── word error rate (Levenshtein over words) ──
static int split_words(char *buf, char **w, int max) {
  int n = 0;
  for (char *t = strtok(buf, " \t\n"); t && n < max; t = strtok(NULL, " \t\n")) w[n++] = t;
  return n;
}
static void wer(const char *hyp_s, const char *ref_s) {
  static char hb[8192], rb[8192];
  static char *h[2048], *r[2048];
  snprintf(hb, sizeof hb, "%s", hyp_s);
  snprintf(rb, sizeof rb, "%s", ref_s);
  int nh = split_words(hb, h, 2048), nr = split_words(rb, r, 2048);
  static int d[2049][2049];
  for (int i = 0; i <= nr; i++) d[i][0] = i;
  for (int j = 0; j <= nh; j++) d[0][j] = j;
  for (int i = 1; i <= nr; i++)
    for (int j = 1; j <= nh; j++) {
      int c = strcmp(r[i-1], h[j-1]) ? 1 : 0;
      int a = d[i-1][j] + 1, b = d[i][j-1] + 1, e = d[i-1][j-1] + c;
      int m = a < b ? a : b; d[i][j] = m < e ? m : e;
    }
  printf("\n── accuracy ────────────────────────────────────\n");
  printf("  ref words: %d   hyp words: %d   edits: %d   WER: %.1f%%\n",
         nr, nh, d[nr][nh], 100.0 * d[nr][nh] / (nr ? nr : 1));
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <model_dir> <wav>... [--int8] [--provider P] [--threads N]\n", argv[0]);
    return 1;
  }
  const char *model_dir = argv[1];
  const char *provider = "cpu";
  int threads = 2, use_int8 = 0, no_pacing = 0, debug = 0;
  const char *model_type = NULL;
  int feat_dim = 80;
  const char *wavs[16]; int n_wavs = 0;
  const char *ref = NULL;

  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--fast")) no_pacing = 1;
    else if (!strcmp(argv[i], "--debug")) debug = 1;
    else if (!strcmp(argv[i], "--model-type") && i + 1 < argc) model_type = argv[++i];
    else if (!strcmp(argv[i], "--feat-dim") && i + 1 < argc) feat_dim = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--int8")) use_int8 = 1;
    else if (!strcmp(argv[i], "--provider") && i + 1 < argc) provider = argv[++i];
    else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--ref") && i + 1 < argc) ref = argv[++i];
    else if (n_wavs < 16) wavs[n_wavs++] = argv[i];
  }

  // ── load + concatenate audio ──
  static float samples[MAX_SAMPLES];
  int total = 0, rate = 0;
  for (int i = 0; i < n_wavs; i++) {
    int r = 0;
    int n = read_wav(wavs[i], samples + total, MAX_SAMPLES - total, &r);
    if (n < 0) return 1;
    if (rate && r != rate) { fprintf(stderr, "sample-rate mismatch: %d vs %d\n", r, rate); return 1; }
    rate = r; total += n;
    fprintf(stderr, "loaded %-40s %6.2fs @ %dHz\n", wavs[i], (double)n / r, r);
  }
  double audio_dur = (double)total / rate;
  fprintf(stderr, "total audio: %.2fs @ %dHz\n\n", audio_dur, rate);

  // ── build recognizer ──
  char enc[512], dec[512], joi[512], tok[512];
  // Model filenames vary between releases (e.g. "-chunk-16-left-128" suffixes),
  // so locate encoder/decoder/joiner by prefix rather than hardcoding.
  // Prefer the requested precision, but fall back: some releases (e.g. the
  // streaming Parakeet models) ship int8 weights only.
  if (!find_model(model_dir, "encoder", use_int8, enc, sizeof enc) &&
      !find_model(model_dir, "encoder", !use_int8, enc, sizeof enc)) { enc[0] = 0; }
  if (!find_model(model_dir, "decoder", 0, dec, sizeof dec) &&
      !find_model(model_dir, "decoder", 1, dec, sizeof dec)) { dec[0] = 0; }
  if (!find_model(model_dir, "joiner", use_int8, joi, sizeof joi) &&
      !find_model(model_dir, "joiner", !use_int8, joi, sizeof joi)) { joi[0] = 0; }
  if (!enc[0] || !dec[0] || !joi[0]) {
    fprintf(stderr, "could not locate encoder/decoder/joiner in %s\n", model_dir);
    return 1;
  }
  snprintf(tok, sizeof tok, "%s/tokens.txt", model_dir);
  fprintf(stderr, "  encoder: %s\n  decoder: %s\n  joiner : %s\n",
          strrchr(enc,'/')+1, strrchr(dec,'/')+1, strrchr(joi,'/')+1);

  SherpaOnnxOnlineRecognizerConfig cfg;
  memset(&cfg, 0, sizeof cfg);
  cfg.feat_config.sample_rate = 16000;
  cfg.feat_config.feature_dim = feat_dim;
  cfg.model_config.transducer.encoder = enc;
  cfg.model_config.transducer.decoder = dec;
  cfg.model_config.transducer.joiner  = joi;
  cfg.model_config.tokens = tok;
  cfg.model_config.num_threads = threads;
  cfg.model_config.provider = provider;
  cfg.model_config.debug = debug;
  cfg.model_config.model_type = model_type;
  cfg.decoding_method = "greedy_search";
  cfg.max_active_paths = 4;
  cfg.enable_endpoint = 0;             // no endpointing: we want a continuous stream

  fprintf(stderr, "model: %s  int8=%d provider=%s threads=%d\n", model_dir, use_int8, provider, threads);
  double load_t0 = now_sec();
  const SherpaOnnxOnlineRecognizer *rec = SherpaOnnxCreateOnlineRecognizer(&cfg);
  if (!rec) { fprintf(stderr, "failed to create recognizer\n"); return 1; }
  fprintf(stderr, "model load: %.2fs\n", now_sec() - load_t0);
  const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(rec);

  // ── stream at real-time pace ──
  static TokenEvent ev[MAX_EVENTS];
  int n_ev = 0, committed_len = 0;
  static char prev_tok[MAX_EVENTS][64];
  int prev_count = 0;
  double decode_cpu = 0;

  int chunk = rate * CHUNK_MS / 1000;
  double t0 = now_sec();

  for (int off = 0; off < total; off += chunk) {
    int n = (off + chunk <= total) ? chunk : (total - off);
    double audio_end = (double)(off + n) / rate;
    if (!no_pacing) sleep_until(t0 + audio_end);        // real-time pacing

    SherpaOnnxOnlineStreamAcceptWaveform(stream, rate, samples + off, n);

    double d0 = now_sec();
    while (SherpaOnnxIsOnlineStreamReady(rec, stream)) SherpaOnnxDecodeOnlineStream(rec, stream);
    decode_cpu += now_sec() - d0;

    const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(rec, stream);
    double emit = now_sec() - t0;

    if (r && r->count > 0 && r->tokens_arr) {
      // longest prefix agreeing with the previous hypothesis → LocalAgreement-2
      int agreed = 0;
      int lim = r->count < prev_count ? r->count : prev_count;
      while (agreed < lim && !strcmp(r->tokens_arr[agreed], prev_tok[agreed])) agreed++;

      for (int i = 0; i < r->count && i < MAX_EVENTS; i++) {
        if (i >= n_ev) {                                // token seen for the first time
          ev[i].first_emit = emit;
          ev[i].committed  = -1;
          ev[i].audio_ts   = r->timestamps ? r->timestamps[i] : 0;
          ev[i].word_start = is_word_start(r->tokens_arr[i]);
          snprintf(ev[i].text, sizeof ev[i].text, "%s", r->tokens_arr[i]);
          n_ev = i + 1;
        }
      }
      for (int i = committed_len; i < agreed && i < MAX_EVENTS; i++) {
        if (ev[i].committed < 0) {
          ev[i].committed = emit;
          ev[i].audio_ts  = r->timestamps ? r->timestamps[i] : ev[i].audio_ts;
        }
      }
      if (agreed > committed_len) committed_len = agreed;

      for (int i = 0; i < r->count && i < MAX_EVENTS; i++)
        snprintf(prev_tok[i], sizeof prev_tok[i], "%s", r->tokens_arr[i]);
      prev_count = r->count;
    }
    if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
  }

  // ── drain ──
  // Streaming zipformer has right-context lookahead: without trailing silence
  // the final word never flushes (observed as a truncated last token).
  static float tail[16000 / 2];
  memset(tail, 0, sizeof tail);
  SherpaOnnxOnlineStreamAcceptWaveform(stream, rate, tail, (int)(sizeof tail / sizeof *tail));
  SherpaOnnxOnlineStreamInputFinished(stream);
  double d0 = now_sec();
  while (SherpaOnnxIsOnlineStreamReady(rec, stream)) SherpaOnnxDecodeOnlineStream(rec, stream);
  decode_cpu += now_sec() - d0;
  double drain_end = now_sec() - t0;

  const SherpaOnnxOnlineRecognizerResult *final = SherpaOnnxGetOnlineStreamResult(rec, stream);
  for (int i = committed_len; final && i < final->count && i < MAX_EVENTS; i++)
    if (ev[i].committed < 0) ev[i].committed = drain_end;

  printf("\n── transcript ──────────────────────────────────\n%s\n",
         final && final->text ? final->text : "(empty)");

  if (getenv("DUMP_TOKENS") && final) {
    printf("\n── token dump (first 12 of %d) ──\n", final->count);
    printf("  tokens_arr = %p, timestamps = %p\n",
           (void *)final->tokens_arr, (void *)final->timestamps);
    for (int i = 0; i < final->count && i < 12; i++) {
      const char *t = final->tokens_arr ? final->tokens_arr[i] : "(null arr)";
      printf("  [%2d] ts=%6.2f  \"%s\"  bytes:", i,
             final->timestamps ? final->timestamps[i] : -1, t);
      for (const unsigned char *p = (const unsigned char *)t; *p; p++) printf(" %02x", *p);
      printf("  word_start=%d\n", is_word_start(t));
    }
  }

  // ── latency stats (word-level) ──
  // Word end is approximated by the next token's start time.
  static double f_end[MAX_EVENTS], c_end[MAX_EVENTS], f_start[MAX_EVENTS];
  int nf = 0, nc = 0, nfs = 0;
  for (int i = 0; i < n_ev; i++) {
    if (!ev[i].word_start) continue;
    double word_end = (i + 1 < n_ev) ? ev[i + 1].audio_ts : ev[i].audio_ts;
    f_start[nfs++] = ev[i].first_emit - ev[i].audio_ts;
    if (ev[i].first_emit >= 0) f_end[nf++] = ev[i].first_emit - word_end;
    if (ev[i].committed  >= 0) c_end[nc++] = ev[i].committed  - word_end;
  }
  qsort(f_end, nf, sizeof(double), cmp_double);
  qsort(c_end, nc, sizeof(double), cmp_double);
  qsort(f_start, nfs, sizeof(double), cmp_double);

  printf("\n── latency (%d words) ──────────────────────────\n", nf);
  printf("                        p50       p95       max\n");
  printf("  first-emit (vs end) %6.0fms  %6.0fms  %6.0fms\n",
         pct(f_end, nf, 50) * 1000, pct(f_end, nf, 95) * 1000, pct(f_end, nf, 100) * 1000);
  printf("  committed  (vs end) %6.0fms  %6.0fms  %6.0fms\n",
         pct(c_end, nc, 50) * 1000, pct(c_end, nc, 95) * 1000, pct(c_end, nc, 100) * 1000);
  printf("  first-emit (vs start of word, for reference) p50 %.0fms\n",
         pct(f_start, nfs, 50) * 1000);

  {
    static double delta[MAX_EVENTS]; int nd = 0;
    double worst = 0;
    for (int i = 0; i < n_ev; i++)
      if (ev[i].word_start && ev[i].committed >= 0 && ev[i].first_emit >= 0) {
        double dd = ev[i].committed - ev[i].first_emit;
        delta[nd++] = dd;
        if (dd > worst) worst = dd;
      }
    qsort(delta, nd, sizeof(double), cmp_double);
    printf("\n── stabilisation cost (LocalAgreement-2) ───────\n");
    printf("  commit delay after first emit: p50 %.0fms  p95 %.0fms  max %.0fms\n",
           pct(delta, nd, 50) * 1000, pct(delta, nd, 95) * 1000, worst * 1000);
    int revised = 0;
    for (int i = 0; i < nd; i++) if (delta[i] > 0.001) revised++;
    printf("  words whose commit lagged first emit at all: %d / %d\n", revised, nd);
  }
  if (ref && final && final->text) wer(final->text, ref);

  printf("\n── compute ─────────────────────────────────────\n");
  printf("  decode CPU: %.2fs over %.2fs audio  →  RTF %.3f  (headroom %.1fx)\n",
         decode_cpu, audio_dur, decode_cpu / audio_dur, audio_dur / decode_cpu);

  if (final) SherpaOnnxDestroyOnlineRecognizerResult(final);
  SherpaOnnxDestroyOnlineStream(stream);
  SherpaOnnxDestroyOnlineRecognizer(rec);
  return 0;
}
