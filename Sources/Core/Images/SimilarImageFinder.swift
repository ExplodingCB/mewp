import Foundation
import CoreGraphics
import ImageIO
import Vision

struct SimilarImagePair: Identifiable {
    let id = UUID()
    var first: FileEntry
    var second: FileEntry
    var visualDistance: Float

    var similarityPercent: Int {
        max(0, min(100, Int(((1 - Double(visualDistance)) * 100).rounded())))
    }
}

struct SimilarImageScanResult {
    var pairs: [SimilarImagePair]
    var imagesFound: Int
    var imagesFingerprintable: Int
    var hitLimit: Bool
    var message: String
}

enum SimilarImageFinder {
    private static let extensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
    ]

    static func find(
        under root: URL,
        isCancelled: @escaping () -> Bool = { false },
        onProgress: @escaping (Double, String) -> Void = { _, _ in }
    ) -> SimilarImageScanResult {
        if root.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame {
            return SimilarImageScanResult(
                pairs: [],
                imagesFound: 0,
                imagesFingerprintable: 0,
                hitLimit: false,
                message: "A Photos library cannot be scanned as a normal folder. Choose a folder containing exported image files."
            )
        }

        let collection = collectImages(root: root, limit: 2_000)
        let entries = collection.entries
        guard entries.count > 1 else {
            let detail = collection.hadReadError
                ? "CleanMyMewp could not read this folder. Choose another folder or grant the required Files and Folders access in System Settings."
                : "Found \(entries.count) image\(entries.count == 1 ? "" : "s"). At least two ordinary image files are needed."
            return SimilarImageScanResult(
                pairs: [],
                imagesFound: entries.count,
                imagesFingerprintable: 0,
                hitLimit: collection.hitLimit,
                message: detail
            )
        }
        onProgress(0.05, "Fingerprinting \(entries.count) images…")

        var fingerprints: [(FileEntry, UInt64, VNFeaturePrintObservation)] = []
        for (index, entry) in entries.enumerated() {
            if isCancelled() {
                return SimilarImageScanResult(
                    pairs: [],
                    imagesFound: entries.count,
                    imagesFingerprintable: fingerprints.count,
                    hitLimit: collection.hitLimit,
                    message: "Scan cancelled."
                )
            }
            guard let hash = differenceHash(url: entry.url),
                  let feature = featurePrint(url: entry.url)
            else { continue }
            fingerprints.append((entry, hash, feature))
            if index.isMultiple(of: 20) {
                onProgress(0.05 + 0.55 * Double(index) / Double(entries.count), entry.url.lastPathComponent)
            }
        }

        onProgress(0.62, "Comparing visual fingerprints…")
        var pairs: [SimilarImagePair] = []
        var usedPairs = Set<String>()
        for left in 0..<fingerprints.count {
            if isCancelled() {
                return SimilarImageScanResult(
                    pairs: pairs,
                    imagesFound: entries.count,
                    imagesFingerprintable: fingerprints.count,
                    hitLimit: collection.hitLimit,
                    message: "Scan cancelled."
                )
            }
            for right in (left + 1)..<fingerprints.count {
                let a = fingerprints[left]
                let b = fingerprints[right]
                guard hammingDistance(a.1, b.1) <= 16 else { continue }
                var distance: Float = 1
                guard (try? a.2.computeDistance(&distance, to: b.2)) != nil,
                      distance <= 0.45
                else { continue }

                let key = [a.0.url.path, b.0.url.path].sorted().joined(separator: "\u{0}")
                guard usedPairs.insert(key).inserted else { continue }
                pairs.append(SimilarImagePair(first: a.0, second: b.0, visualDistance: distance))
                if pairs.count >= 300 { break }
            }
            if pairs.count >= 300 { break }
            onProgress(0.62 + 0.36 * Double(left) / Double(max(1, fingerprints.count)), "Comparing images…")
        }
        onProgress(1, "Done")
        let sorted = pairs.sorted { $0.visualDistance < $1.visualDistance }
        let message: String
        if fingerprints.count < 2 {
            message = "Found \(entries.count) images, but fewer than two could be decoded."
        } else if sorted.isEmpty {
            message = "No similar pairs found among \(fingerprints.count) readable images."
        } else {
            message = "Found \(sorted.count) similar pair\(sorted.count == 1 ? "" : "s") among \(fingerprints.count) readable images."
        }
        return SimilarImageScanResult(
            pairs: sorted,
            imagesFound: entries.count,
            imagesFingerprintable: fingerprints.count,
            hitLimit: collection.hitLimit,
            message: message + (collection.hitLimit ? " Only the first 2,000 images were scanned." : "")
        )
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func differenceHash(url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 9,
                ] as CFDictionary
              )
        else { return nil }

        let width = 9
        let height = 8
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 0, count: width * height)
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<8 {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }

    private static func featurePrint(url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func collectImages(
        root: URL,
        limit: Int
    ) -> (entries: [FileEntry], hadReadError: Bool, hitLimit: Bool) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        var hadReadError = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                hadReadError = true
                return true
            }
        ) else { return ([], true, false) }

        var entries: [FileEntry] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let logical = Int64(values.fileSize ?? 0)
            entries.append(FileEntry(
                url: url,
                size: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                logicalSize: logical,
                modified: values.contentModificationDate,
                accessed: values.contentAccessDate
            ))
            if entries.count >= limit {
                return (entries, hadReadError, true)
            }
        }
        return (entries, hadReadError, false)
    }
}
