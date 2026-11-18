import XCTest
@testable import CodexIdeaDockCore

final class LocalizationTests: XCTestCase {
    func testEnglishAndMandarinInterfaceStrings() {
        XCTAssertEqual(L10n.text("保存", language: .english), "Save")
        XCTAssertEqual(L10n.text("保存", language: .mandarin), "保存")
        XCTAssertEqual(L10n.text("想法已保存到本地。", language: .english), "Idea saved locally.")
        XCTAssertEqual(L10n.text("User-authored note", language: .english), "User-authored note")
    }
}
