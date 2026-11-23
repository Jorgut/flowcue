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


    /// 任意一条种子想法。不要写死编号——删除用例会把某一条删掉，
    /// 后续用例就会因为找不到它而失败。
    private func anySeedRow() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "UITest idea")).firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 列表能滚：向上拖之后，顶部那条的位置必须上移。
    func testScrollingWorks() {
        let top = anySeedRow()
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
        let first = anySeedRow()
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
        let first = anySeedRow()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.swipeLeft()
        snap("05-swipe")

        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3), "左滑没露出 Archive")
        XCTAssertTrue(app.buttons["Delete"].exists, "左滑没露出 Delete")
        // 不该跳进详情：详情页有 Save 按钮
        XCTAssertFalse(app.buttons["Save"].exists, "左滑误跳到了详情页")
    }

    /// 左滑后点 Delete 必须真的生效（不只是按钮存在）。
    func testSwipeDeleteActuallyWorks() {
        let top = anySeedRow()
        XCTAssertTrue(top.waitForExistence(timeout: 10))
        let deletedLabel = top.label
        top.swipeLeft()
        snap("06-before-delete-tap")

        let deleteButton = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()
        snap("07-after-delete-tap")

        // 删除有确认弹窗：先确认，再判断这一行是否消失。
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "点 Delete 后没有出现确认弹窗")
        confirm.tap()
        snap("08-after-confirm")

        XCTAssertTrue(app.staticTexts[deletedLabel].waitForNonExistence(timeout: 5),
                      "确认后这一行还在")
    }

    /// Me 页面必须有 Trash 入口。
    func testTrashEntryExistsInMe() {
        XCTAssertTrue(anySeedRow().waitForExistence(timeout: 10))
        app.buttons["Me"].firstMatch.tap()
        snap("08-me-page")

        let trash = app.staticTexts["Trash"]
        if !trash.waitForExistence(timeout: 3) {
            app.swipeUp()
            snap("09-me-scrolled")
        }
        XCTAssertTrue(app.staticTexts["Trash"].exists, "Me 页面找不到 Trash 入口")
    }
}

/// Agents → DSH 的会话列表应按项目文件夹分组。
final class AgentSessionsUITests: XCTestCase {
    func testSessionsAreGroupedByProject() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--flowcue-sessions-preview", "--flowcue-pro-preview", "--flowcue-uitest-seed"]
        app.launch()

        app.buttons["Agents"].firstMatch.tap()
        sleep(2)
        // 模拟器没有配对 Mac 时 Agents 页是空态，分组无从验证。
        if app.staticTexts["No agents yet"].waitForExistence(timeout: 3) {
            throw XCTSkip("模拟器未连接 Mac，跳过会话分组验证")
        }
        let early = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        early.name = "11-agents-page"
        early.lifetime = .keepAlways
        add(early)
        let dshRow = app.staticTexts["DSH"].firstMatch
        if !dshRow.waitForExistence(timeout: 5) {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(dshRow.waitForExistence(timeout: 5), "Agents 页面没有 DSH 入口")
        dshRow.tap()

        // 三个项目名应该作为分组标题出现
        for project in ["FLOWCUE-DEVELOPMENT", "QUIETBAR"] {
            XCTAssertTrue(app.staticTexts[project].waitForExistence(timeout: 8),
                          "缺少分组标题 \(project)")
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "10-sessions-grouped"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
