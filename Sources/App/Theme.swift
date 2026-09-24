import SwiftUI

// MARK: - Layout rhythm

enum Layout {
    static let contentMaxWidth: CGFloat = 940
    static let gutter: CGFloat = 26
    static let cardCorner: CGFloat = 14
    static let cardSpacing: CGFloat = 16
}

// MARK: - Motion

/// Shared motion vocabulary so the whole surface moves with one personality, and so
/// "Reduce motion" can be honoured in one place.
enum Motion {
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.84)
    static let arrive = Animation.spring(response: 0.44, dampingFraction: 0.86)
    static let screen = Animation.easeInOut(duration: 0.26)
    static let readout = Animation.easeOut(duration: 0.32)

    static func stagger(_ index: Int, step: Double = 0.04, cap: Int = 10) -> Animation {
        arrive.delay(Double(min(index, cap)) * step)
    }
}

/// Fades and lifts a view in when it first appears, offset by its position in a list so
/// results cascade instead of snapping in all at once.
private struct StaggeredAppear: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Motion.stagger(index)) { shown = true }
                }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

// MARK: - Module themes

/// Visual identity for one module: an accent gradient used in its background
/// wash, icon tile, and call-to-action buttons.
struct ModuleTheme {
    var colors: [Color]

    var accent: Color { colors.first ?? .accentColor }
    var trailingAccent: Color { colors.last ?? accent }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Module {
    var theme: ModuleTheme {
        switch self {
        case .checkup:
            return ModuleTheme(colors: [Color(hex: 0x2BD9C6), Color(hex: 0x7C5CFC)])
        case .cleanup:
            return ModuleTheme(colors: [Color(hex: 0x2BD9C6), Color(hex: 0x3D7BFF)])
        case .spaceMap:
            return ModuleTheme(colors: [Color(hex: 0xB44CF0), Color(hex: 0x5B5BF7)])
        case .largeFiles:
            return ModuleTheme(colors: [Color(hex: 0xFFB340), Color(hex: 0xFF6482)])
        case .duplicates:
            return ModuleTheme(colors: [Color(hex: 0xFF5FA2), Color(hex: 0x8E54E9)])
        case .uninstaller:
            return ModuleTheme(colors: [Color(hex: 0xFF7A59), Color(hex: 0xFF3B7A)])
        case .similarImages:
            return ModuleTheme(colors: [Color(hex: 0x5AC8FA), Color(hex: 0xAF52DE)])
        case .performance:
            return ModuleTheme(colors: [Color(hex: 0x30D158), Color(hex: 0x00B8A9)])
        case .startupItems:
            return ModuleTheme(colors: [Color(hex: 0xFF9F0A), Color(hex: 0xFF6B35)])
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Aurora background

/// The gradient wash behind every screen.
///
/// The accent only bleeds in from two corners at low opacity, and a scrim settles the
/// lower half back toward neutral. Washing the accent across the whole field tinted
/// data-heavy screens brown or green and made tables look muddy; keeping the middle of
/// the window close to neutral is what lets the cards read.
///
/// Deliberately static — an animated drift here means re-rasterising a full-window
/// gradient every frame for an effect nobody notices while reading.
struct AuroraBackground: View {
    let theme: ModuleTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(hex: 0x0A0D14) : Color(hex: 0xF4F6FB))
            RadialGradient(
                colors: [theme.accent.opacity(dark ? 0.22 : 0.16), .clear],
                center: .topLeading, startRadius: 0, endRadius: 640
            )
            RadialGradient(
                colors: [theme.trailingAccent.opacity(dark ? 0.17 : 0.12), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 700
            )
            RadialGradient(
                colors: [theme.trailingAccent.opacity(dark ? 0.10 : 0.07), .clear],
                center: .top, startRadius: 0, endRadius: 460
            )
            LinearGradient(
                colors: [
                    .clear,
                    (dark ? Color.black : Color(hex: 0xE9EDF6)).opacity(dark ? 0.55 : 0.5),
                ],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Icon tiles

/// Rounded-square gradient icon, System Settings style. Used in the sidebar
/// and on category rows.
struct IconTile: View {
    var systemImage: String
    var colors: [Color]
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .shadow(color: (colors.first ?? .black).opacity(0.35), radius: 3, y: 1)
    }
}

/// Per-category tile colors for the Cleanup list, keyed by category id.
enum CategoryTint {
    private static let map: [String: [Color]] = [
        "user-caches": [Color(hex: 0x2BD9C6), Color(hex: 0x21A8DE)],
        "user-logs": [Color(hex: 0x5AC8FA), Color(hex: 0x3D7BFF)],
        "saved-app-state": [Color(hex: 0x64D2FF), Color(hex: 0x5B5BF7)],
        "xcode-junk": [Color(hex: 0x30D158), Color(hex: 0x2BD9C6)],
        "dev-tool-caches": [Color(hex: 0x66D4CF), Color(hex: 0x34AADC)],
        "old-installers": [Color(hex: 0xFFB340), Color(hex: 0xFF8C42)],
        "trash": [Color(hex: 0x98989D), Color(hex: 0x636366)],
        "ios-backups": [Color(hex: 0xFF6482), Color(hex: 0xFF2D55)],
        "mail-attachments": [Color(hex: 0x5B5BF7), Color(hex: 0xB44CF0)],
    ]

    static func colors(for id: String) -> [Color] {
        map[id] ?? [Color(hex: 0x3D7BFF), Color(hex: 0x5B5BF7)]
    }
}

// MARK: - Cards

/// Floating glass card.
///
/// A bare `.regularMaterial` fill disappears against the dark wash, which is what made
/// every screen look flat. Three things give the card an edge: a faint fill lift over
/// the material, a hairline brighter along the top than the bottom (reads as a lit
/// edge), and a shadow deep enough to separate it from the background.
struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = Layout.cardCorner

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [.white.opacity(0.07), .white.opacity(0.015)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = Layout.cardCorner) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }

    /// Data tables and long lists: clip to the card shape and drop the system's
    /// alternating row stripes, which otherwise march on past the last real row and make
    /// a short table look like a broken spreadsheet.
    func tableCard(cornerRadius: CGFloat = Layout.cardCorner) -> some View {
        scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .cardStyle(cornerRadius: cornerRadius)
    }
}

// MARK: - Gradient buttons

/// Capsule call-to-action filled with the module gradient.
struct GradientButtonStyle: ButtonStyle {
    var colors: [Color]
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        let accent = colors.first ?? .accentColor
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background {
                if prominent {
                    Capsule().fill(
                        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    )
                } else {
                    Capsule().fill(accent.opacity(0.14))
                }
            }
            .overlay {
                if prominent {
                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
            }
            .shadow(color: prominent ? accent.opacity(0.34) : .clear, radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - The big scan button

/// The landing screen's call to action: a large circular gradient button with a soft
/// glow and translucent halo rings, breathing slightly while idle.
struct BigScanButton: View {
    var title: String
    var systemImage: String
    var theme: ModuleTheme
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(theme.accent.opacity(0.14), lineWidth: 1.5)
                    .frame(width: 208, height: 208)
                    .scaleEffect(breathing ? 1.04 : 0.98)
                Circle()
                    .stroke(theme.accent.opacity(0.26), lineWidth: 1.5)
                    .frame(width: 174, height: 174)
                    .scaleEffect(breathing ? 1.02 : 0.99)

                Circle()
                    .fill(
                        LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 148, height: 148)
                    .overlay {
                        Circle().fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .clear],
                                startPoint: .top, endPoint: .center
                            )
                        )
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .shadow(color: theme.accent.opacity(hovering ? 0.55 : 0.38), radius: hovering ? 26 : 18, y: 6)

                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .medium))
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(Motion.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

// MARK: - Scanning indicator

/// Shown while a module is working. A bare `ProgressView` gave no sense that anything
/// was being swept, which made long scans feel stalled.
struct ScanningIndicator: View {
    var theme: ModuleTheme
    var status: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.10))
                    .frame(width: 104, height: 104)
                    .scaleEffect(pulse ? 1.08 : 0.92)

                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [theme.accent.opacity(0), theme.accent, theme.trailingAccent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 84, height: 84)
                    .rotationEffect(.degrees(spin ? 360 : 0))

                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .opacity(pulse ? 1 : 0.55)
            }
            .accessibilityLabel("Scanning")

            if !status.isEmpty {
                Text(status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .id(status)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Hero header

/// Large friendly title block used at the top of every module.
struct ModuleHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}
