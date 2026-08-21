import SwiftUI
import AppKit

@MainActor
final class SimilarImagesViewModel: ObservableObject {
    @Published private(set) var pairs: [SimilarImagePair] = []
    @Published private(set) var scanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var scanSummary = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var result: MaintenanceResult?
    @Published var selection: Set<URL> = []
    @Published var scanRoot: URL?

    private var cancellation = ScanCancellationToken()

    var selectedBytes: Int64 {
        var sizes: [URL: Int64] = [:]
        for pair in pairs {
            sizes[pair.first.url] = pair.first.size
            sizes[pair.second.url] = pair.second.size
        }
        return selection.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    func scan(_ root: URL) async {
        cancellation.cancel()
        cancellation = ScanCancellationToken()
        let token = cancellation
        scanRoot = root
        hasScanned = false
        scanning = true
        progress = 0
        status = "Finding images…"
        selection = []
        result = nil
        let report = await Task.detached(priority: .userInitiated) {
            SimilarImageFinder.find(
                under: root,
                isCancelled: { token.isCancelled },
                onProgress: { fraction, message in
                    Task { @MainActor in
                        self.progress = fraction
                        self.status = message
                    }
                }
            )
        }.value
        pairs = report.pairs
        scanSummary = report.message
        hasScanned = true
        scanning = false
    }

    func cancel() {
        cancellation.cancel()
        scanning = false
    }

    func trashSelected() async {
        let urls = Array(selection)
        var sizes: [URL: Int64] = [:]
        for pair in pairs {
            sizes[pair.first.url] = pair.first.size
            sizes[pair.second.url] = pair.second.size
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            FileActions.trash(urls, sizes: sizes)
        }.value
        result = MaintenanceResult(
            succeeded: outcome.failed.isEmpty,
            message: outcome.failed.isEmpty
                ? "Moved \(outcome.freed.formattedBytes) to Trash."
                : "\(outcome.failed.count) image\(outcome.failed.count == 1 ? "" : "s") could not be moved."
        )
        let failed = Set(outcome.failed)
        selection = failed
        pairs.removeAll { pair in
            !failed.contains(pair.first.url)
                && !failed.contains(pair.second.url)
                && (!FileManager.default.fileExists(atPath: pair.first.url.path)
                    || !FileManager.default.fileExists(atPath: pair.second.url.path))
        }
    }
}

struct SimilarImagesView: View {
    @StateObject private var vm = SimilarImagesViewModel()
    @State private var confirming = false
    private let theme = Module.similarImages.theme

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                title: "Similar Images",
                subtitle: "Find visually similar photos with local perceptual and Vision fingerprints."
            ) {
                HStack {
                    Button("Choose folder") { chooseFolder() }
                    if vm.scanning {
                        Button("Cancel") { vm.cancel() }
                    } else if let root = vm.scanRoot {
                        Button("Scan") { Task { await vm.scan(root) } }
                    }
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            }
            content
        }
        .confirmationDialog(
            "Move \(vm.selection.count) image\(vm.selection.count == 1 ? "" : "s") to Trash?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await vm.trashSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vm.selectedBytes.formattedBytes) will be moved. Review each pair and never select both unless both are unwanted.")
        }
    }

    @ViewBuilder private var content: some View {
        if vm.scanning {
            VStack(spacing: 14) {
                ProgressView(value: vm.progress).frame(maxWidth: 420)
                Text(vm.status).foregroundStyle(.secondary)
                Text(vm.scanRoot?.path ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.pairs.isEmpty {
            VStack(spacing: 18) {
                BigScanButton(title: "Choose Folder", systemImage: "folder.badge.plus", theme: theme) {
                    chooseFolder()
                }
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                if let root = vm.scanRoot {
                    Text(root.path)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(vm.pairs) { pair in
                        pairCard(pair)
                    }
                }
                .padding(20)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(vm.selection.count) selected · \(vm.selectedBytes.formattedBytes)")
                    Spacer()
                    Button("Move selected to Trash") { confirming = true }
                        .buttonStyle(GradientButtonStyle(colors: theme.colors))
                        .disabled(vm.selection.isEmpty || selectedBothInAnyPair)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.regularMaterial)
            }
        }
    }

    private func pairCard(_ pair: SimilarImagePair) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(pair.similarityPercent)% visual match").fontWeight(.semibold)
                Spacer()
                Text("Choose one to remove").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                imageChoice(pair.first)
                imageChoice(pair.second)
            }
        }
        .padding(14)
        .cardStyle()
    }

    private func imageChoice(_ entry: FileEntry) -> some View {
        Button {
            if vm.selection.contains(entry.url) { vm.selection.remove(entry.url) }
            else { vm.selection.insert(entry.url) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let image = NSImage(contentsOf: entry.url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").resizable().scaledToFit().padding(30)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 180)
                .clipped()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Image(systemName: vm.selection.contains(entry.url) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(vm.selection.contains(entry.url) ? .red : .secondary)
                    Text(entry.url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Text(entry.size.formattedBytes).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(vm.selection.contains(entry.url) ? .red : .clear, lineWidth: 2)
        }
    }

    private var selectedBothInAnyPair: Bool {
        vm.pairs.contains { vm.selection.contains($0.first.url) && vm.selection.contains($0.second.url) }
    }

    private var emptyStateMessage: String {
        if let result = vm.result { return result.message }
        if vm.hasScanned { return vm.scanSummary }
        return "Choose a folder containing ordinary JPG, PNG, HEIC, TIFF, or WebP files. Photos library packages cannot be read as folders."
    }

    private func chooseFolder() {
        if let url = FileActions.chooseFolder(message: "Choose a folder of images to compare") {
            Task { await vm.scan(url) }
        }
    }
}
