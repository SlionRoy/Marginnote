import CoreGraphics
import Foundation
import XCTest
@testable import StudyReader

/// Independent PDF streams exercise the actual Core Graphics scanner, including
/// matrix order and object hierarchy. They do not contain third-party artwork.
final class PDFGraphicScannerTests: XCTestCase {
    func testImageTransformOrderAndNonzeroCropOrigin() throws {
        let pdf = try document(
            contents: "q 1 0 0 1 100 150 cm 120 0 0 80 0 0 cm /Im Do Q",
            resources: "/XObject << /Im 5 0 R >>", objects: [image],
            crop: "50 100 550 700")
        let regions = PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(regions.count, 1)
        let rect = try XCTUnwrap(regions.first)
        XCTAssertEqual(rect.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 470.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 0.24, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 80.0 / 600, accuracy: 0.0001)
    }

    func testNestedGraphicFormKeepsParentAndInternalLabel() throws {
        let outer = stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] " +
            "/Matrix [1 0 0 1 10 20] /Resources << /XObject << /Inner 6 0 R >> " +
            "/Font << /F1 8 0 R >> >>",
            "q 1 0 0 1 10 10 cm /Inner Do Q BT /F1 10 Tf 5 85 Td (Figure label) Tj ET")
        let inner = stream("/Type /XObject /Subtype /Form /BBox [0 0 60 40] " +
            "/Resources << /XObject << /Im 7 0 R >> >>", "q 60 0 0 40 0 0 cm /Im Do Q")
        let pdf = try document(contents: "q 2 0 0 2 100 150 cm /Outer Do Q",
            resources: "/XObject << /Outer 5 0 R >>", objects: [outer, inner, image, font])
        let regions = PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(regions.count, 1)
        let rect = try XCTUnwrap(regions.first)
        XCTAssertEqual(rect.minX, 120.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 410.0 / 800, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 200.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 0.25, accuracy: 0.0001)
        // The parent includes the label at x=5,y=85, outside the nested image.
        XCTAssertTrue(rect.contains(CGPoint(x: 140.0 / 600, y: 430.0 / 800)))
    }

    func testTextOnlyAndWhiteBackgroundFormsAreNotFigures() throws {
        let text = stream("/Type /XObject /Subtype /Form /BBox [50 100 550 650] " +
            "/Resources << /Font << /F1 6 0 R >> >>",
            "1 g 50 100 500 550 re f 80 150 120 80 re f 80 300 120 80 re f " +
            "0 g BT /F1 12 Tf 80 600 Td (Body text inside a form) Tj ET")
        let pdf = try document(contents: "/F Do", resources: "/XObject << /F 5 0 R >>",
                               objects: [text, font])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    func testWholePageScanIsNotAnIntactFigureCandidate() throws {
        let pdf = try document(contents: "q 600 0 0 800 0 0 cm /Im Do Q",
                               resources: "/XObject << /Im 5 0 R >>", objects: [image])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    func testFullPageWrapperKeepsNestedFigureOnly() throws {
        let wrapper = stream("/Type /XObject /Subtype /Form /BBox [0 0 600 800] " +
            "/Resources << /XObject << /Im 6 0 R >> >>", "q 250 0 0 200 80 300 cm /Im Do Q")
        let pdf = try document(contents: "/PageForm Do", resources: "/XObject << /PageForm 5 0 R >>",
                               objects: [wrapper, image])
        let rect = try XCTUnwrap(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).first)
        XCTAssertEqual(rect.minX, 80.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 300.0 / 800, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 250.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 0.25, accuracy: 0.0001)
    }

    func testRectangularClipAndSavedGraphicsState() throws {
        let pdf = try document(contents:
            "q 100 200 120 100 re W n 240 0 0 200 100 200 cm /Im Do Q " +
            "q 100 0 0 80 400 600 cm /Im Do Q",
            resources: "/XObject << /Im 5 0 R >>", objects: [image])
        let regions = PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(regions.count, 2)
        let clipped = try XCTUnwrap(regions.first { $0.minX < 0.5 })
        XCTAssertEqual(clipped.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(clipped.height, 0.125, accuracy: 0.0001)
        XCTAssertNotNil(regions.first { $0.minX > 0.6 })
    }

    func testRecursiveFormTerminatesWithoutInventingRegion() throws {
        let cycle = stream("/Type /XObject /Subtype /Form /BBox [50 100 400 600] " +
            "/Resources << /XObject << /Self 5 0 R >> >>", "/Self Do")
        let pdf = try document(contents: "/Self Do", resources: "/XObject << /Self 5 0 R >>",
                               objects: [cycle])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    func testVectorFormPreservesInternalLabel() throws {
        let diagram = stream("/Type /XObject /Subtype /Form /BBox [0 0 300 220] " +
            "/Resources << /Font << /F1 6 0 R >> >>",
            "0 g 20 20 60 60 re f 120 20 60 60 re f 220 20 60 60 re f " +
            "BT /F1 12 Tf 30 180 Td (Labels belong to the diagram) Tj ET")
        let pdf = try document(contents: "q 1 0 0 1 80 300 cm /F Do Q",
            resources: "/XObject << /F 5 0 R >>", objects: [diagram, font])
        let regions = PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(regions.count, 1)
        let rect = try XCTUnwrap(regions.first)
        XCTAssertEqual(rect.minY, 280.0 / 800, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 220.0 / 800, accuracy: 0.0001)
    }

    func testMalformedFormMatrixIsRejectedInsteadOfUsingIdentity() throws {
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 300 220] " +
            "/Matrix [1 0 0] /Resources << /XObject << /Im 6 0 R >> >>",
            "q 200 0 0 100 0 0 cm /Im Do Q")
        let pdf = try document(contents: "/F Do", resources: "/XObject << /F 5 0 R >>",
                               objects: [form, image])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    func testNonrectangularClipIsNotExpandedToItsBoundingBox() throws {
        let pdf = try document(contents:
            "q 100 200 m 200 400 l 300 200 l h W n 240 0 0 200 100 200 cm /Im Do Q",
            resources: "/XObject << /Im 5 0 R >>", objects: [image])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    func testOperatorBudgetDiscardsPartialResult() throws {
        let pdf = try document(contents:
            "q 200 0 0 150 100 300 cm /Im Do Q " + String(repeating: "q Q ", count: 15_100),
            resources: "/XObject << /Im 5 0 R >>", objects: [image])
        XCTAssertTrue(PDFGraphicScanner.figures(in: try XCTUnwrap(pdf.page(at: 1))).isEmpty)
    }

    private var image: String {
        stream("/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray " +
               "/BitsPerComponent 8 /Filter /ASCIIHexDecode", "00>")
    }

    private var font: String { "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" }

    private func stream(_ dictionary: String, _ content: String) -> String {
        "<< \(dictionary) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    private func document(contents: String, resources: String, objects: [String],
                          crop: String = "0 0 600 800") throws -> CGPDFDocument {
        let all = ["<< /Type /Catalog /Pages 2 0 R >>",
                   "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /CropBox [\(crop)] " +
                   "/Resources << \(resources) >> /Contents 4 0 R >>", stream("", contents)] + objects
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in all.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }
}
