// The only code in the app that deletes anything.
//
// It deletes in gigabytes, from a directory that also holds other applications'
// models, and the single thing standing between a repair and someone's home
// folder is a path check. These run against a temporary tree so that check can
// be aimed at the cases that would be unrecoverable in the real one.

import XCTest
@testable import CaptionCore

final class ModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("modelstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A compiled bundle: `complete` writes the two files CoreML insists on.
    @discardableResult
    private func bundle(_ path: String, complete: Bool) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        let fm = FileManager.default
        // Present either way, which is what makes a half-finished download look
        // plausible on disk: the big directories arrive, the small files do not.
        for directory in ["analytics", "weights"] {
            try fm.createDirectory(at: url.appendingPathComponent(directory),
                                   withIntermediateDirectories: true)
        }
        if complete {
            for file in ModelStore.requiredInBundle {
                try Data("x".utf8).write(to: url.appendingPathComponent(file))
            }
        }
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `/var` against `/private/var`: the directory enumerator resolves the
    /// symlink the temporary directory sits behind and the fixtures do not, so
    /// the two describe the same file by different paths.
    private func resolved(_ urls: [URL]) -> [String] {
        urls.map { $0.resolvingSymlinksInPath().path }
    }

    // MARK: the containment guard

    func testAPathInsideTheRootIsInside() throws {
        let inner = try bundle("repo/encoder.mlmodelc", complete: true)
        XCTAssertTrue(ModelStore.isInside(inner, root: root))
    }

    /// Removing the models directory itself is the outcome this exists to stop:
    /// FluidAudio loads from it while the app is running.
    func testTheRootIsNotInsideItself() {
        XCTAssertFalse(ModelStore.isInside(root, root: root))
    }

    func testASiblingDirectoryIsNotInside() {
        let sibling = root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        XCTAssertFalse(ModelStore.isInside(sibling, root: root))
    }

    /// A prefix match on the raw string would accept this: the path really does
    /// begin with the root's characters.
    func testASiblingWithTheSameNamePrefixIsNotInside() {
        let lookalike = URL(fileURLWithPath: root.path + "-other/thing.mlmodelc")
        XCTAssertFalse(ModelStore.isInside(lookalike, root: root))
    }

    /// Traversal has to be resolved, not merely inspected.
    func testDotDotEscapingTheRootIsNotInside() {
        let escaped = root.appendingPathComponent("repo/../../Documents/precious")
        XCTAssertFalse(ModelStore.isInside(escaped, root: root))
    }

    func testRemoveRefusesAnythingOutsideTheRoot() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("keepme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let removed = ModelStore.remove([outside], root: root)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(exists(outside), "a path outside the models directory was deleted")
    }

    func testRemoveTakesWhatIsInsideAndLeavesWhatIsNot() throws {
        let inside = try bundle("repo/encoder.mlmodelc", complete: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("keepme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let removed = ModelStore.remove([outside, inside], root: root)
        XCTAssertEqual(resolved(removed), resolved([inside]))
        XCTAssertFalse(exists(inside))
        XCTAssertTrue(exists(outside))
    }

    // MARK: spotting a half-finished download

    func testFindsOnlyTheBundlesThatCannotLoad() throws {
        try bundle("repo/decoder.mlmodelc", complete: true)
        try bundle("repo/joint.mlmodelc", complete: true)
        let broken = try bundle("repo/encoder/encoder_int8.mlmodelc", complete: false)

        XCTAssertEqual(resolved(ModelStore.incompleteBundles(under: root)), resolved([broken]))
    }

    /// Encoders sit a level down and the multilingual pack nests a folder per
    /// language, so a shallow scan would miss most of them.
    func testSearchesNestedDirectories() throws {
        let deep = try bundle("repo/v2/fr/encoder.mlmodelc", complete: false)
        XCTAssertEqual(resolved(ModelStore.incompleteBundles(under: root)), resolved([deep]))
    }

    func testAHealthyCacheReportsNothing() throws {
        try bundle("repo/decoder.mlmodelc", complete: true)
        try bundle("other/encoder.mlmodelc", complete: true)
        XCTAssertTrue(ModelStore.incompleteBundles(under: root).isEmpty)
    }

    /// Anything that is not a compiled bundle is none of this code's business:
    /// the directory is shared with other applications.
    func testIgnoresDirectoriesThatAreNotBundles() throws {
        let stranger = root.appendingPathComponent("someone-elses-data", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        XCTAssertTrue(ModelStore.incompleteBundles(under: root).isEmpty)
        XCTAssertTrue(exists(stranger))
    }

    func testAMissingRootIsNotAnError() {
        let absent = root.appendingPathComponent("never-created", isDirectory: true)
        XCTAssertTrue(ModelStore.incompleteBundles(under: absent).isEmpty)
    }

    // MARK: pruning what a removal emptied

    func testRemovesAParentLeftEmpty() throws {
        let nested = try bundle("nemotron-streaming/560ms/encoder.mlmodelc", complete: true)
        ModelStore.remove([nested], root: root)
        ModelStore.pruneEmptyParents(of: nested, root: root)

        XCTAssertFalse(exists(root.appendingPathComponent("nemotron-streaming/560ms")))
        XCTAssertFalse(exists(root.appendingPathComponent("nemotron-streaming")))
    }

    func testKeepsAParentThatStillHoldsSomething() throws {
        let gone = try bundle("nemotron-streaming/560ms/encoder.mlmodelc", complete: true)
        try bundle("nemotron-streaming/1120ms/encoder.mlmodelc", complete: true)
        ModelStore.remove([gone], root: root)
        ModelStore.pruneEmptyParents(of: gone, root: root)

        XCTAssertTrue(exists(root.appendingPathComponent("nemotron-streaming/1120ms")))
        XCTAssertTrue(exists(root.appendingPathComponent("nemotron-streaming")))
    }

    /// Emptying the last repo must not take the models directory with it.
    func testNeverPrunesTheRoot() throws {
        let only = try bundle("repo/encoder.mlmodelc", complete: true)
        ModelStore.remove([only], root: root)
        ModelStore.pruneEmptyParents(of: only, root: root)
        XCTAssertTrue(exists(root))
    }

    // MARK: sizes

    func testSizeCountsFilesBeneathADirectory() throws {
        let url = try bundle("repo/encoder.mlmodelc", complete: true)
        try Data(repeating: 0, count: 4096).write(to: url.appendingPathComponent("weights/w.bin"))
        XCTAssertGreaterThanOrEqual(ModelStore.size(of: url), 4096)
    }

    func testSizeOfSomethingMissingIsZero() {
        XCTAssertEqual(ModelStore.size(of: root.appendingPathComponent("nope")), 0)
    }
}
