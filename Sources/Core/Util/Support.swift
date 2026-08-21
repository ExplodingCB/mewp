import Foundation

/// Formats a byte count the way Finder does (base-10, e.g. "1.2 GB").
enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        // ByteCountFormatter is not documented as thread-safe; guard with a lock.
        lock.lock(); defer { lock.unlock() }
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private static let lock = NSLock()
}

extension Int64 {
    var formattedBytes: String { ByteFormat.string(self) }
}

/// Thread-safe cancellation flag for synchronous filesystem walkers running
/// inside detached tasks.
final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Runs `work` over `items` with at most `limit` operations in flight at once,
/// preserving input order in the returned array. Failures map to `nil`.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ work: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty else { return [] }
    let cap = max(1, limit)
    var results = [R?](repeating: nil, count: items.count)

    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        var running = 0

        func submit() {
            let i = next
            next += 1
            running += 1
            let item = items[i]
            group.addTask { (i, await work(item)) }
        }

        while next < items.count && running < cap { submit() }

        while let (i, r) = await group.next() {
            results[i] = r
            running -= 1
            if next < items.count { submit() }
        }
    }
    return results.map { $0! }
}
