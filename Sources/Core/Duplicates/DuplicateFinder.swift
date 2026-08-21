import Foundation
import CryptoKit

/// A set of byte-identical files. Keeping one copy, the rest are reclaimable.
struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    let contentDigest: Data
    var perFileSize: Int64
    var files: [FileEntry]

    /// Conservative estimate that assumes the largest allocated copy is kept.
    var reclaimable: Int64 {
        guard files.count > 1 else { return 0 }
        return files.reduce(0) { $0 + $1.size } - (files.map(\.size).max() ?? 0)
    }
    var count: Int { files.count }
}

/// fclones-style funnel: cheap filters first, expensive hashing only on survivors.
/// 1) group by exact size · 2) partial hash (first 64 KB) · 3) full SHA-256.
/// Each stage discards singleton groups, so we full-hash only genuine candidates.
enum DuplicateFinder {

    private static let partialLimit = 64 * 1024
    private struct PartialKey: Hashable {
        var size: Int64
        var digest: Data
    }

    static func find(
        in entries: [FileEntry],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (_ fraction: Double, _ status: String) -> Void = { _, _ in }
    ) async -> [DuplicateGroup] {
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // Stage 1 — group by size (free; metadata only).
        onProgress(0.1, "Grouping \(entries.count) files by size…")
        var bySize: [Int64: [FileEntry]] = [:]
        for e in entries where e.logicalSize > 0 {
            bySize[e.logicalSize, default: []].append(e)
        }
        let sizeSurvivors = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        if sizeSurvivors.isEmpty || isCancelled() { return [] }

        // Stage 2 — partial hash of survivors, regroup by (size, prefix hash).
        onProgress(0.35, "Comparing \(sizeSurvivors.count) candidates…")
        let partialWorkers = min(8, max(2, cores))
        let partial = await concurrentMap(sizeSurvivors, limit: partialWorkers) { e in
            (e, hash(url: e.url, expectedBytes: e.logicalSize, limit: Int64(partialLimit)))
        }
        var byPartial: [PartialKey: [FileEntry]] = [:]
        for (e, h) in partial {
            guard let h else { continue }
            byPartial[PartialKey(size: e.logicalSize, digest: h), default: []].append(e)
        }
        let partialGroups = byPartial.values.filter { $0.count > 1 }
        if partialGroups.isEmpty || isCancelled() { return [] }

        // Stage 3 — confirm. Files ≤ 64 KB were fully covered by the partial hash;
        // larger files need a full SHA-256 to rule out prefix collisions.
        onProgress(0.6, "Verifying duplicates…")
        var confirmed: [DuplicateGroup] = []
        for group in partialGroups {
            if isCancelled() { break }
            guard let first = group.first else { continue }
            let size = first.logicalSize
            if size <= Int64(partialLimit) {
                guard let digest = hash(
                    url: first.url,
                    expectedBytes: first.logicalSize,
                    limit: nil
                ) else { continue }
                confirmed.append(DuplicateGroup(
                    contentDigest: digest,
                    perFileSize: size,
                    files: group
                ))
                continue
            }
            // Full-file hashing is storage-bound. Capping this avoids turning a
            // scan into competing reads that make SSDs and external disks slower.
            let fullHashWorkers = min(4, max(2, cores / 2))
            let hashed = await concurrentMap(group, limit: fullHashWorkers) { e in
                (e, hash(url: e.url, expectedBytes: e.logicalSize, limit: nil))
            }
            var byFull: [Data: [FileEntry]] = [:]
            for (e, h) in hashed {
                guard let h else { continue }
                byFull[h, default: []].append(e)
            }
            for (digest, exact) in byFull where exact.count > 1 {
                confirmed.append(DuplicateGroup(
                    contentDigest: digest,
                    perFileSize: size,
                    files: exact
                ))
            }
        }

        onProgress(1.0, "Done")
        return confirmed.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// SHA-256 of a file, optionally only the first `limit` bytes. Chunked reads
    /// keep memory flat for large files.
    static func stillMatches(_ entry: FileEntry, digest: Data) -> Bool {
        hash(url: entry.url, expectedBytes: entry.logicalSize, limit: nil) == digest
    }

    /// Returns nil for short reads, read errors, or a file whose logical length
    /// changed during hashing. Partial hashes therefore never masquerade as full
    /// hashes for sparse or compressed files.
    private static func hash(url: URL, expectedBytes: Int64, limit: Int64?) -> Data? {
        guard expectedBytes >= 0 else { return nil }
        guard
            let currentSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            Int64(currentSize) == expectedBytes,
            let fh = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? fh.close() }

        var hasher = SHA256()
        let targetBytes = min(expectedBytes, limit ?? expectedBytes)
        var remaining = targetBytes

        do {
            while remaining > 0 {
                let toRead = Int(min(Int64(1 << 20), remaining))
                guard let data = try fh.read(upToCount: toRead), !data.isEmpty else {
                    return nil
                }
                hasher.update(data: data)
                remaining -= Int64(data.count)
            }

            if limit == nil {
                if let extra = try fh.read(upToCount: 1), !extra.isEmpty {
                    return nil
                }
                guard
                    let finalSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    Int64(finalSize) == expectedBytes
                else { return nil }
            }
        } catch {
            return nil
        }

        return Data(hasher.finalize())
    }
}
