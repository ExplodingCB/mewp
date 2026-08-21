import XCTest
@testable import CleanMyMewp

/// These tests build a throwaway fixture tree and assert the scanner/deleter
/// only touch what they're supposed to. Nothing here reads the real home dir.
final class CleanupEngineTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Scanner sizing

    func testMeasureSumsSubtreeAllocatedSize() throws {
        _ = try write("cacheA/one.bin", bytes: 4096)
        _ = try write("cacheA/sub/two.bin", bytes: 4096)
        let measured = DirectoryScanner.measure(root.appendingPathComponent("cacheA"))
        XCTAssertEqual(measured.fileCount, 2)
        // Allocated size rounds up to block size, so assert a sane lower bound.
        XCTAssertGreaterThanOrEqual(measured.allocatedBytes, 8192)
    }

    func testChildrenAsItemsSkipsNames() async throws {
        _ = try write("Caches/com.good.app/f.bin", bytes: 2048)
        _ = try write("Caches/com.apple.FontRegistry/f.bin", bytes: 2048)

        let category = CleanupCategory(
            id: "t", name: "t", subtitle: "", systemImage: "x",
            risk: .safe, permission: .none,
            sources: [JunkSource(root: root.appendingPathComponent("Caches"),
                                 mode: .childrenAsItems, strategy: .moveItemToTrash,
                                 skipNames: ["com.apple.FontRegistry"])]
        )
        let result = await JunkScanner.scan(category, fullDiskAccessGranted: true)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.displayName, "com.good.app")
    }

    func testChildSubfoldersOnlyReturnsExistingNestedCaches() async throws {
        _ = try write("Containers/com.example.one/Data/Library/Caches/a.bin", bytes: 2048)
        _ = try write("Containers/com.example.two/Data/Documents/real-data.bin", bytes: 2048)

        let category = CleanupCategory(
            id: "containers",
            name: "containers",
            subtitle: "",
            systemImage: "shippingbox",
            risk: .safe,
            permission: .none,
            sources: [
                JunkSource(
                    root: root.appendingPathComponent("Containers"),
                    mode: .childSubfolders(relativePath: "Data/Library/Caches"),
                    strategy: .emptyContentsToTrash
                ),
            ]
        )
        let result = await JunkScanner.scan(category, fullDiskAccessGranted: true)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.displayName, "com.example.one")
        XCTAssertEqual(result.items.first?.strategy, .emptyContentsToTrash)
    }

    func testExpandedSafetyDatabaseKeepsAdministratorItemsOptIn() {
        let ids = Set(SafetyRules.categories().map(\.id))
        XCTAssertTrue(ids.contains("browser-caches"))
        XCTAssertTrue(ids.contains("sandboxed-app-caches"))
        XCTAssertTrue(ids.contains("safari-caches"))
        XCTAssertTrue(ids.contains("system-caches-logs"))
        XCTAssertFalse(SafetyRules.systemCachesAndLogs.selectedByDefault)
        XCTAssertEqual(SafetyRules.systemCachesAndLogs.permission, .admin)
    }

    // MARK: - Deleter

    func testMoveItemToTrashRemovesFromSource() throws {
        let file = try write("junk/big.bin", bytes: 10_000)
        let item = JunkItem(url: file.deletingLastPathComponent(), displayName: "junk",
                            size: 10_000, isDirectory: true, strategy: .moveItemToTrash,
                            categoryID: "t")
        let outcome = Deleter.run([item], permanent: true)
        XCTAssertEqual(outcome.deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
    }

    func testEmptyContentsPermanentKeepsContainer() throws {
        let container = root.appendingPathComponent("Trash")
        _ = try write("Trash/a.bin", bytes: 1000)
        _ = try write("Trash/b.bin", bytes: 1000)
        let item = JunkItem(url: container, displayName: "Trash", size: 2000,
                            isDirectory: true, strategy: .emptyContentsPermanent,
                            categoryID: "trash")
        let outcome = Deleter.run([item], permanent: true)
        XCTAssertEqual(outcome.deletedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path),
                      "container folder must survive")
        let leftover = try FileManager.default.contentsOfDirectory(atPath: container.path)
        XCTAssertTrue(leftover.isEmpty)
    }

    // MARK: - Safety invariants

    func testNoCategoryTargetsForbiddenRoots() {
        let forbidden = ["/System", "/private/var/folders"]
        for category in SafetyRules.categories() {
            for source in category.sources {
                for bad in forbidden {
                    XCTAssertFalse(source.root.path.hasPrefix(bad),
                                   "\(category.id) must not target \(bad)")
                }
            }
        }
    }

    func testTrashIsNeverSelectedByDefault() {
        XCTAssertEqual(SafetyRules.trash.risk, .caution)
        XCTAssertFalse(SafetyRules.trash.selectedByDefault)
        XCTAssertTrue(
            SafetyRules.trash.sources.allSatisfy {
                $0.strategy == .emptyContentsPermanent
            }
        )
    }
}
