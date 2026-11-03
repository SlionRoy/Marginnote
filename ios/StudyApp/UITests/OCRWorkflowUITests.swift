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
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let fileMenu = app.buttons["reader.fileMenu"]
        waitUntilReady(fileMenu)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, 480,
                             "The app must use the modern iPhone viewport, not 320x480 compatibility mode.")
        attachScreenshot(app, name: "00-reader-viewport")
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

        // Vision can represent the same word as one region or several real regions.
        // Cache identifiers/labels across lazy-list scrolls; never split a region's label.
        var observedRegions: [String: ObservedRegion] = [:]
        var wordRegions: [ObservedRegion]?
        for attempt in 0...8 {
            for region in observedRegionButtons(in: app) {
                observedRegions[region.identifier] = region
            }
            wordRegions = exactRegionSequence(for: "read", among: Array(observedRegions.values))
            if wordRegions != nil { break }
            if attempt < 8 { textList.swipeUp() }
        }
        guard let wordRegions else {
            attachScreenshot(app, name: "OCR-region-not-found")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "F2-OCR-accessibility-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("No same-line consecutive region sequence exactly spelling 'read' after eight search scrolls.")
            return
        }

        // The first region may have scrolled just above the viewport while the last
        // one was discovered. Reveal it, then move forwards through the same sequence.
        // Eight additional reveal scrolls bound the entire selection phase.
        var revealScrollsRemaining = 8
        for (position, region) in wordRegions.enumerated() {
            let button = app.buttons[region.identifier]
            while !(button.exists && button.isHittable) && revealScrollsRemaining > 0 {
                let visible = observedRegionButtons(in: app).filter {
                    app.buttons[$0.identifier].isHittable
                }
                let firstVisible = visible.min(by: regionComesBefore)
                if position == 0, let firstVisible, regionComesBefore(region, firstVisible) {
                    textList.swipeDown()
                } else {
                    textList.swipeUp()
                }
                revealScrollsRemaining -= 1
            }
            guard button.exists && button.isHittable else {
                attachScreenshot(app, name: "OCR-region-could-not-be-revealed")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "F2-OCR-region-reveal-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                XCTFail("Could not reveal real OCR region \(region.identifier) within the scroll bound.")
                return
            }
            XCTAssertEqual(button.label, region.text,
                           "The cached OCR region changed before selection.")
            button.tap()
        }
        let regionAttachment = XCTAttachment(string: wordRegions.map {
            "\($0.identifier): \($0.text)"
        }.joined(separator: "\n"))
        regionAttachment.name = "F2-selected-real-OCR-regions"
        regionAttachment.lifetime = .keepAlways
        add(regionAttachment)
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
        let noteForm = app.descendants(matching: .any)
            .matching(identifier: "note.editor.form").firstMatch
        reveal(note, in: noteForm, scrollingUp: true)
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
        reveal(restoredNote, in: noteForm, scrollingUp: true)
        waitUntilReady(restoredNote)
        XCTAssertEqual(restoredNote.value as? String, noteText)
        let preservedOriginal = app.staticTexts["note.editor.originalOCR"]
        reveal(preservedOriginal, in: noteForm, scrollingUp: false)
        XCTAssertEqual(preservedOriginal.label.lowercased(), originalText.lowercased())
        let restoredExcerpt = app.staticTexts["note.editor.excerpt"]
        reveal(restoredExcerpt, in: noteForm, scrollingUp: false)
        XCTAssertEqual(restoredExcerpt.label, excerptText)
        attachScreenshot(app, name: "06-restored-excerpt-note-and-source")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement,
                        scrollingUp: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15), file: file, line: line)
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            if scrollingUp { scrollView.swipeUp() } else { scrollView.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "Required form field could not be revealed by scrolling.", file: file, line: line)
    }

    private struct ObservedRegion {
        let identifier: String
        let lineIndex: Int
        let regionIndex: Int
        let text: String
    }

    @MainActor
    private func observedRegionButtons(in app: XCUIApplication) -> [ObservedRegion] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ocr.region."))
            .allElementsBoundByIndex.compactMap { button in
                let identifier = button.identifier
                let components = identifier.split(separator: ".")
                guard components.count == 4,
                      let lineIndex = Int(components[2]), lineIndex >= 0,
                      let regionIndex = Int(components[3]), regionIndex >= 0 else { return nil }
                let text = button.label
                guard !text.isEmpty else { return nil }
                return ObservedRegion(identifier: identifier, lineIndex: lineIndex,
                                      regionIndex: regionIndex, text: text)
            }
    }

    private func regionComesBefore(_ lhs: ObservedRegion, _ rhs: ObservedRegion) -> Bool {
        lhs.lineIndex == rhs.lineIndex
            ? lhs.regionIndex < rhs.regionIndex : lhs.lineIndex < rhs.lineIndex
    }

    private func exactRegionSequence(for word: String,
                                     among observed: [ObservedRegion]) -> [ObservedRegion]? {
        let ordered = observed.sorted(by: regionComesBefore)
        if let wholeWord = ordered.first(where: { $0.text.lowercased() == word.lowercased() }) {
            return [wholeWord]
        }
        let target = word.lowercased()
        for start in ordered.indices {
            let first = ordered[start]
            var sequence: [ObservedRegion] = []
            var text = ""
            for region in ordered[start...] {
                guard region.lineIndex == first.lineIndex,
                      region.regionIndex == first.regionIndex + sequence.count else { break }
                text += region.text.lowercased()
                guard target.hasPrefix(text) else { break }
                sequence.append(region)
                if text == target { return sequence }
            }
        }
        return nil
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
