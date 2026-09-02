// Filesystem work for the model cache, with the directory passed in.
//
// Split out of ModelCache so it can be pointed at a temporary directory and
// tested. What lives here is everything that decides *which* paths to touch;
// what stays behind is the part that knows which repos FluidAudio owns.
//
// This is the only code in the app that deletes anything, and it deletes in
// gigabytes. The guard that every path is inside the models directory is
// therefore the load-bearing line in the file: cheap to check, and the one
// mistake here is not recoverable.

import Foundation

public enum ModelStore {
    /// Files CoreML needs inside a compiled bundle before it will load one.
    ///
    /// Confirmed against every healthy bundle on disk: recogniser, diarizer and
    /// VAD alike all carry `analytics`, `coremldata.bin`, `model.mil`, `weights`.
    /// An interrupted download leaves the two large directories behind and the
    /// two small files missing, which is exactly what CoreML refuses.
    public static let requiredInBundle = ["coremldata.bin", "model.mil"]

    /// Whether `url` is somewhere `root` actually contains.
    ///
    /// Standardised first, so `…/Models/../../Documents` is resolved rather than
    /// merely looking like a child. Equality with the root is not containment:
    /// removing the root itself is precisely the outcome this prevents.
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") && path != base
    }

    /// Compiled bundles under `root` that cannot load, because a download did not
    /// finish. Recursive: encoders sit a level down (`encoder/encoder_int8.mlmodelc`)
    /// and the multilingual pack nests a folder per language.
    public static func incompleteBundles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in walk where url.pathExtension == "mlmodelc" {
            let missing = requiredInBundle.contains {
                !fm.fileExists(atPath: url.appendingPathComponent($0).path)
            }
            if missing { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Delete `urls`, skipping anything not inside `root`, and say what went.
    @discardableResult
    public static func remove(_ urls: [URL], root: URL) -> [URL] {
        var removed: [URL] = []
        for url in urls where isInside(url, root: root) {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            removed.append(url)
        }
        return removed
    }

    /// Remove now-empty parents of `url`, never climbing to or above `root`.
    ///
    /// Repos nest a level down (`nemotron-streaming/560ms`), so taking the last
    /// tier leaves an empty parent behind.
    public static func pruneEmptyParents(of url: URL, root: URL) {
        let fm = FileManager.default
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while isInside(parent, root: root) {
            let contents = try? fm.contentsOfDirectory(atPath: parent.path)
            guard let contents, contents.isEmpty else { return }
            try? fm.removeItem(at: parent)
            parent = parent.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Bytes on disk beneath `url`, as allocated rather than as reported by the
    /// file lengths, so the figure matches what Finder would give back.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
