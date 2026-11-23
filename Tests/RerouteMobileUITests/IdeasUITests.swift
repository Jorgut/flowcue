import XCTest

/// 想法列表的交互回归：长按批量选择、左滑操作、单击进详情、上下滚动。
/// 这些断言只验证「能用」，视觉观感仍需人眼；但至少能把行为回归挡在发布前。
final class IdeasUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--flowcue-uitest-seed"]
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 列表能滚：向上拖之后，顶部那条的位置必须上移。
    func testScrollingWorks() {
        let top = app.staticTexts["UITest idea 20"]
        XCTAssertTrue(top.waitForExistence(timeout: 10), "种子数据没出现")
        snap("01-list")
        let before = top.frame.minY

        app.swipeUp()
        snap("02-after-swipe-up")

        let moved = !top.exists || top.frame.minY < before - 20
        XCTAssertTrue(moved, "向上滚动后列表没有移动（顶部条目仍在 \(before)）")
    }

    /// 长按进入批量选择，底部出现计数与操作。
    func testLongPressEntersSelection() {
        let first = app.staticTexts["UITest idea 20"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        snap("03-longpress")

        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 3),
                      "长按后没有进入批量选择")
        XCTAssertTrue(app.buttons["Delete"].exists, "批量删除按钮缺失")
        XCTAssertTrue(app.buttons["Archive"].exists, "批量归档按钮缺失")
        snap("04-selection-mode")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForNonExistence(timeout: 3))
    }

    /// 左滑露出两个操作，且不会跳详情。
    func testSwipeRevealsActions() {
        let first = app.staticTexts["UITest idea 20"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.swipeLeft()
        snap("05-swipe")

        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3), "左滑没露出 Archive")
        XCTAssertTrue(app.buttons["Delete"].exists, "左滑没露出 Delete")
        // 不该跳进详情：详情页有 Save 按钮
        XCTAssertFalse(app.buttons["Save"].exists, "左滑误跳到了详情页")
    }
}
