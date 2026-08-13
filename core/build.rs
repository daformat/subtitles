// Generates Rust bindings for the sherpa-onnx C API.
//
// PLAN.md D4 called for bindgen over hand-written externs. Spike 0A sidestepped
// the question by writing the harness in C; this is where that decision gets
// validated for real.

use std::env;
use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .join("third_party/sherpa-onnx");
    let include = root.join("include");
    let lib = root.join("lib");

    println!("cargo:rerun-if-changed={}", include.join("c-api.h").display());
    println!("cargo:rerun-if-changed=build.rs");

    // Emitted for `cargo test`; the app's real link line lives in build.sh,
    // because a staticlib crate does not bundle its C dependencies.
    println!("cargo:rustc-link-search=native={}", lib.display());
    for l in [
        "sherpa-onnx-c-api",
        "sherpa-onnx-core",
        "kaldi-native-fbank-core",
        "kaldi-decoder-core",
        "sherpa-onnx-kaldifst-core",
        "sherpa-onnx-fst",
        "sherpa-onnx-fstfar",
        "ssentencepiece_core",
        "kissfft-float",
        "onnxruntime",
    ] {
        println!("cargo:rustc-link-lib=static={l}");
    }
    println!("cargo:rustc-link-lib=c++");
    // onnxruntime's Apple log sink is Objective-C++ and references NSLog /
    // __CFConstantStringClassReference.
    for fw in ["Foundation", "CoreML", "Accelerate"] {
        println!("cargo:rustc-link-lib=framework={fw}");
    }

    let bindings = bindgen::Builder::default()
        .header(include.join("c-api.h").to_string_lossy())
        .clang_arg(format!("-I{}", include.display()))
        // Only the streaming (online) ASR surface — the header is ~4700 lines and
        // most of it is TTS, speaker ID, punctuation, etc.
        .allowlist_type("SherpaOnnxOnline.*")
        .allowlist_type("SherpaOnnxFeatureConfig")
        .allowlist_function("SherpaOnnxCreateOnlineRecognizer")
        .allowlist_function("SherpaOnnxDestroyOnlineRecognizer")
        .allowlist_function("SherpaOnnxCreateOnlineStream")
        .allowlist_function("SherpaOnnxDestroyOnlineStream")
        .allowlist_function("SherpaOnnxOnlineStreamAcceptWaveform")
        .allowlist_function("SherpaOnnxIsOnlineStreamReady")
        .allowlist_function("SherpaOnnxDecodeOnlineStream")
        .allowlist_function("SherpaOnnxGetOnlineStreamResult")
        .allowlist_function("SherpaOnnxDestroyOnlineRecognizerResult")
        .allowlist_function("SherpaOnnxOnlineStreamInputFinished")
        .allowlist_function("SherpaOnnxOnlineStreamReset")
        .derive_default(true)
        .generate()
        .expect("bindgen failed on sherpa-onnx c-api.h");

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out.join("sherpa.rs"))
        .expect("could not write bindings");

    generate_c_header();
}

/// Emit core/include/subs.h from the #[no_mangle] surface in lib.rs.
///
/// Generated rather than hand-written so the header cannot silently drift out of
/// sync with the Rust definitions — a struct-layout mismatch across this boundary
/// would corrupt every event rather than fail to compile.
fn generate_c_header() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    println!("cargo:rerun-if-changed=src/lib.rs");
    let out = crate_dir.join("include/subs.h");
    std::fs::create_dir_all(out.parent().unwrap()).ok();

    match cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_language(cbindgen::Language::C)
        .with_pragma_once(true)
        .with_include_guard("SUBS_H")
        .with_documentation(true)
        .with_parse_deps(false)
        .generate()
    {
        Ok(b) => {
            b.write_to_file(&out);
        }
        // Never fail the build over the header: cargo test does not need it, and
        // a stale header is a louder failure at the Swift link step anyway.
        Err(e) => println!("cargo:warning=cbindgen: {e}"),
    }
}
