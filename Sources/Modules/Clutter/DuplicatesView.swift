import SwiftUI

@MainActor
final class DuplicatesViewModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready }

    @Published var phase: Phase = .idle
    @Published var groups: [DuplicateGroup] = []
    @Published var selection: Set<URL> = []      // FileEntry ids marked for deletion
    @Published var scanRoot: URL = FileActions.home.appendingPathComponent("Downloads")
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var isTrashing = false
    @Published var visitedCount = 0
    @Published var removalMessage: String?
    private var scanToken: ScanCancellationToken?

    func scan(_ url: URL) async {
        scanToken?.cancel()
        let token = ScanCancellationToken()
        scanToken = token
        scanRoot = url
        phase = .scanning
        progress = 0
        status = "Reading files…"
        visitedCount = 0
        selection = []
        removalMessage = nil

        let entries = await FileWalker.collectParallel(
            root: url,
            minSize: 4096,
            useLogicalSizeForMinimum: true,
            isCancelled: { token.isCancelled },
            onProgress: { visited, name in
                Task { @MainActor in
                    self.visitedCount = visited
                    if !name.isEmpty { self.status = "Reading \(name)…" }
                }
            }
        )

        guard scanToken === token, !token.isCancelled else {
            if scanToken === token {
                phase = .idle
                status = "Scan cancelled"
                scanToken = nil
            }
            return
        }

        let found = await DuplicateFinder.find(
            in: entries,
            isCancelled: { token.isCancelled },
            onProgress: { frac, status in
                Task { @MainActor in self.progress = frac; self.status = status }
            }
        )
        guard scanToken === token, !token.isCancelled else {
            if scanToken === token {
                phase = .idle
                status = "Scan cancelled"
                scanToken = nil
            }
            return
        }
        groups = found
        autoSelect()
        phase = .ready
        scanToken = nil
    }

    func cancelScan() {
        scanToken?.cancel()
        status = "Cancelling…"
    }

    /// Default: keep the newest copy in each group, mark the rest for deletion.
    private func autoSelect() {
        var sel = Set<URL>()
        for group in groups {
            let sorted = group.files.sorted {
                ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
            }
            for extra in sorted.dropFirst() { sel.insert(extra.id) }
        }
        selection = sel
    }

    var totalGroups: Int { groups.count }
    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    var selectedEntries: [FileEntry] { groups.flatMap(\.files).filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    func toggle(_ entry: FileEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else if canSelect(entry) {
            selection.insert(entry.id)
        }
    }

    func canSelect(_ entry: FileEntry) -> Bool {
        if selection.contains(entry.id) { return true }
        guard let group = groups.first(where: { $0.files.contains(entry) }) else { return false }
        return group.files.contains {
            $0.id != entry.id && !selection.contains($0.id)
        }
    }

    func trashSelected() async {
        let victims = selectedEntries
        guard !victims.isEmpty else { return }
        isTrashing = true
        removalMessage = nil
        let selected = selection
        let snapshot = groups

        // Re-hash selected files and at least one retained copy immediately
        // before removal. A file changed since the scan is never touched.
        let verified = await Task.detached(priority: .userInitiated) {
            var safe: [FileEntry] = []
            for group in snapshot {
                let keepers = group.files.filter { !selected.contains($0.id) }
                guard keepers.contains(where: {
                    DuplicateFinder.stillMatches($0, digest: group.contentDigest)
                }) else { continue }
                safe.append(contentsOf: group.files.filter {
                    selected.contains($0.id)
                        && DuplicateFinder.stillMatches($0, digest: group.contentDigest)
                })
            }
            return safe
        }.value

        let skippedChanged = victims.count - verified.count
        let sizes = Dictionary(uniqueKeysWithValues: verified.map { ($0.url, $0.size) })
        let (_, failed) = await Task.detached(priority: .userInitiated) {
            FileActions.trash(verified.map(\.url), sizes: sizes)
        }.value
        let failedSet = Set(failed)
        let removed = Set(verified.filter { !failedSet.contains($0.url) }.map(\.id))
        groups = groups.compactMap { g in
            var g = g
            g.files.removeAll { removed.contains($0.id) }
            return g.files.count > 1 ? g : nil
        }
        selection.subtract(removed)
        if skippedChanged > 0 || !failed.isEmpty {
            var parts: [String] = []
            if skippedChanged > 0 {
                parts.append("\(skippedChanged) changed or unreadable")
            }
            if !failed.isEmpty {
                parts.append("\(failed.count) could not be moved")
            }
            removalMessage = parts.joined(separator: ", ") + ". Nothing uncertain was removed."
        }
        isTrashing = false
    }
}

