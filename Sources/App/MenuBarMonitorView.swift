import SwiftUI
import AppKit

struct MenuBarMonitorView: View {
    @EnvironmentObject private var monitor: SystemMonitorModel
    @EnvironmentObject private var navigation: AppNavigationModel

    var body: some View {
        content
            // The sampler idles at a five-minute cadence and only speeds up while this
            // popover is actually on screen.
            .onAppear { monitor.setWatched(true) }
            .onDisappear { monitor.setWatched(false) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "pawprint.fill").foregroundStyle(.teal)
                Text("CleanMyMewp").font(.headline)
                Spacer()
                if let battery = monitor.snapshot.batteryPercent {
                    Label(
                        "\(battery)%",
                        systemImage: monitor.snapshot.charging ? "battery.100percent.bolt" : "battery.75percent"
                    )
                    .font(.caption).monospacedDigit()
                }
            }
            Divider()
            meter("CPU", value: monitor.snapshot.cpuPercent / 100, detail: "\(Int(monitor.snapshot.cpuPercent.rounded()))%")
            meter(
                "Memory",
                value: fraction(monitor.snapshot.memoryUsed, monitor.snapshot.memoryTotal),
                detail: "\(monitor.snapshot.memoryUsed.formattedBytes) / \(monitor.snapshot.memoryTotal.formattedBytes)"
            )
            meter(
                "Disk",
                value: 1 - fraction(monitor.snapshot.diskFree, monitor.snapshot.diskTotal),
                detail: "\(monitor.snapshot.diskFree.formattedBytes) free"
            )
            HStack {
                Label(monitor.snapshot.downloadBytesPerSecond.formattedBytes + "/s", systemImage: "arrow.down")
                Spacer()
                Label(monitor.snapshot.uploadBytesPerSecond.formattedBytes + "/s", systemImage: "arrow.up")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Label("Trash", systemImage: "trash")
                Spacer()
                Text(monitor.snapshot.trashBytes.formattedBytes).monospacedDigit()
            }
            .font(.caption)
            Divider()
            Button {
                navigation.requestSmartCareScan()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            } label: {
                Label("Run Smart Care Scan", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            HStack {
                Button("Open CleanMyMewp") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { monitor.start() }
    }

    private func meter(_ title: String, value: Double, detail: String) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: max(0, min(1, value)))
        }
    }

    private func fraction(_ used: Int64, _ total: Int64) -> Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}
