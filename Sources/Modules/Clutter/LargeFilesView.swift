import SwiftUI

@MainActor
final class LargeFilesViewModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready }
    enum Sort: String, CaseIterable, Identifiable { case size = "Largest", age = "Oldest"; var id: String { rawValue } }

    @Published var phase: Phase = .idle
    @Published var entries: [FileEntry] = []
    @Published var selection: Set<URL> = []
    @Published var scanRoot: URL = FileActions.home
    @Published var minSizeMB: Int = 50
    @Published var minAgeMonths: Int = 6
    @Published var sort: Sort = .size { didSet { resort() } }
    @Published var scannedCount: Int = 0
    @Published var isTrashing = false
    @Published var currentName = ""
    @Published var removalMessage: String?
    private var scanToken: ScanCancellationToken?

    func scan(_ url: URL) async {
        scanToken?.cancel()
        let token = ScanCancellationToken()
        scanToken = token
        scanRoot = url
        phase = .scanning
        selection = []
        scannedCount = 0
        currentName = ""
        removalMessage = nil
        let minBytes = Int64(minSizeMB) * 1_000_000
        let cutoff = Calendar.current.date(byAdding: .month, value: -minAgeMonths, to: Date()) ?? .distantPast
        let ageMonths = minAgeMonths

        let raw = await FileWalker.collectParallel(
            root: url,
            minSize: minBytes,
            isCancelled: { token.isCancelled },
            onProgress: { visited, name in
                Task { @MainActor in
                    self.scannedCount = visited
                    if !name.isEmpty { self.currentName = name }
                }
            }
        )
        let found = ageMonths > 0
            ? raw.filter { ($0.accessed ?? $0.modified ?? .distantPast) < cutoff }
            : raw

        guard scanToken === token, !token.isCancelled else {
            if scanToken === token {
                phase = .idle
                scanToken = nil
            }
            return
        }
        entries = found
        resort()
        phase = .ready
        scanToken = nil
    }

    func cancelScan() {
        scanToken?.cancel()
        currentName = "Cancelling…"
    }

    private func resort() {
        switch sort {
        case .size: entries.sort { $0.size > $1.size }
        case .age:
            entries.sort {
                ($0.accessed ?? $0.modified ?? .distantPast) < ($1.accessed ?? $1.modified ?? .distantPast)
            }
        }
    }

    var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    func trashSelected() async {
        let victims = selectedEntries
        guard !victims.isEmpty else { return }
        isTrashing = true
        let sizes = Dictionary(uniqueKeysWithValues: victims.map { ($0.url, $0.size) })
        let (_, failed) = await Task.detached(priority: .userInitiated) {
            FileActions.trash(victims.map(\.url), sizes: sizes)
        }.value
        let failedSet = Set(failed)
        entries.removeAll { selection.contains($0.id) && !failedSet.contains($0.url) }
        selection = Set(failed)
        if !failed.isEmpty {
            removalMessage = "\(failed.count) file\(failed.count == 1 ? "" : "s") could not be moved to Trash."
        }
        isTrashing = false
    }
}

struct LargeFilesView: View {
    @StateObject private var vm = LargeFilesViewModel()
    @State private var confirmingTrash = false

    private let theme = Module.largeFiles.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            switch vm.phase {
            case .idle: idleState
            case .scanning:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Scanning…").foregroundStyle(.secondary)
                    if vm.scannedCount > 0 {
                        Text("\(vm.scannedCount.formatted()) items checked · \(vm.currentName)")
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Button("Cancel") { vm.cancelScan() }
                        .buttonStyle(.bordered)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready: table
            }
            if vm.phase == .ready { actionBar }
        }
    }

    private var header: some View {
        ModuleHeader(title: "Large Files",
                     subtitle: "Big files you haven't opened in a while.") {
            Button("Choose Folder…") { chooseAndScan() }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            Button {
                Task { await vm.scan(vm.scanRoot) }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(GradientButtonStyle(colors: theme.colors))
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Bigger than", selection: $vm.minSizeMB) {
                Text("10 MB").tag(10); Text("50 MB").tag(50); Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1000)
            }.fixedSize()
            Picker("Not opened in", selection: $vm.minAgeMonths) {
                Text("Any time").tag(0); Text("3 months").tag(3); Text("6 months").tag(6); Text("1 year").tag(12); Text("2 years").tag(24)
            }.fixedSize()
            Picker("Sort", selection: $vm.sort) {
                ForEach(LargeFilesViewModel.Sort.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
    }

    private var idleState: some View {
        VStack(spacing: 28) {
            BigScanButton(title: "Scan Home", systemImage: "tray.full", theme: theme) {
                Task { await vm.scan(FileActions.home) }
            }
            VStack(spacing: 6) {
                Text("Find forgotten space hogs").font(.title3).fontWeight(.semibold)
                Text("Set your thresholds above, then scan.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var table: some View {
        Table(vm.entries, selection: $vm.selection) {
            TableColumn("Name") { e in
                HStack { Image(systemName: "doc").foregroundStyle(.secondary); Text(e.url.lastPathComponent).lineLimit(1) }
            }
            TableColumn("Size") { e in Text(e.size.formattedBytes).monospacedDigit() }.width(90)
            TableColumn("Last Opened") { e in Text(dateString(e.accessed ?? e.modified)).foregroundStyle(.secondary) }.width(130)
            TableColumn("Folder") { e in
                Text(e.url.deletingLastPathComponent().path.replacingOccurrences(of: FileActions.home.path, with: "~"))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { _ in
            Button("Reveal in Finder") { if let e = vm.selectedEntries.first { FileActions.revealInFinder(e.url) } }
        }
        .tableCard()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var actionBar: some View {
        HStack {
            Text("\(vm.entries.count) files · \(vm.totalBytes.formattedBytes)").foregroundStyle(.secondary)
            if let message = vm.removalMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            if !vm.selection.isEmpty {
                Text("\(vm.selection.count) selected · \(vm.selectedBytes.formattedBytes)").fontWeight(.medium)
                Button(role: .destructive) {
                    confirmingTrash = true
                } label: {
                    if vm.isTrashing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors))
                .disabled(vm.isTrashing)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .confirmationDialog(
            "Move \(vm.selection.count) file\(vm.selection.count == 1 ? "" : "s") to Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await vm.trashSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vm.selectedBytes.formattedBytes) will be moved to Trash and can be restored.")
        }
    }

    private func chooseAndScan() {
        if let url = FileActions.chooseFolder(message: "Choose a folder to scan for large & old files") {
            Task { await vm.scan(url) }
        }
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "Not available" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
