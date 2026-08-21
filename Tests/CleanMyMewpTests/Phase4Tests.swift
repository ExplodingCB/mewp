import XCTest
@testable import CleanMyMewp

final class Phase4Tests: XCTestCase {
    func testUninstallerMatchingRequiresBundleIdentifierBoundary() {
        XCTAssertTrue(ApplicationScanner.matches("com.example.Editor", bundleID: "com.example.Editor"))
        XCTAssertTrue(ApplicationScanner.matches("com.example.Editor.plist", bundleID: "com.example.Editor"))
        XCTAssertTrue(ApplicationScanner.matches("com.example.Editor.savedState", bundleID: "com.example.Editor"))
        XCTAssertFalse(ApplicationScanner.matches("com.example.EditorPro", bundleID: "com.example.Editor"))
        XCTAssertFalse(ApplicationScanner.matches("Editor", bundleID: "com.example.Editor"))
        XCTAssertFalse(ApplicationScanner.matches("com.example", bundleID: "com.example.Editor"))
    }

    func testUninstallerEnhancedMatchesStayMarkedForReview() {
        XCTAssertEqual(
            ApplicationScanner.matchTier("example.Editor.helper", bundleID: "com.example.Editor"),
            .enhanced
        )
        XCTAssertNil(
            ApplicationScanner.matchTier("unrelated.Editor", bundleID: "com.example.Editor")
        )
    }

    @MainActor
    func testSmartCareReportsBrokenStartupItems() {
        let performance = PerformanceSnapshot(
            memory: nil,
            pressure: .normal,
            availablePercent: 50,
            swapUsedBytes: 0,
            swapTotalBytes: 0,
            cpuPercent: 10,
            thermalState: "Nominal",
            battery: nil,
            topProcesses: []
        )
        let startup = StartupItem(
            plistURL: URL(fileURLWithPath: "/tmp/com.example.broken.plist"),
            label: "com.example.broken",
            program: "/missing/program",
            runAtLoad: true,
            scope: .userAgent,
            isLoaded: false,
            isEnabled: true,
            isBroken: true
        )
        let recommendations = SmartCareViewModel.makeRecommendations(
            performance: performance,
            startupItems: [startup]
        )
        XCTAssertEqual(recommendations.map(\.id), ["broken-startup-items"])
        XCTAssertEqual(recommendations.first?.destination, .startupItems)
    }

    func testImageHashHammingDistance() {
        XCTAssertEqual(SimilarImageFinder.hammingDistance(0, 0), 0)
        XCTAssertEqual(SimilarImageFinder.hammingDistance(0, UInt64.max), 64)
        XCTAssertEqual(
            SimilarImageFinder.hammingDistance(0b1010, 0b0011),
            2
        )
    }

    func testSimilarImageFinderFindsIdenticalFiles() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = sourceRoot.appendingPathComponent("app-icon.png")
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        try FileManager.default.copyItem(
            at: source,
            to: fixture.appendingPathComponent("copy-a.png")
        )
        try FileManager.default.copyItem(
            at: source,
            to: fixture.appendingPathComponent("copy-b.png")
        )

        let report = SimilarImageFinder.find(under: fixture)
        XCTAssertEqual(report.imagesFound, 2)
        XCTAssertEqual(report.imagesFingerprintable, 2)
        XCTAssertEqual(report.pairs.count, 1)
    }

    func testAllRoadmapModulesAreAvailable() {
        XCTAssertEqual(Module.allCases.count, 9)
        XCTAssertTrue(Module.allCases.contains(.smartCare))
        XCTAssertTrue(Module.allCases.contains(.uninstaller))
        XCTAssertTrue(Module.allCases.contains(.similarImages))
    }
}
