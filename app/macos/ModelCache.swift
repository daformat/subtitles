// Clearing out models that are no longer being used.
//
// Every variant in the model menu is a separate multi-hundred-megabyte download
// that stays on disk for good once fetched, so trying two or three of them
// quietly costs several gigabytes in Application Support. This finds the ones
// nothing is using and offers to remove them.
//
// Deliberately an allowlist, not a sweep: it only ever considers folders it can
// name, derived from FluidAudio's own `Repo.folderName` rather than from string
// literals here, so an upstream rename moves this with it instead of leaving it
// deleting the wrong thing. Anything else in that directory — another app's
// models, a file someone put there — is not ours to remove and is never looked
// at. FluidAudio ships a `clearAllCaches()` that removes the directory outright;
// that is exactly what must not happen while a model is loaded from it.

import AppKit
import CaptionCore
import FluidAudio

enum ModelCache {
    /// One removable model on disk.
    struct Entry {
        let name: String
        let url: URL
        let bytes: Int64
    }

    static var directory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory()
    }

    /// Every repo this app can cause to be downloaded, with the name to show for
    /// it. Nothing outside this list is ever a candidate for deletion.
    private static var known: [(repo: Repo, name: String)] {
        var out: [(Repo, String)] = FluidVariant.allCases.map { ($0.repo, $0.displayName) }
        out.append((.vad, "Voice detection"))
        out.append((.sortformer, "Speaker diarization"))
        // Variants can share a repo; keep the first name for each.
        var seen = Set<String>()
        return out.filter { seen.insert($0.0.folderName).inserted }
    }

    /// Folders that must survive: the recogniser in use, the voice detector, and
    /// the diarizer while speaker breaks are on.
    ///
    /// The voice detector is kept unconditionally. It is a megabyte, so there is
    /// nothing to reclaim, and it is loaded the moment VAD is switched back on —
    /// deleting it buys a re-download and no disk.
    static func inUse(variant: FluidVariant, speakerBreaks: Bool) -> Set<String> {
        var keep: Set<String> = [variant.repo.folderName, Repo.vad.folderName]
        if speakerBreaks { keep.insert(Repo.sortformer.folderName) }
        return keep
    }

    /// What is on disk, minus whatever `keeping` says is in use.
    ///
    /// Sizes are the sum of file allocations underneath, so the figure matches
    /// what Finder would give back rather than the download size.
    static func removable(keeping: Set<String>) -> [Entry] {
        let fm = FileManager.default
        return known.compactMap { entry in
            let folder = entry.repo.folderName
            guard !keeping.contains(folder) else { return nil }
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return Entry(name: entry.name, url: url, bytes: size(of: url))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
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

    /// Delete them, returning what could not be removed.
    ///
    /// Each path is checked to be inside the models directory before it goes
    /// anywhere near `removeItem` — cheap, and the one mistake here is
    /// unrecoverable.
    @discardableResult
    static func remove(_ entries: [Entry]) -> [String] {
        let root = directory
        var failed: [String] = []
        for entry in entries {
            // The containment check and the deletion both live in ModelStore, so
            // the one guard that actually matters is written once, in one place,
            // and can be tested against a directory that is not the real one.
            guard ModelStore.remove([entry.url], root: root).count == 1 else {
                failed.append(entry.name)
                continue
            }
            ModelStore.pruneEmptyParents(of: entry.url, root: root)
        }
        return failed
    }


    /// Compiled bundles under `root` that a download left unloadable.
    static func incompleteBundles(under root: URL) -> [URL] {
        ModelStore.incompleteBundles(under: root)
    }

    /// Delete the unloadable bundles in `repo` so the downloader fetches them
    /// again, and say which went.
    ///
    /// Only the broken bundles, not the whole repo: a 612 MB variant whose encoder
    /// alone is truncated should cost one encoder to put right, not the lot.
    ///
    /// Without this a partial download is permanent. The load throws every time,
    /// the app produces no transcript at all, and nothing says why — the only
    /// visible symptom is an overlay that never appears, which reads as any of a
    /// dozen unrelated faults.
    @discardableResult
    static func repair(repo: Repo) -> [String] {
        let root = directory.appendingPathComponent(repo.folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        return ModelStore.remove(ModelStore.incompleteBundles(under: root),
                                 root: directory).map(\.lastPathComponent)
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension FluidVariant {
    /// Where this variant's models are cached. FluidAudio owns the folder names;
    /// this only says which repo each menu entry corresponds to.
    var repo: Repo {
        switch self {
        case .eou160: return .parakeetEou160
        case .eou320: return .parakeetEou320
        case .eou1280: return .parakeetEou1280
        case .nemotron560: return .nemotronStreaming560
        case .nemotron1120: return .nemotronStreaming1120
        case .nemotron2240: return .nemotronStreaming2240
        case .unified: return .parakeetUnified
        case .multilingual: return .nemotronMultilingual
        }
    }
}
