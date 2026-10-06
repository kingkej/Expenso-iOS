import XCTest
import UIKit

/// Run only on a disposable simulator. Keyboard checks never save or analyze drafts.
/// The local OCR integration saves and deletes only its synthetic receipt, with no API requests.
@MainActor
final class KeyboardLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testKeyboardLayoutLight() throws { try exerciseScreens(style: "Light") }
    func testKeyboardLayoutDark() throws { try exerciseScreens(style: "Dark") }

    func testLocalClipboardReceiptReviewAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let dashboard = app.navigationBars["Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 15))

        // Exercise the real image paste control and Vision recognizer, not a test-only screen.
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            ("UI Coffee Sample\nTOTAL 125.00 RUB\n2026-10-05" as NSString).draw(
                in: CGRect(x: 80, y: 100, width: 1040, height: 600),
                withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }
        app.buttons["Add Transaction"].tap()
        app.buttons["Scan Receipt or Screenshot"].tap()
        let input = app.textViews["Transactions to import"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        pasteFromEditMenu(input, app: app)
        let transaction = app.navigationBars["Transaction"]
        let reviewOpened = transaction.waitForExistence(timeout: 45)
        if !reviewOpened, app.buttons["Details"].exists { app.buttons["Details"].tap() }
        XCTAssertTrue(reviewOpened, "One receipt must open verification inside the import sheet. \(app.debugDescription)")
        attach(app, "Local-Clipboard-Verification")
        let title = app.textFields["Title"]
        // OCR/model availability may leave merchant unknown. Verification must
        // allow filling that field rather than guessing a title from the image.
        if title.value as? String == "Title" || title.value as? String == "" {
            title.tap()
            title.typeText("UI Coffee Sample")
            tapOutsideInput(transaction, app: app)
        }
        XCTAssertEqual(title.value as? String, "UI Coffee Sample")
        XCTAssertEqual(app.textFields["Amount"].value as? String, "125")
        XCTAssertFalse(app.buttons["Continue to Transaction Editor"].exists)

        // Apple Intelligence isn't guaranteed on Simulator; use the normal picker
        // if no semantic category was available. Financial fields remain OCR-derived.
        let chooseCategory = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose Category")).firstMatch
        if chooseCategory.exists {
            chooseCategory.tap()
            let food = app.buttons["Food"]
            XCTAssertTrue(food.waitForExistence(timeout: 5))
            food.tap()
        }
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.isEnabled && add.isHittable)
        add.tap()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 15), "Saving must finish import without reopening the blank editor.")
        let saved = app.staticTexts["UI Coffee Sample"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The verified receipt must be saved once.")
        saved.tap()
        let detail = app.navigationBars["Transaction"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.buttons["More"].tap()
        app.buttons["Delete Transaction"].tap()
        app.alerts["Delete Transaction?"].buttons["Delete"].tap()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["UI Coffee Sample"].exists)
    }

    private func exerciseScreens(style: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", style, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let dashboard = app.navigationBars["Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 15), "The real Dashboard must launch without an authentication gate on the disposable simulator.")
        attach(app, "\(style)-Dashboard")
        let add = app.buttons["Add Transaction"]
        XCTAssertTrue(add.waitForExistence(timeout: 5) && add.isHittable)
        add.tap()

        let header = app.navigationBars["New Transaction"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertLessThan(header.frame.minY, app.frame.height * 0.18, "Transaction editors open expanded.")
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        amount.typeText("125")
        XCTAssertFalse(app.buttons["Done"].exists, "Numeric input must not add a keyboard Done toolbar.")
        tapOutsideInput(header, app: app)
        assertKeyboardHidden(app)
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        title.typeText("UI layout draft — never saved")
        // Scroll the actual form. A downward drag at its top boundary can
        // legitimately dismiss the entire sheet instead of scrolling content.
        let form = app.scrollViews.containing(.textField, identifier: "Title").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5) && form.isHittable)
        form.swipeUp()
        assertKeyboardHidden(app)
        if !title.isHittable { form.swipeDown() }
        title.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let action = app.buttons["Add"].firstMatch
        assertLayout(app: app, header: header, action: action, keyboard: true)
        let scan = app.buttons["Scan Receipt or Screenshot"]
        XCTAssertTrue(scan.exists && scan.isHittable, "Import must remain reachable while Title is focused.")
        attach(app, "\(style)-Add-Keyboard")
        scan.tap()

        let importHeader = app.navigationBars["Import"]
        XCTAssertTrue(importHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Attachment"].exists)
        XCTAssertFalse(app.buttons["Import Limits"].exists)
        XCTAssertFalse(app.buttons["Import Text"].exists)
        attach(app, "\(style)-Import")
        let textHeader = importHeader
        let text = app.textViews["Transactions to import"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        UIPasteboard.general.string = "2026-10-05, Taxi, 125.00 RUB"
        pasteFromEditMenu(text, app: app)
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2026-10-05, Taxi, 125.00 RUB"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed, app.debugDescription)
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        text.typeText("\n2026-10-05, Coffee, 100 RUB")
        // Deliberately never tap Analyze: no API credits or remote data transmission.
        let analyze = app.buttons["Add Attachment"]
        assertLayout(app: app, header: textHeader, action: analyze, keyboard: true)
        attach(app, "\(style)-ImportText-Keyboard")
        XCTAssertFalse(app.buttons["Done"].exists, "Import must not add a keyboard Done toolbar.")
        tapOutsideInput(textHeader, app: app)
        let keyboardGone = NSPredicate(format: "exists == false")
        let hidden = XCTNSPredicateExpectation(predicate: keyboardGone, object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        assertLayout(app: app, header: textHeader, action: analyze, keyboard: false)
        attach(app, "\(style)-ImportText-KeyboardDismissed")

        XCTAssertLessThan(textHeader.frame.minY, app.frame.height * 0.18, "Import opens expanded without a sheet drag.")
        assertLayout(app: app, header: textHeader, action: analyze, keyboard: false)
        attach(app, "\(style)-ImportText-Large")
        XCTAssertTrue(importHeader.waitForExistence(timeout: 5))
        importHeader.buttons["Cancel"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "UI layout draft — never saved")
        XCTAssertEqual(amount.value as? String, "125")
        assertKeyboardHidden(app)
        header.buttons["Cancel"].tap()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
    }

    func testHistorySearchAndCategoryEditorDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 15))
        app.buttons["Options"].tap()
        app.buttons["History"].tap()
        let history = app.navigationBars["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("unsaved search")
        app.buttons["Filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 5))
        assertKeyboardHidden(app)
        app.buttons["More filters"].tap()
        let minimum = app.textFields["Minimum amount"]
        XCTAssertTrue(minimum.waitForExistence(timeout: 5))
        minimum.tap()
        minimum.typeText("200")
        tapOutsideInput(app.navigationBars["Filters"], app: app)
        assertKeyboardHidden(app)
        app.navigationBars["Filters"].buttons["Cancel"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "unsaved search")
        assertKeyboardHidden(app)
        history.buttons["Close"].tap()
        app.buttons["Options"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        app.buttons["New Category"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Unsaved UI category")
        tapOutsideInput(app.navigationBars["New Category"], app: app)
        assertKeyboardHidden(app)
        app.navigationBars["New Category"].buttons["Cancel"].tap()
    }

    func testChatDraftSurvivesKeyboardDismissalAndPrivacySheetWhenAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Chat"].tap()
        let question = app.textFields["Spending question"]
        guard question.waitForExistence(timeout: 5) else {
            throw XCTSkip("Chat provider is unavailable on this disposable simulator; do not configure an online provider for this test.")
        }
        question.tap()
        question.typeText("Unsaved keyboard draft")
        tapOutsideInput(app.navigationBars["Chat"], app: app)
        assertKeyboardHidden(app)
        question.tap()
        app.buttons["Chat Options"].tap()
        app.buttons["Privacy"].tap()
        assertKeyboardHidden(app)
        // No Send tap: this check never asks the AI provider to process a question.
        app.navigationBars["Chat Privacy"].buttons["Close"].tap()
        XCTAssertEqual(question.value as? String, "Unsaved keyboard draft")
        assertKeyboardHidden(app)
    }

    private func tapOutsideInput(_ header: XCUIElement, app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertKeyboardHidden(app, file: file, line: line)
    }

    private func assertKeyboardHidden(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, file: file, line: line)
    }

    private func pasteFromEditMenu(_ input: XCUIElement, app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        input.doubleTap()
        let menuItem = app.menuItems["Paste"].firstMatch
        if menuItem.waitForExistence(timeout: 2) { menuItem.tap() }
        else {
            let paste = app.buttons["Paste"].firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5), "Native edit menu must offer Paste. \(app.debugDescription)", file: file, line: line)
            paste.tap()
        }
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
    }

    private func assertLayout(app: XCUIApplication, header: XCUIElement, action: XCUIElement, keyboard: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(header.exists && header.isHittable, "Header must remain visible and reachable.", file: file, line: line)
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Bottom action must exist.", file: file, line: line)
        let headerFrame = header.frame
        let actionFrame = action.frame
        XCTAssertGreaterThan(headerFrame.height, 0, file: file, line: line)
        XCTAssertGreaterThan(actionFrame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actionFrame.minY, headerFrame.maxY, "Header and action cannot overlap.", file: file, line: line)
        XCTAssertTrue(app.frame.contains(actionFrame), "Action must stay inside the offered app frame.", file: file, line: line)
        if keyboard {
            let keyboardFrame = app.keyboards.firstMatch.frame
            XCTAssertLessThanOrEqual(actionFrame.maxY, keyboardFrame.minY + 2, "Bottom action must sit above the keyboard, not beneath it.", file: file, line: line)
        }
        if action.isEnabled { XCTAssertTrue(action.isHittable, "Enabled action must be reachable.", file: file, line: line) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        // Keep local visual evidence even when the build wrapper cleans its result bundle.
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ExpensoUILayout-\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
