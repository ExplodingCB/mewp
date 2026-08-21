import XCTest
@testable import CleanMyMewp

final class Phase2Tests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-p2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeBytes(_ relativePath: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    // MARK: - Tree scanner

    func testTreeScannerAggregatesAndSorts() async throws {
        try writeBytes("t/a/x.bin", Data(repeating: 1, count: 5000))
        try writeBytes("t/a/y.bin", Data(repeating: 1, count: 5000))
        try writeBytes("t/b/z.bin", Data(repeating: 1, count: 5000))

        let tree = await TreeScanner.scan(root: root.appendingPathComponent("t"))
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertGreaterThanOrEqual(tree.size, 15000)
        // "a" holds two files, "b" one, so "a" sorts first.
        XCTAssertEqual(tree.children.first?.name, "a")
    }

    // MARK: - Duplicate finder

    func testFindsExactDuplicatesAcrossFullHash() async throws {
        // >64KB so the full-hash stage runs, not just the partial prefix.
        let contentA = Data(repeating: 0x7A, count: 100_000)
        let contentB = Data(repeating: 0x7B, count: 100_000) // same size, different bytes
        try writeBytes("dup/one.bin", contentA)
        try writeBytes("dup/two.bin", contentA)
        try writeBytes("dup/decoy.bin", contentB)
        try writeBytes("dup/unique.bin", Data(repeating: 0x01, count: 50_000))

        let entries = FileWalker.collect(root: root.appendingPathComponent("dup"))
        let groups = await DuplicateFinder.find(in: entries)

        XCTAssertEqual(groups.count, 1, "only one.bin/two.bin are identical")
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertGreaterThan(groups.first?.reclaimable ?? 0, 0)
    }

    func testSmallDuplicatesUsePartialShortCircuit() async throws {
        // ≤64KB: partial hash covers the whole file, no full-hash pass needed.
        let small = Data(repeating: 0x42, count: 1024)
        try writeBytes("s/a.bin", small)
        try writeBytes("s/b.bin", small)

        let entries = FileWalker.collect(root: root.appendingPathComponent("s"))
        let groups = await DuplicateFinder.find(in: entries)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testAllocatedSizeDoesNotShortCircuitLogicalContentHash() async throws {
        let prefix = Data(repeating: 0x41, count: 64 * 1024)
        let firstURL = try writeBytes("sparse/a.bin", prefix + Data([0x01]))
        let secondURL = try writeBytes("sparse/b.bin", prefix + Data([0x02]))
        let entries = [
            FileEntry(
                url: firstURL,
                size: 4096,
                logicalSize: Int64(prefix.count + 1),
                modified: nil,
                accessed: nil
            ),
            FileEntry(
                url: secondURL,
                size: 4096,
                logicalSize: Int64(prefix.count + 1),
                modified: nil,
                accessed: nil
            ),
        ]

        let groups = await DuplicateFinder.find(in: entries)
        XCTAssertTrue(groups.isEmpty, "matching prefixes must not create a duplicate group")
    }

    func testDuplicateIsRevalidatedBeforeRemoval() async throws {
        let content = Data(repeating: 0x55, count: 80_000)
        _ = try writeBytes("changed/a.bin", content)
        _ = try writeBytes("changed/b.bin", content)
        let entries = FileWalker.collect(root: root.appendingPathComponent("changed"))
        let groups = await DuplicateFinder.find(in: entries)
        let group = try XCTUnwrap(groups.first)
        let first = try XCTUnwrap(group.files.first)

        try Data(repeating: 0x66, count: 80_000).write(to: first.url)
        XCTAssertFalse(DuplicateFinder.stillMatches(first, digest: group.contentDigest))
    }

    // MARK: - File walker filtering

    func testWalkerHonorsMinSize() throws {
        try writeBytes("w/big.bin", Data(repeating: 0, count: 200_000))
        try writeBytes("w/small.bin", Data(repeating: 0, count: 100))
        let entries = FileWalker.collect(root: root.appendingPathComponent("w"), minSize: 150_000)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url.lastPathComponent, "big.bin")
        XCTAssertEqual(entries.first?.logicalSize, 200_000)
    }

    func testParallelWalkerMatchesSerialWalker() async throws {
        try writeBytes("parallel/a/one.bin", Data(repeating: 1, count: 4000))
        try writeBytes("parallel/b/two.bin", Data(repeating: 2, count: 5000))
        try writeBytes("parallel/top.bin", Data(repeating: 3, count: 6000))
        let scanRoot = root.appendingPathComponent("parallel")

        let serial = FileWalker.collect(root: scanRoot)
        let parallel = await FileWalker.collectParallel(root: scanRoot)

        XCTAssertEqual(Set(serial.map(\.url)), Set(parallel.map(\.url)))
        XCTAssertEqual(serial.reduce(0) { $0 + $1.logicalSize },
                       parallel.reduce(0) { $0 + $1.logicalSize })
    }

    func testTreeScannerAggregatesSmallLeafFiles() async throws {
        for index in 0..<520 {
            try writeBytes("many/\(index).bin", Data([UInt8(index % 255)]))
        }
        let tree = await TreeScanner.scan(root: root.appendingPathComponent("many"))
        let summary = try XCTUnwrap(tree.children.first { $0.isAggregate })
        // Every file is still counted, but only the largest 40 keep a node; the rest
        // collapse into one summary row. Keeping 500 per directory meant a whole-home
        // scan effectively allocated a node per file.
        XCTAssertEqual(tree.fileCount, 520)
        XCTAssertEqual(summary.fileCount, 480)
        XCTAssertEqual(tree.children.count, 41)
        // The aggregate must not lose bytes.
        XCTAssertEqual(tree.size, tree.children.reduce(0) { $0 + $1.size })
    }

    /// Directories past the depth budget are sized but not expanded, and drilling fills
    /// them in — this is what keeps a home scan from retaining millions of nodes.
    func testTreeScannerDefersDeepDirectoriesUntilExpanded() async throws {
        let deepPath = "deep/l1/l2/l3/l4/l5/l6/buried.bin"
        try writeBytes(deepPath, Data(repeating: 7, count: 3000))
        let tree = await TreeScanner.scan(root: root.appendingPathComponent("deep"))

        // Walk to the deepest node the scan actually materialised.
        var node = tree
        var levels = 0
        while let next = node.children.first(where: \.isDirectory) {
            node = next
            levels += 1
        }
        XCTAssertTrue(node.isUnexpanded, "deepest built directory should be deferred")
        XCTAssertLessThan(levels, 7, "scan should stop building below the depth budget")
        XCTAssertGreaterThan(node.size, 0, "a deferred directory still reports its size")
        XCTAssertTrue(node.children.isEmpty)

        let children = await TreeScanner.expandedChildren(of: node)
        XCTAssertFalse(children.isEmpty, "expanding a deferred directory yields its contents")
    }
}
