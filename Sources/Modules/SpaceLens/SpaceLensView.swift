import SwiftUI

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready }

    @Published var phase: Phase = .idle
    @Published var root: FileNode?
    @Published var focus: FileNode?
    @Published var hoveredID: URL?
    @Published var scanRoot: URL = FileActions.home
    @Published var scannedBytes: Int64 = 0
    @Published var currentName: String = ""
    @Published var space: VolumeSpace?
    @Published var pendingTrashNode: FileNode?
    @Published var isTrashing = false
    @Published var removalMessage: String?
    /// Directory currently being expanded on demand, so its bubble can show progress.
    @Published var expandingID: URL?
    private var scanToken: ScanCancellationToken?

    func scan(_ url: URL) async {
        scanToken?.cancel()
        let token = ScanCancellationToken()
        scanToken = token
        scanRoot = url
        phase = .scanning
        scannedBytes = 0
        currentName = ""
        removalMessage = nil
        space = VolumeSpace.forRoot(url)

        let tree = await TreeScanner.scan(
            root: url,
            isCancelled: { token.isCancelled },
            onProgress: { bytes, name in
                Task { @MainActor in
                    guard self.scanToken === token else { return }
                    self.scannedBytes += bytes
                    self.currentName = name
                }
            }
        )
        guard scanToken === token, !token.isCancelled else {
            if scanToken === token {
                phase = .idle
                scanToken = nil
            }
            return
        }
        root = tree
        focus = tree
        phase = .ready
        scanToken = nil
    }

    func cancelScan() {
        scanToken?.cancel()
        currentName = "Cancelling…"
    }

    // MARK: - Navigation

    /// Path from the scan root down to the current focus, for the breadcrumb.
    var breadcrumb: [FileNode] {
        var chain: [FileNode] = []
        var node = focus
        while let n = node { chain.append(n); node = n.parent }
        return chain.reversed()
    }

    var canGoBack: Bool { focus?.parent != nil }

    /// Deep directories arrive from the scan measured but not expanded, so drilling into one
    /// builds its children on demand instead of the scan having held every level in memory.
    func drill(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node.isUnexpanded {
            Task { await expandThenFocus(node) }
            return
        }
        guard !node.children.isEmpty else { return }
        focus = node
        hoveredID = nil
    }

    private func expandThenFocus(_ node: FileNode) async {
        guard node.isUnexpanded, expandingID == nil else { return }
        expandingID = node.id
        let children = await TreeScanner.expandedChildren(of: node)
        expandingID = nil
        for child in children { child.parent = node }
        node.children = children
        node.isUnexpanded = false
        if !children.isEmpty {
            node.size = children.reduce(0) { $0 + $1.size }
            node.fileCount = children.reduce(0) { $0 + $1.fileCount }
            focus = node
            hoveredID = nil
        }
        objectWillChange.send()
    }

    func goBack() {
        if let p = focus?.parent { focus = p; hoveredID = nil }
    }

    func jump(to node: FileNode) { focus = node; hoveredID = nil }

    func requestTrash(_ node: FileNode) {
        guard !node.isAggregate, node.parent != nil else { return }
        pendingTrashNode = node
    }

    func trashPending() async {
        guard let node = pendingTrashNode else { return }
        pendingTrashNode = nil
        isTrashing = true
        removalMessage = nil
        let (_, failed) = await Task.detached(priority: .userInitiated) {
            FileActions.trash([node.url], sizes: [node.url: node.size])
        }.value
        guard failed.isEmpty, let parent = node.parent else {
            removalMessage = "Could not move \(node.name) to Trash."
            isTrashing = false
            return
        }
        // Surgical update: drop the node and walk its size out of the ancestors,
        // so we don't force a full rescan just to reflect one deletion.
        parent.children.removeAll { $0.id == node.id }
        var up: FileNode? = parent
        while let n = up {
            n.size -= node.size
            n.fileCount -= node.fileCount
            up = n.parent
        }
        space = VolumeSpace.forRoot(scanRoot)
        isTrashing = false
        objectWillChange.send()
    }
}

struct SpaceLensView: View {
    @StateObject private var vm = SpaceLensViewModel()

