import CoreGraphics
import Foundation
import XCTest

final class OCRWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOCRWordCorrectionAndNoteSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // A unique value prevents an excerpt from an earlier run satisfying the check.
        let runMarker = String(UUID().uuidString.prefix(8))
        let excerptText = "UI OCR excerpt \(runMarker)"
        let noteText = "UI OCR note \(runMarker)"
        app.launch()

        let fileMenu = app.buttons["reader.fileMenu"]
        waitUntilReady(fileMenu)
        fileMenu.tap()
        let sample = app.buttons["reader.openSample"]
        waitUntilReady(sample)
        sample.tap()

        let recognize = app.buttons["ocr.recognizePage"]
        waitUntilReady(recognize)
        recognize.tap()
        let textList = app.descendants(matching: .any)
            .matching(identifier: "ocr.selection.textList").firstMatch
        XCTAssertTrue(textList.waitForExistence(timeout: 60),
                      "The real OCR result list did not appear for the bundled F2 sample.")

        let word = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label ==[c] %@", "ocr.region.", "read"
        )).firstMatch
        var foundWord = false
        for attempt in 0...8 {
            if word.exists && word.isHittable {
                foundWord = true
                break
            }
            if attempt < 8 { textList.swipeUp() }
        }
        guard foundWord else {
            attachScreenshot(app, name: "OCR-region-not-found")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "F2-OCR-accessibility-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("No selectable 'read' OCR region after at most eight list scrolls.")
            return
        }
        word.tap()
        attachScreenshot(app, name: "01-selected-real-OCR-region")

        let review = app.buttons["ocr.selection.review"]
        waitUntilReady(review)
        review.tap()
        let corrected = app.textViews["ocr.review.text"]
        waitUntilReady(corrected)
        let originalText = try XCTUnwrap(corrected.value as? String)
        XCTAssertEqual(originalText.lowercased(), "read",
                       "Selecting a word must not silently include the entire OCR line.")
        let sourceAttachment = XCTAttachment(string: originalText)
        sourceAttachment.name = "F2-selected-OCR-source-text"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)
        replaceSingleLineText(in: corrected, with: excerptText)
        attachScreenshot(app, name: "02-corrected-OCR-text")

        let confirm = app.buttons["ocr.review.confirm"]
        waitUntilReady(confirm)
        confirm.tap()
        let note = app.textViews["note.editor.text"]
        waitUntilReady(note)
        replaceSingleLineText(in: note, with: noteText)
        attachScreenshot(app, name: "03-excerpt-and-note-before-save")
        let save = app.buttons["note.editor.save"]
        waitUntilReady(save)
        save.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !note.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed,
                       "The note editor did not dismiss after saving.")
        attachScreenshot(app, name: "04-reader-after-save")

        app.terminate()
        app.launch()
        let excerpts = app.buttons["reader.excerpts"]
        waitUntilReady(excerpts)
        excerpts.tap()
        let storedEntry = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", excerptText, noteText
        )).firstMatch
        XCTAssertTrue(storedEntry.waitForExistence(timeout: 15),
                      "The corrected excerpt and its note were not restored in the same list entry.")
        attachScreenshot(app, name: "05-restored-excerpt-list")

        waitUntilReady(storedEntry)
        storedEntry.tap()
        let restoredNote = app.textViews["note.editor.text"]
        waitUntilReady(restoredNote)
        XCTAssertEqual(restoredNote.value as? String, noteText)
        XCTAssertTrue(app.staticTexts[excerptText].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", originalText
        )).firstMatch.waitForExistence(timeout: 15),
                      "The preserved original OCR text was not shown when reopening the excerpt.")
        attachScreenshot(app, name: "06-restored-excerpt-note-and-source")
    }

    @MainActor
    private func waitUntilReady(_ element: XCUIElement, timeout: TimeInterval = 15,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required control did not appear: \(element)", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isEnabled && element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "Required control was not ready: \(element)", file: file, line: line)
    }

    @MainActor
    private func replaceSingleLineText(in editor: XCUIElement, with replacement: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        // This case edits only the one-word selection and an initially empty note.
        let current = editor.value as? String ?? ""
        XCTAssertFalse(current.contains("\n"), file: file, line: line)
        editor.tap()
        // Tapping below the sole line places the insertion point at its end.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
        if !current.isEmpty {
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                   count: current.count))
        }
        editor.typeText(replacement)
        XCTAssertEqual(editor.value as? String, replacement,
                       "Text replacement did not produce the requested value.", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
