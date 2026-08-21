import XCTest
import CoreGraphics
@testable import CleanMyMewp

final class BubbleLayoutTests: XCTestCase {

    private func node(_ name: String, size: Int64, dir: Bool = true) -> FileNode {
        let n = FileNode(url: URL(fileURLWithPath: "/\(name)"), isDirectory: dir)
        n.size = size
        return n
    }

    func testBubblesDoNotOverlapAndStayInBounds() {
        let children = (1...20).map { node("n\($0)", size: Int64($0) * 100_000_000) }
        let size = CGSize(width: 800, height: 500)
        let bubbles = BubbleLayout.pack(children: children, in: size)

        XCTAssertEqual(bubbles.count, 20)
        for b in bubbles {
            XCTAssertGreaterThanOrEqual(b.center.x - b.radius, 0)
            XCTAssertLessThanOrEqual(b.center.x + b.radius, size.width)
            XCTAssertGreaterThanOrEqual(b.center.y - b.radius, 0)
            XCTAssertLessThanOrEqual(b.center.y + b.radius, size.height)
        }
        for i in 0..<bubbles.count {
            for j in (i + 1)..<bubbles.count {
                let a = bubbles[i], b = bubbles[j]
                let dist = hypot(a.center.x - b.center.x, a.center.y - b.center.y)
                XCTAssertGreaterThanOrEqual(dist + 0.5, a.radius + b.radius,
                                            "\(a.node.name) overlaps \(b.node.name)")
            }
        }
    }

    func testLargerItemsGetLargerBubblesAndShares() {
        let big = node("big", size: 900)
        let small = node("small", size: 100)
        let bubbles = BubbleLayout.pack(children: [big, small], in: CGSize(width: 600, height: 400))

        let bigBubble = try! XCTUnwrap(bubbles.first { $0.node === big })
        let smallBubble = try! XCTUnwrap(bubbles.first { $0.node === small })
        XCTAssertGreaterThan(bigBubble.radius, smallBubble.radius)
        XCTAssertEqual(bigBubble.share, 0.9, accuracy: 0.001)
    }

    func testHitFindsBubbleUnderPoint() {
        let a = node("a", size: 500)
        let bubbles = BubbleLayout.pack(children: [a], in: CGSize(width: 400, height: 400))
        let bubble = try! XCTUnwrap(bubbles.first)

        XCTAssertNotNil(BubbleLayout.hit(bubble.center, in: bubbles))
        let outside = CGPoint(x: bubble.center.x + bubble.radius + 10, y: bubble.center.y)
        XCTAssertNil(BubbleLayout.hit(outside, in: bubbles))
    }

    func testZeroAndTinyCanvasesProduceNoBubbles() {
        let children = [node("a", size: 100)]
        XCTAssertTrue(BubbleLayout.pack(children: children, in: CGSize(width: 10, height: 10)).isEmpty)
        XCTAssertTrue(BubbleLayout.pack(children: [], in: CGSize(width: 500, height: 500)).isEmpty)
    }
}