    private let theme = Module.spaceLens.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            switch vm.phase {
            case .idle: idleState
            case .scanning: scanningState
            case .ready: readyState
            }
        }
        .confirmationDialog(
            "Move \(vm.pendingTrashNode?.name ?? "item") to Trash?",
            isPresented: Binding(
                get: { vm.pendingTrashNode != nil },
                set: { if !$0 { vm.pendingTrashNode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await vm.trashPending() }
            }
            Button("Cancel", role: .cancel) { vm.pendingTrashNode = nil }
        } message: {
            if let node = vm.pendingTrashNode {
                Text("\(node.size.formattedBytes) will be moved to Trash and can be restored.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ModuleHeader(title: "Space Lens",
                     subtitle: "Bigger bubble, bigger space. Click a bubble to look inside.") {
            if vm.phase == .ready {
                Button { Task { await vm.scan(vm.scanRoot) } } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                Button("Choose Folder…") { chooseAndScan() }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            }
        }
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 28) {
            BigScanButton(title: "Scan Home", systemImage: "chart.pie", theme: theme) {
                Task { await vm.scan(FileActions.home) }
            }
            VStack(spacing: 6) {
                Text("Visualize your storage").font(.title3).fontWeight(.semibold)
                Text("Scan your Home folder (or pick another) to map where the space went.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Choose Folder…") { chooseAndScan() }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ScanningIndicator(
                theme: theme,
                status: "Scanning \(vm.scanRoot.lastPathComponent)…"
            )
            Text("\(vm.scannedBytes.formattedBytes) · \(vm.currentName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.readout, value: vm.scannedBytes)
            Button("Cancel") { vm.cancelScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyState: some View {
        VStack(spacing: 0) {
            navigationBar
            HStack(spacing: 14) {
                if let focus = vm.focus {
                    BubbleMapView(vm: vm, focus: focus)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    FolderListPanel(vm: vm, focus: focus)
                        .frame(width: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .cardStyle(cornerRadius: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Breadcrumb / back bar

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button { vm.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!vm.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(vm.breadcrumb) { node in
                        Button {
                            vm.jump(to: node)
                        } label: {
                            Text(node.parent == nil ? vm.scanRoot.lastPathComponent : node.name)
                                .fontWeight(node.id == vm.focus?.id ? .semibold : .regular)
                                .foregroundStyle(node.id == vm.focus?.id ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        if node.id != vm.focus?.id {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            if let focus = vm.focus {
                Text("\(focus.size.formattedBytes) · \(focus.fileCount) files")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if vm.isTrashing {
                ProgressView().controlSize(.small)
            } else if let message = vm.removalMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func chooseAndScan() {
        if let url = FileActions.chooseFolder(message: "Choose a folder to visualize") {
            Task { await vm.scan(url) }
        }
    }
}

// MARK: - Bubble map

struct BubbleMapView: View {
    @ObservedObject var vm: SpaceLensViewModel
    let focus: FileNode
    @State private var bubbles: [Bubble] = []
    @Namespace private var glassNamespace

    private static let palette: [Color] = [
        .blue, .teal, .purple, .orange, .pink, .indigo, .mint, .cyan, .green, .yellow,
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if bubbles.isEmpty {
                    Text(focus.children.isEmpty ? "Empty folder" : "Window too small")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                bubbleField
            }
            .onAppear { updateLayout(for: geo.size) }
            .onChange(of: geo.size) { _, newSize in updateLayout(for: newSize) }
            .onChange(of: focus.id) { _, _ in updateLayout(for: geo.size) }
        }
        .padding(8)
    }

    /// On macOS 26 the bubbles are real Liquid Glass, wrapped in a
    /// `GlassEffectContainer` so neighbours within `spacing` visually fuse into each
    /// other — packed bubbles bleed together like liquid instead of sitting as separate
    /// discs. Earlier systems fall back to the shaded-sphere rendering.
    @ViewBuilder private var bubbleField: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 20) {
                ZStack { bubbleViews }
            }
        } else {
            ZStack { bubbleViews }
        }
    }

    @ViewBuilder private var bubbleViews: some View {
        ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
            BubbleView(
                bubble: bubble,
                color: bubble.node.isAggregate
                    ? .gray
                    : bubble.node.isDirectory
                    ? Self.palette[index % Self.palette.count]
                    : .gray,
                hovered: vm.hoveredID == bubble.id,
                // Bigger bubbles land first, so the eye is drawn to the space hogs
                // before the small fry arrive.
                revealDelay: Double(min(index, 14)) * 0.035,
                glassNamespace: glassNamespace
            )
            .position(bubble.center)
            .onHover { inside in
                withAnimation(Motion.snappy) {
                    vm.hoveredID = inside ? bubble.id : nil
                }
            }
            .onTapGesture {
                if bubble.node.isAggregate { return }
                if bubble.node.isDirectory {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        vm.drill(bubble.node)
                    }
                } else {
                    FileActions.revealInFinder(bubble.node.url)
                }
            }
            .contextMenu {
                if !bubble.node.isAggregate {
                    Button("Reveal in Finder") { FileActions.revealInFinder(bubble.node.url) }
                    Button("Move to Trash", role: .destructive) { vm.requestTrash(bubble.node) }
                }
            }
        }
    }

    private func updateLayout(for size: CGSize) {
        let packed = BubbleLayout.pack(children: focus.children, in: size)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            bubbles = packed
        }
    }
}

struct BubbleView: View {
    let bubble: Bubble
    let color: Color
    let hovered: Bool
    var revealDelay: Double = 0
    /// Owned by `BubbleMapView`; shared so Liquid Glass can morph a bubble between
    /// layout passes instead of cross-fading it.
    let glassNamespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var diameter: CGFloat { bubble.radius * 2 }

    var body: some View {
        surface
            .frame(width: diameter, height: diameter)
            .scaleEffect(revealed ? (hovered ? 1.06 : 1) : 0.35)
            .opacity(revealed ? 1 : 0)
            .animation(Motion.snappy, value: hovered)
            .help("\(bubble.node.name) — \(bubble.node.size.formattedBytes)")
            // Reveal once, on appear. Drilling into a folder produces entirely new bubble
            // identities, so the entrance replays there naturally. Resetting this on every
            // re-pack meant a `GeometryReader` that reported its size more than once could
            // restart the fade repeatedly and leave bubbles stuck at zero opacity.
            .onAppear { reveal() }
    }

    private func reveal() {
        guard !revealed else { return }
        if reduceMotion {
            revealed = true
            return
        }
        withAnimation(
            .spring(response: 0.46, dampingFraction: 0.7).delay(revealDelay)
        ) {
            revealed = true
        }
    }

    /// Liquid Glass on macOS 26, shaded spheres below it.
    @ViewBuilder private var surface: some View {
        if #available(macOS 26.0, *) {
            liquidGlassBubble
        } else {
            legacySphere
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassBubble: some View {
        // Glass is mostly *refracted background*, and the wash behind the map is nearly
        // uniform — so a plain glass circle over it has almost nothing to refract and any
        // bubble too small to carry a label disappears entirely. A tinted base coat plus a
        // bright rim gives every bubble a body and an edge at any size; the glass layer on
        // top still does the refraction, specular highlight, and interactive flex.
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(hovered ? 0.95 : 0.72),
                            color.opacity(hovered ? 0.70 : 0.48),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            label
        }
        .frame(width: diameter, height: diameter)
        // `.interactive()` makes the glass flex and brighten under the pointer.
        .glassEffect(
            .regular
                .tint(color.opacity(hovered ? 0.34 : 0.22))
                .interactive(),
            in: Circle()
        )
        .overlay {
            Circle().strokeBorder(.white.opacity(hovered ? 0.55 : 0.28), lineWidth: 1)
        }
        .glassEffectID(bubble.id, in: glassNamespace)
        .shadow(color: color.opacity(hovered ? 0.45 : 0.22), radius: hovered ? 12 : 6, y: 3)
    }

    private var legacySphere: some View {
        ZStack {
            // Sphere shading: lighter top-left falling to a saturated bottom-right,
            // plus a glass highlight — flat circles read as a chart, spheres as a toy.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(hovered ? 1 : 0.9), color.opacity(hovered ? 0.85 : 0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.30), .clear],
                        center: .init(x: 0.35, y: 0.25),
                        startRadius: 0, endRadius: bubble.radius * 1.2
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(hovered ? 0.5 : 0.2), lineWidth: hovered ? 2 : 1)
            label
        }
        .shadow(color: color.opacity(hovered ? 0.5 : 0.25), radius: hovered ? 14 : 8, y: 4)
    }

    @ViewBuilder private var label: some View {
        if bubble.radius >= 34 {
            VStack(spacing: 1) {
                if bubble.node.isAggregate {
                    Image(systemName: "ellipsis")
                        .font(.system(size: min(20, bubble.radius * 0.3)))
                } else if bubble.node.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: min(20, bubble.radius * 0.3)))
                }
                Text(bubble.node.name)
                    .font(.system(size: max(10, min(15, bubble.radius * 0.22)), weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(bubble.node.size.formattedBytes)
                    .font(.system(size: max(9, min(13, bubble.radius * 0.18))))
                    .opacity(0.85)
                if bubble.radius >= 52 {
                    Text("\(Int((bubble.share * 100).rounded()))%")
                        .font(.system(size: 10)).opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(.horizontal, 6)
            .frame(maxWidth: bubble.radius * 1.7)
        }
    }
}

// MARK: - Ranked list panel

struct FolderListPanel: View {
    @ObservedObject var vm: SpaceLensViewModel
    let focus: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's inside")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(focus.children.prefix(200)) { child in
                        row(child)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            Spacer(minLength: 0)
            if let space = vm.space { footer(space) }
        }
    }

    private func row(_ child: FileNode) -> some View {
        let frac = focus.size > 0 ? Double(child.size) / Double(focus.size) : 0
        return Button {
            if child.isAggregate { return }
            if child.isDirectory { vm.drill(child) }
            else { FileActions.revealInFinder(child.url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: child.isAggregate ? "ellipsis.circle" : (child.isDirectory ? "folder.fill" : "doc"))
                        .foregroundStyle(child.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.caption)
                    Text(child.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(child.size.formattedBytes)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if child.isDirectory {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                // Percentage bar: the "what's actually taking the space" answer.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.tint)
                            .frame(width: max(2, g.size.width * frac))
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(vm.hoveredID == child.id ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { inside in vm.hoveredID = inside ? child.id : nil }
        .contextMenu {
            if !child.isAggregate {
                Button("Reveal in Finder") { FileActions.revealInFinder(child.url) }
                Button("Move to Trash", role: .destructive) { vm.requestTrash(child) }
            }
        }
    }

    private func footer(_ space: VolumeSpace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("Free (Finder):").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(space.important.formattedBytes).font(.caption).monospacedDigit()
            }
            HStack {
                Text("Free (df):").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(space.available.formattedBytes).font(.caption).monospacedDigit()
            }
            Text("They differ by purgeable space (snapshots, caches).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
