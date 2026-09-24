import XCTest
@testable import Mewp

final class Phase3Tests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-p3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePlist(_ name: String, values: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        return url
    }

    func testStartupItemParserFindsProgramAndState() throws {
        let url = try writePlist("good", values: [
            "Label": "com.example.good",
            "ProgramArguments": ["/bin/sh", "-c", "true"],
            "RunAtLoad": true,
        ])

        let item = try XCTUnwrap(StartupItemScanner.parse(url, scope: .userAgent))
        XCTAssertEqual(item.label, "com.example.good")
        XCTAssertEqual(item.program, "/bin/sh")
        XCTAssertTrue(item.runAtLoad)
        XCTAssertFalse(item.isBroken)
    }

    func testStartupItemParserFlagsMissingExecutable() throws {
        let url = try writePlist("broken", values: [
            "Label": "com.example.broken",
            "Program": "/definitely/not/a/real/executable",
        ])

        let item = try XCTUnwrap(StartupItemScanner.parse(url, scope: .systemDaemon))
        XCTAssertTrue(item.isBroken)
    }

    func testStartupItemParserUsesBatchedLoadedLabels() throws {
        let url = try writePlist("loaded", values: [
            "Label": "com.example.loaded",
            "Program": "/bin/sh",
        ])

        let item = try XCTUnwrap(StartupItemScanner.parse(
            url,
            scope: .userAgent,
            loadedLabels: ["com.example.loaded"]
        ))
        XCTAssertTrue(item.isLoaded)
    }

    func testStartupItemParserClassifiesPersistentReviewCandidate() throws {
        let url = try writePlist("persistent", values: [
            "Label": "com.example.persistent",
            "Program": "/bin/sh",
            "KeepAlive": ["SuccessfulExit": false],
        ])

        let item = try XCTUnwrap(StartupItemScanner.parse(
            url,
            scope: .userAgent,
            loadedLabels: []
        ))
        XCTAssertTrue(item.keepAlive)
        XCTAssertTrue(item.startsAutomatically)
        XCTAssertTrue(item.isReviewCandidate)
        XCTAssertEqual(item.startupBehavior, "Persistent")
    }

    func testStartupItemParserProtectsAppleItemsFromReviewFilter() throws {
        let url = try writePlist("apple", values: [
            "Label": "com.apple.example",
            "Program": "/bin/sh",
            "RunAtLoad": true,
        ])

        let item = try XCTUnwrap(StartupItemScanner.parse(
            url,
            scope: .systemAgent,
            loadedLabels: []
        ))
        XCTAssertTrue(item.isAppleItem)
        XCTAssertFalse(item.isReviewCandidate)
    }

    func testApplicationURLIsExtractedFromExecutablePath() {
        let result = SustainedProcessAnalyzer.applicationURL(
            forExecutablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        XCTAssertEqual(result?.path, "/Applications/Example.app")
        XCTAssertNil(
            SustainedProcessAnalyzer.applicationURL(
                forExecutablePath: "/usr/local/bin/example"
            )
        )
    }

    func testSustainedProcessAnalysisAveragesAndExcludesOneOffSpikes() {
        let snapshots = [
            [
                ProcessSample(
                    pid: 42,
                    cpuPercent: 10,
                    memoryBytes: 100,
                    name: "Example",
                    executablePath: "/Applications/Example.app/Contents/MacOS/Example"
                ),
                ProcessSample(
                    pid: 99,
                    cpuPercent: 90,
                    memoryBytes: 1_000,
                    name: "OneOff",
                    executablePath: "/tmp/one-off"
                ),
            ],
            [
                ProcessSample(
                    pid: 42,
                    cpuPercent: 30,
                    memoryBytes: 300,
                    name: "Example",
                    executablePath: "/Applications/Example.app/Contents/MacOS/Example"
                ),
            ],
        ]

        let result = SustainedProcessAnalyzer.aggregate(snapshots)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].pid, 42)
        XCTAssertEqual(result[0].averageCPUPercent, 20)
        XCTAssertEqual(result[0].peakCPUPercent, 30)
        XCTAssertEqual(result[0].averageMemoryBytes, 200)
        XCTAssertEqual(result[0].applicationURL?.path, "/Applications/Example.app")
    }

    func testSustainedProcessAnalysisGroupsHelpersByOwningApp() {
        let snapshots = [
            [
                ProcessSample(
                    pid: 42,
                    cpuPercent: 4,
                    memoryBytes: 100,
                    name: "Example",
                    executablePath: "/Applications/Example.app/Contents/MacOS/Example"
                ),
                ProcessSample(
                    pid: 43,
                    cpuPercent: 6,
                    memoryBytes: 200,
                    name: "Example Helper",
                    executablePath: "/Applications/Example.app/Contents/Frameworks/Example Helper"
                ),
            ],
            [
                ProcessSample(
                    pid: 42,
                    cpuPercent: 8,
                    memoryBytes: 300,
                    name: "Example",
                    executablePath: "/Applications/Example.app/Contents/MacOS/Example"
                ),
                ProcessSample(
                    pid: 43,
                    cpuPercent: 12,
                    memoryBytes: 500,
                    name: "Example Helper",
                    executablePath: "/Applications/Example.app/Contents/Frameworks/Example Helper"
                ),
            ],
        ]

        let result = SustainedProcessAnalyzer.aggregate(snapshots)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].pid, 42)
        XCTAssertEqual(result[0].averageCPUPercent, 15)
        XCTAssertEqual(result[0].peakCPUPercent, 20)
        XCTAssertEqual(result[0].averageMemoryBytes, 550)
    }

    func testMaintenanceOperationsUseFixedAbsoluteCommands() {
        XCTAssertEqual(MaintenanceOperation.allCases.count, 4)
        for operation in MaintenanceOperation.allCases {
            XCTAssertTrue(
                operation.shellCommand.hasPrefix("/usr/bin/")
                    || operation.shellCommand.hasPrefix("/usr/sbin/")
            )
            XCTAssertFalse(operation.shellCommand.contains("$"))
            XCTAssertFalse(operation.shellCommand.contains("`"))
        }
    }

    func testMemorySnapshotIsAvailable() {
        let snapshot = MemorySnapshot.current()
        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.physical ?? 0, 0)
    }
}
