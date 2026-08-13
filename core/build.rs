// Emits core/include/subs.h from the #[no_mangle] surface in lib.rs.
//
// Generated rather than hand-written so the header cannot silently drift out of
// sync with the Rust definitions — a struct-layout mismatch across this boundary
// would corrupt every event rather than fail to compile.

use std::env;
use std::path::PathBuf;

fn main() {
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
