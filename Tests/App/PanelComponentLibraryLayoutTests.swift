import XCTest
@testable import MacTools

final class PanelComponentLibraryLayoutTests: XCTestCase {
    private let panelWidth = ComponentPanelLayout.gridWidth
    private let spacing = PanelComponentLibraryLayout.spacing

    func testAllPreviewsShareTheTwoPanelScale() {
        let sources = [CGSize(width: 70, height: 88), CGSize(width: panelWidth, height: 48)]
        for scale: CGFloat in [0.5, 0.692, 1, 1.5] {
            let layout = PanelComponentLibraryLayout(sourceSizes: sources,
                availableWidth: panelWidth * 2 * scale + spacing)
            XCTAssertEqual(layout.scale, scale, accuracy: 0.0001)
            for (source, frame) in zip(sources, layout.frames) {
                XCTAssertEqual(frame.width, source.width * scale, accuracy: 0.0001)
                XCTAssertEqual(frame.height, source.height * scale, accuracy: 0.0001)
            }
            XCTAssertEqual(layout.frames[1].minX, layout.frames[0].maxX + spacing, accuracy: 0.0001)
            XCTAssertEqual(layout.frames[1].minY, 0, "A row fits immediately beside a narrow icon")
        }
    }

    func testNarrowPreviewsFillLeftToRightBeforeWrapping() {
        let size = CGSize(width: 70, height: 88)
        let layout = PanelComponentLibraryLayout(sourceSizes: Array(repeating: size, count: 10),
            availableWidth: panelWidth * 2 + spacing)
        for index in 0..<7 {
            XCTAssertEqual(layout.frames[index], CGRect(x: CGFloat(index) * 84, y: 0, width: 70, height: 88))
        }
        for index in 7..<10 {
            XCTAssertEqual(layout.frames[index], CGRect(x: CGFloat(index - 7) * 84, y: 102, width: 70, height: 88))
        }
        XCTAssertEqual(layout.height, 190, "The scroll extent excludes trailing spacing")
    }

    func testFullWidthPreviewsStillFillTheShorterColumn() {
        let sources = [200, 50, 100, 50, 80].map { CGSize(width: panelWidth, height: CGFloat($0)) }
        let layout = PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: panelWidth * 2 + spacing)
        XCTAssertEqual(layout.frames.map(\.origin), [
            CGPoint(x: 0, y: 0), CGPoint(x: 318, y: 0), CGPoint(x: 318, y: 64),
            CGPoint(x: 318, y: 178), CGPoint(x: 0, y: 214)
        ])
        XCTAssertEqual(layout.height, 294)
    }

    func testMixedWidthsUseTopmostThenLeftmostAvailableSpace() {
        let sources = [CGSize(width: 70, height: 160), CGSize(width: 148, height: 48),
                       CGSize(width: 226, height: 96), CGSize(width: 70, height: 48),
                       CGSize(width: 148, height: 64), CGSize(width: 304, height: 80)]
        let layout = PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: panelWidth * 2 + spacing)
        XCTAssertEqual(layout.frames.map(\.origin), [
            CGPoint(x: 0, y: 0), CGPoint(x: 84, y: 0), CGPoint(x: 246, y: 0),
            CGPoint(x: 486, y: 0), CGPoint(x: 84, y: 62), CGPoint(x: 246, y: 110)
        ])
        XCTAssertEqual(layout.height, 190)
    }

    func testMeasuredHeightReflowsWithoutChangingScaleOrWidths() {
        var sources = Array(repeating: CGSize(width: panelWidth, height: 48), count: 3)
        let before = PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: 435)
        sources[0].height = 240
        let after = PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: 435)
        XCTAssertEqual(before.scale, after.scale)
        XCTAssertEqual(before.frames.map(\.width), after.frames.map(\.width))
        XCTAssertEqual(before.frames[2].minX, 0)
        XCTAssertEqual(after.frames[2].minX, after.frames[1].minX)
        XCTAssertEqual(after.frames[2].minY, after.frames[1].maxY + spacing)
    }

    func testManyMixedPreviewsStayWithinBoundsAndNeverOverlap() {
        let sources: [CGSize] = (0..<256).map { index in
            let columns = (index * 7) % 4 + 1
            let rows = (index * 11) % 37 + 1
            return CGSize(width: columns * 78 - 8, height: rows * 8)
        }
        for width: CGFloat in [210, 435, 622] {
            let layout = PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: width)
            XCTAssertEqual(layout.frames.count, sources.count)
            XCTAssertEqual(layout.frames, PanelComponentLibraryLayout(sourceSizes: sources, availableWidth: width).frames)
            for (index, frame) in layout.frames.enumerated() {
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.001)
                XCTAssertLessThanOrEqual(frame.maxY, layout.height)
                let padding: CGFloat = -spacing / 2 + 0.001
                let padded = frame.insetBy(dx: padding, dy: padding)
                for other in layout.frames.dropFirst(index + 1) {
                    XCTAssertFalse(padded.intersects(other.insetBy(dx: -spacing / 2, dy: -spacing / 2)))
                }
            }
        }
    }

    func testEmptyAndUnavailableWidthHaveNoFramesOrScrollExtent() {
        let empty = PanelComponentLibraryLayout(sourceSizes: [], availableWidth: 435)
        XCTAssertTrue(empty.frames.isEmpty)
        XCTAssertEqual(empty.height, 0)
        for width: CGFloat in [0, -1, spacing, .infinity, .nan] {
            let layout = PanelComponentLibraryLayout(sourceSizes: [CGSize(width: 70, height: 88)], availableWidth: width)
            XCTAssertTrue(layout.frames.isEmpty)
            XCTAssertEqual(layout.scale, 0)
            XCTAssertEqual(layout.height, 0)
        }
    }
}
