import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryItemTests: XCTestCase {
    func testPlainTextOnlyRequiresOnlyPlainTextRepresentations() {
        let plain = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
        ])
        XCTAssertTrue(plain.isPlainTextOnly)

        let rich = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
            .init(typeIdentifier: ClipboardRepresentationType.rtf, data: Data("{\\rtf1 Hello}".utf8)),
        ])
        XCTAssertFalse(rich.isPlainTextOnly)

        let additionalData = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
            .init(typeIdentifier: "com.example.custom-content", data: Data([1])),
        ])
        XCTAssertFalse(additionalData.isPlainTextOnly)
    }

    private func item(representations: [ClipboardStoredRepresentation]) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: representations),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
    }
}