struct DuplicatesView: View {
    @StateObject private var vm = DuplicatesViewModel()
    @State private var confirmingTrash = false

    private let theme = Module.duplicates.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            switch vm.phase {
            case .idle: idleState
            case .scanning: scanningState
            case .ready: content
            }
            if vm.phase == .ready { actionBar }
        }
    }

    private var header: some View {
        ModuleHeader(title: "Duplicates",
                     subtitle: "Byte-for-byte identical files. Keep one, reclaim the rest.") {
            if vm.phase == .ready {
                Button { Task { await vm.scan(vm.scanRoot) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                Button("Choose Folder…") { chooseAndScan() }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 28) {
            BigScanButton(title: "Scan", systemImage: "square.on.square", theme: theme) {
                Task { await vm.scan(vm.scanRoot) }
            }
            VStack(spacing: 6) {
                Text("Find duplicate files").font(.title3).fontWeight(.semibold)
                Text("Compares files by size, then by hash. Matches are exact, not guesses.\nStarts in Downloads.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Choose Folder…") { chooseAndScan() }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView(value: vm.progress).frame(width: 220)
            Text(vm.status).font(.callout).foregroundStyle(.secondary)
            if vm.visitedCount > 0 {
                Text("\(vm.visitedCount.formatted()) items checked")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button("Cancel") { vm.cancelScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        Group {
            if vm.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 42, weight: .light)).foregroundStyle(.green)
                    Text("No duplicates found").font(.title3).fontWeight(.semibold)
                    Text("Nothing identical under \(vm.scanRoot.lastPathComponent).").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.groups) { group in DuplicateGroupCard(vm: vm, group: group) }
                        Color.clear.frame(height: 6)
                    }
                    .padding(20)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text("\(vm.totalGroups) groups · \(vm.totalReclaimable.formattedBytes) reclaimable").foregroundStyle(.secondary)
            if let message = vm.removalMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
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
            .disabled(vm.selection.isEmpty || vm.isTrashing)
            .opacity(vm.selection.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .confirmationDialog(
            "Move \(vm.selection.count) duplicate file\(vm.selection.count == 1 ? "" : "s") to Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await vm.trashSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vm.selectedBytes.formattedBytes) will be moved. At least one verified copy from every group will remain.")
        }
    }

    private func chooseAndScan() {
        if let url = FileActions.chooseFolder(message: "Choose a folder to scan for duplicates") {
            Task { await vm.scan(url) }
        }
    }
}

struct DuplicateGroupCard: View {
    @ObservedObject var vm: DuplicatesViewModel
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(group.count) copies").fontWeight(.semibold)
                Text("· \(group.perFileSize.formattedBytes) each").foregroundStyle(.secondary)
                Spacer()
                Text("save \(group.reclaimable.formattedBytes)").font(.callout).foregroundStyle(.green)
            }
            .padding(12)
            Divider()
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 12) {
                    CheckboxButton(
                        state: vm.selection.contains(file.id) ? .on : .off,
                        enabled: vm.canSelect(file)
                    ) {
                        vm.toggle(file)
                    }
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.url.lastPathComponent).lineLimit(1)
                        Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: FileActions.home.path, with: "~"))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { FileActions.revealInFinder(file.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                if file.id != group.files.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .cardStyle()
    }
}
