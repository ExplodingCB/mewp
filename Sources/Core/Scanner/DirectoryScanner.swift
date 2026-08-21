import Foundation

/// Result of measuring a file or directory subtree on disk.
struct MeasuredSize: Sendable {
    var allocatedBytes: Int64 = 0
    var fileCount: Int = 0
}

/// Low-level filesystem measurement using prefetched resource keys. Independent
/// top-level folders are dispatched through bounded task groups by the callers,
/// which keeps this synchronous walker simple and works on local and network volumes.
enum DirectoryScanner {

    /// Keys we prefetch so enumeration doesn't stat each file twice.
    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
    ]

    /// Allocated on-disk size of a single file/dir url (not recursive).
    static func allocatedSize(ofItem url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: sizeKeys)
        return Int64(values?.totalFileAllocatedSize
            ?? values?.fileAllocatedSize
            ?? values?.fileSize
            ?? 0)
    }

    /// Recursively measures a subtree's allocated size and regular-file count.
    /// Symlinks are counted at their own (tiny) size and never followed.
    static func measure(_ url: URL) -> MeasuredSize {
        var result = MeasuredSize()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return result }

        if !isDir.boolValue {
            result.allocatedBytes = allocatedSize(ofItem: url)
            result.fileCount = 1
            return result
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [], // include hidden; do NOT skip descendants
            errorHandler: { _, _ in true } // skip unreadable entries, keep going
        ) else {
            return result
        }

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: sizeKeys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                let bytes = values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
                result.allocatedBytes += Int64(bytes)
                result.fileCount += 1
            }
        }
        return result
    }

    /// Immediate children of a directory (non-recursive), hidden included.
    static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: []
        )) ?? []
    }
}
