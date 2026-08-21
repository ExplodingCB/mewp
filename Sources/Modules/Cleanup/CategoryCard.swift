import SwiftUI

struct CategoryCard: View {
    @ObservedObject var vm: CleanupViewModel
    let result: CategoryScanResult

    private var isExpanded: Bool { vm.expandedCategoryIDs.contains(result.id) }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded && !result.items.isEmpty {
                Divider().padding(.leading, 44)
                itemsList
            }
        }
        .cardStyle()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            if result.lockedByPermission {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
            } else {
                CheckboxButton(state: vm.categorySelectionState(result), enabled: !result.items.isEmpty) {
                    let on = vm.categorySelectionState(result) != .on
                    vm.setCategory(result, selected: on)
                }
            }

            IconTile(systemImage: result.category.systemImage,
                     colors: CategoryTint.colors(for: result.category.id),
                     size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(result.category.name).fontWeight(.semibold)
                    RiskBadge(risk: result.category.risk)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if result.lockedByPermission {
                Button("Grant Access") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if !result.items.isEmpty {
                Text(result.totalSize.formattedBytes)
                    .font(.callout).fontWeight(.medium).monospacedDigit()
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Text("Nothing found").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { if !result.items.isEmpty { toggleExpanded() } }
    }

    private var subtitle: String {
        if let note = result.note { return note }
        if result.lockedByPermission { return "Needs Full Disk Access" }
        return result.category.subtitle
    }

    // MARK: - Items

    private var itemsList: some View {
        VStack(spacing: 0) {
            ForEach(result.items.prefix(200)) { item in
                itemRow(item)
                if item.id != result.items.prefix(200).last?.id {
                    Divider().padding(.leading, 44)
                }
            }
            if result.items.count > 200 {
                Text("+ \(result.items.count - 200) more smaller items")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 44).padding(.vertical, 8)
            }
        }
    }

    private func itemRow(_ item: JunkItem) -> some View {
        HStack(spacing: 12) {
            CheckboxButton(state: vm.isSelected(item) ? .on : .off, enabled: true) {
                vm.toggle(item)
            }
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary).frame(width: 24)
            Text(item.displayName).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(item.size.formattedBytes)
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { vm.toggle(item) }
    }

    private func toggleExpanded() {
        if isExpanded { vm.expandedCategoryIDs.remove(result.id) }
        else { vm.expandedCategoryIDs.insert(result.id) }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        Text(risk.label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch risk {
        case .safe: return .green
        case .caution: return .orange
        case .risky: return .red
        }
    }
}

struct CheckboxButton: View {
    let state: ToggleState
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .frame(width: 20)
    }

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }
}
