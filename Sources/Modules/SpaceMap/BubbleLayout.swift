import Foundation
import CoreGraphics

/// One placed bubble in the map.
struct Bubble: Identifiable {
    let node: FileNode
    var center: CGPoint
    var radius: CGFloat
    /// This node's share of the focused folder (0…1), for labels like "42%".
    var share: Double

    var id: URL { node.id }
}

/// Packed-bubble layout: every child of the focused folder
/// becomes a circle whose AREA is proportional to its size, greedily packed
/// around the middle of the canvas (largest first, spiraling outward). Pure
/// math — no UI — so it's unit-testable.
enum BubbleLayout {

    static let maxBubbles = 30
    static let minRadius: CGFloat = 16   // below this a bubble isn't clickable

    static func pack(children: [FileNode], in size: CGSize) -> [Bubble] {
        let candidates = Array(children.prefix(maxBubbles)).filter { $0.size > 0 }
        guard !candidates.isEmpty, size.width > 50, size.height > 50 else { return [] }
        let total = children.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return [] }

        // Radii: area ∝ size, scaled so all bubbles use ~½ the canvas area.
        let fillArea = size.width * size.height * 0.5
        var radii: [CGFloat] = candidates.map { node in
            let frac = Double(node.size) / Double(total)
            return max(minRadius, sqrt(frac * fillArea / .pi))
        }

        // Try to pack; if the spiral can't fit everything in bounds, shrink and retry.
        for attempt in 0..<8 {
            if let placed = tryPack(candidates, radii: radii, in: size) {
                return placed.map { (node, center, radius) in
                    Bubble(node: node, center: center, radius: radius,
                           share: Double(node.size) / Double(total))
                }
            }
            _ = attempt
            radii = radii.map { max(minRadius * 0.6, $0 * 0.88) }
        }
        return []
    }

    private static func tryPack(
        _ nodes: [FileNode], radii: [CGFloat], in size: CGSize
    ) -> [(FileNode, CGPoint, CGFloat)]? {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        var placed: [(FileNode, CGPoint, CGFloat)] = []

        for (i, node) in nodes.enumerated() {
            let r = radii[i]
            var found: CGPoint?
            // Deterministic spiral search out from the center.
            let golden = 2.399963229728653
            var t = 0.0
            while t < 4000 {
                let dist = t * 0.55
                let angle = t * golden
                let p = CGPoint(x: mid.x + dist * cos(angle) * 1.25, // slight horizontal bias: canvases are wide
                                y: mid.y + dist * sin(angle))
                t += 1
                // In bounds?
                if p.x - r < 4 || p.x + r > size.width - 4 || p.y - r < 4 || p.y + r > size.height - 4 { continue }
                // Overlap?
                var ok = true
                for (_, c, pr) in placed {
                    let dx = p.x - c.x, dy = p.y - c.y
                    if dx * dx + dy * dy < (r + pr + 3) * (r + pr + 3) { ok = false; break }
                }
                if ok { found = p; break }
            }
            guard let pos = found else { return nil }
            placed.append((node, pos, r))
        }
        return placed
    }

    /// Bubble under a point, if any (topmost = largest are drawn first, so any hit is fine —
    /// packing guarantees no overlap).
    static func hit(_ point: CGPoint, in bubbles: [Bubble]) -> Bubble? {
        bubbles.first {
            let dx = point.x - $0.center.x, dy = point.y - $0.center.y
            return dx * dx + dy * dy <= $0.radius * $0.radius
        }
    }
}
