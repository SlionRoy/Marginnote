import CoreGraphics
import Foundation
import XCTest

final class OCRWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            // Capture the screen independently of an app accessibility query.
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "failure-entire-screen"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testImmersiveReadingControls() throws {
        // This standard simulator case assumes VoiceOver is off. The accessible
        // always-visible exit variant needs a separate accessibility session.
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let fileMenu = app.buttons["reader.fileMenu"]
        let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fileMenu.exists && fileMenu.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 15), .completed)
        fileMenu.tap()
        let sample = app.buttons["reader.openSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        sample.tap()

        let pdf = app.descendants(matching: .any)
            .matching(identifier: "reader.pdfView").firstMatch
        let enter = app.buttons["reader.enterFullscreen"]
        let exit = app.buttons["reader.exitFullscreen"]
        let navigationBar = app.navigationBars.firstMatch
        let readerReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pdf.exists && pdf.frame.height > 0 && enter.exists && enter.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readerReady], timeout: 15), .completed,
                       "The bundled scan must open before testing reading controls.")
        let windowFrame = app.windows.firstMatch.frame
        let regularFrame = pdf.frame
        XCTAssertGreaterThan(windowFrame.height, 480)
        XCTAssertTrue(navigationBar.exists)
        XCTAssertFalse(exit.exists)
        attachScreenshot(app, name: "fullscreen-00-normal-reader")

        enter.tap()
        let fullscreenReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard pdf.exists else { return false }
            let frame = pdf.frame
            return !navigationBar.exists && !enter.exists && !fileMenu.exists
                && abs(frame.minX - windowFrame.minX) <= 4
                && abs(frame.maxX - windowFrame.maxX) <= 4
                && abs(frame.minY - windowFrame.minY) <= 4
                && abs(frame.maxY - windowFrame.maxY) <= 4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fullscreenReady], timeout: 10), .completed,
                       "Fullscreen must hide navigation and extend the PDF to the window edges.")
        let fullscreenFrame = pdf.frame
        XCTAssertGreaterThan(fullscreenFrame.height, regularFrame.height + 20,
                             "Hiding toolbar labels alone must not count as expanding the reader.")
        XCTAssertFalse(exit.exists, "Entering fullscreen should initially leave the page unobstructed.")
        attachScreenshot(app, name: "fullscreen-01-page-fills-window")

        let firstTapTime = ProcessInfo.processInfo.systemUptime
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3),
                      "One PDF tap must reveal the exit control.")
        attachScreenshot(app, name: "fullscreen-02-exit-control-visible")
        // Poll one existence query, without repeatedly asking for hittability.
        // The timer starts in the app; this upper bound allows UI observation lag.
        let automaticallyHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !exit.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [automaticallyHidden], timeout: 8), .completed,
                       "The exit control should disappear automatically after about five seconds.")
        let hideObservedAfterTap = ProcessInfo.processInfo.systemUptime - firstTapTime
        XCTAssertGreaterThanOrEqual(hideObservedAfterTap, 4,
                                    "The control must not vanish immediately after it appears.")
        XCTAssertFalse(enter.exists, "Auto-hiding the exit control must keep fullscreen active.")
        attachScreenshot(app, name: "fullscreen-03-controls-auto-hidden")

        // Reveal a fresh control and use it immediately; screenshots or repeated
        // readiness checks must not consume the next five-second visibility window.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 3))
        exit.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard pdf.exists else { return false }
            return navigationBar.exists && fileMenu.exists && enter.exists
                && app.buttons["ocr.recognizePage"].exists && !exit.exists
                && abs(pdf.frame.height - regularFrame.height) <= 4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed,
                       "Exiting fullscreen must restore the reading toolbar and normal PDF viewport.")
        attachScreenshot(app, name: "fullscreen-04-toolbar-restored")

        let frames = XCTAttachment(string: """
            Window: \(windowFrame)
            Regular PDF: \(regularFrame)
            Fullscreen PDF: \(fullscreenFrame)
            Restored PDF: \(pdf.frame)
            Automatic hide observed \(hideObservedAfterTap) seconds after the first tap began.
            """)
        frames.name = "fullscreen-viewport-and-control-timing"
        frames.lifetime = .keepAlways
        add(frames)
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
        var searchObservations: [String] = []
        var previousSearchPosition: String?
        var unchangedSearchPositions = 0
        let maximumSearchScrolls = 32
        for attempt in 0...maximumSearchScrolls {
            let regions = observedRegionButtons(in: app)
            let position = regionPositionSignature(regions)
            searchObservations.append(regionObservation(
                step: attempt, regions: regions, viewport: textList.frame))
            for region in regions {
                observedRegions[region.identifier] = region
            }
            wordRegions = exactRegionSequence(for: "read", among: Array(observedRegions.values))
            if wordRegions != nil { break }
            unchangedSearchPositions = position == previousSearchPosition
                ? unchangedSearchPositions + 1 : 0
            previousSearchPosition = position
            if unchangedSearchPositions >= 3 {
                searchObservations.append("Stopped: three consecutive drags did not change region IDs or positions.")
                break
            }
            if attempt < maximumSearchScrolls { scrollBySmallStep(textList, scrollingUp: true) }
        }
        attachScrollObservations(searchObservations, name: "F2-OCR-region-search-observations")
        guard let wordRegions else {
            attachScreenshot(app, name: "OCR-region-not-found")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "F2-OCR-accessibility-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("No same-line consecutive region sequence exactly spelling 'read' within the bounded overlapping search.")
            return
        }

        // The first region may have scrolled just above the viewport while the last
        // one was discovered. Reveal it, then move forwards through the same sequence.
        // Every reveal drag uses the same overlapping, slow movement as the search.
        var revealScrollsRemaining = 24
        var revealObservations: [String] = []
        for region in wordRegions {
            let button = app.buttons[region.identifier]
            var previousRevealPosition: String?
            var unchangedRevealPositions = 0
            while !(button.exists && button.isHittable) && revealScrollsRemaining > 0 {
                let viewport = textList.frame
                let regions = observedRegionButtons(in: app)
                let position = regionPositionSignature(regions)
                revealObservations.append("Target: \(region.identifier)\n" + regionObservation(
                    step: 24 - revealScrollsRemaining, regions: regions, viewport: viewport))
                unchangedRevealPositions = position == previousRevealPosition
                    ? unchangedRevealPositions + 1 : 0
                previousRevealPosition = position
                if unchangedRevealPositions >= 3 {
                    revealObservations.append("Stopped: three reveal drags did not change region IDs or positions.")
                    break
                }
                let visible = regions.filter { $0.frame.intersects(viewport) }
                let firstVisible = visible.min(by: regionComesBefore)
                let scrollingUp: Bool
                if let current = regions.first(where: { $0.identifier == region.identifier }) {
                    scrollingUp = current.frame.midY >= viewport.midY
                } else if let firstVisible {
                    scrollingUp = !regionComesBefore(region, firstVisible)
                } else {
                    scrollingUp = true
                }
                scrollBySmallStep(textList, scrollingUp: scrollingUp)
                revealScrollsRemaining -= 1
            }
            guard button.exists && button.isHittable else {
                attachScrollObservations(revealObservations, name: "F2-OCR-region-reveal-observations")
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
        attachScrollObservations(revealObservations, name: "F2-OCR-region-reveal-observations")
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
        let restoredForm = app.descendants(matching: .any)
            .matching(identifier: "note.editor.form").firstMatch
        let restoredNote = app.textViews["note.editor.text"]
        reveal(restoredNote, in: restoredForm, scrollingUp: true)
        attachScreenshot(app, name: "06-reopened-editor-before-content-checks")
        // reveal has already checked existence and hittability. Verify actual
        // contents and editing instead of repeating the readiness query.
        XCTAssertEqual(restoredNote.value as? String, noteText)
        let preservedOriginal = app.staticTexts["note.editor.originalOCR"]
        reveal(preservedOriginal, in: restoredForm, scrollingUp: false)
        XCTAssertEqual(preservedOriginal.label.lowercased(), originalText.lowercased())
        let restoredExcerpt = app.staticTexts["note.editor.excerpt"]
        reveal(restoredExcerpt, in: restoredForm, scrollingUp: false)
        XCTAssertEqual(restoredExcerpt.label, excerptText)
        attachScreenshot(app, name: "07-restored-excerpt-note-and-source")

        let updatedNoteText = "Updated note \(runMarker)"
        reveal(restoredNote, in: restoredForm, scrollingUp: true)
        replaceSingleLineText(in: restoredNote, with: updatedNoteText)
        let updateSave = app.buttons["note.editor.save"]
        waitUntilReady(updateSave)
        updateSave.tap()
        let updateDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !restoredNote.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updateDismissed], timeout: 15), .completed)
        app.terminate()
        app.launch()
        let updatedExcerpts = app.buttons["reader.excerpts"]
        waitUntilReady(updatedExcerpts)
        updatedExcerpts.tap()
        let updatedEntry = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", excerptText, updatedNoteText
        )).firstMatch
        XCTAssertTrue(updatedEntry.waitForExistence(timeout: 15),
                      "Editing a reopened note must persist without changing the excerpt.")
        attachScreenshot(app, name: "08-updated-note-after-second-relaunch")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement,
                        scrollingUp: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15), file: file, line: line)
        var observations: [String] = []
        defer {
            if !observations.isEmpty {
                attachScrollObservations(observations,
                    name: scrollingUp ? "form-reveal-forward" : "form-reveal-backward")
            }
        }
        var previousPosition: String?
        var unchangedPositions = 0
        for attempt in 0..<24 {
            if element.exists && element.isHittable { return }
            let cells = scrollView.cells.allElementsBoundByIndex.prefix(32)
            let position = cells.map { cell in
                "\(cell.identifier):\(String(format: "%.0f", cell.frame.minY)):\(cell.label)"
            }.joined(separator: "\n")
            observations.append("Step \(attempt), viewport \(scrollView.frame)\n\(position)")
            // An empty lazy snapshot cannot establish that scrolling stopped.
            if !position.isEmpty {
                unchangedPositions = position == previousPosition ? unchangedPositions + 1 : 0
                previousPosition = position
                if unchangedPositions >= 3 {
                    observations.append("Stopped: three form drags did not change cell positions.")
                    break
                }
            }
            scrollBySmallStep(scrollView, scrollingUp: scrollingUp)
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "Required form field could not be revealed by scrolling.", file: file, line: line)
    }

    private struct ObservedRegion {
        let identifier: String
        let lineIndex: Int
        let regionIndex: Int
        let text: String
        let frame: CGRect
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
                                      regionIndex: regionIndex, text: text, frame: button.frame)
            }
    }

    @MainActor
    private func scrollBySmallStep(_ scrollView: XCUIElement, scrollingUp: Bool) {
        let viewport = scrollView.frame
        guard viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 40, viewport.height > 40 else {
            XCTFail("Cannot scroll an invalid or collapsed observed viewport: \(viewport)")
            return
        }
        // Limit the drag to 25% of the observed viewport, capped at 96 points,
        // to retain overlap. A stationary final hold reduces flick momentum;
        // the next observation records the actual resulting row positions.
        let distance = min(viewport.height * 0.25, 96)
        let middleY = viewport.height * 0.5
        let direction: CGFloat = scrollingUp ? 1 : -1
        let origin = scrollView.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.width * 0.5,
                                               dy: middleY + direction * distance * 0.5))
        let end = origin.withOffset(CGVector(dx: viewport.width * 0.5,
                                             dy: middleY - direction * distance * 0.5))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 100), thenHoldForDuration: 0.25)
    }

    private func regionPositionSignature(_ regions: [ObservedRegion]) -> String {
        regions.sorted(by: regionComesBefore).map {
            "\($0.identifier):\(String(format: "%.0f", $0.frame.minY)):\($0.text)"
        }.joined(separator: "\n")
    }

    private func regionObservation(step: Int, regions: [ObservedRegion], viewport: CGRect) -> String {
        let rows = regions.sorted(by: regionComesBefore).map {
            "\($0.identifier) text=\(String(reflecting: $0.text)) frame=\($0.frame)"
        }.joined(separator: "\n")
        return "Step \(step), observed viewport \(viewport)\n\(rows.isEmpty ? "<no regions>" : rows)"
    }

    private func attachScrollObservations(_ observations: [String], name: String) {
        let attachment = XCTAttachment(string: observations.joined(separator: "\n\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
