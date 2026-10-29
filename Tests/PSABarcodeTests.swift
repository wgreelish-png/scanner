import XCTest
@testable import CardShowScanner

final class PSABarcodeTests: XCTestCase {
    func testPSAHTTPSCertificateLinksPreserveTheIdentifierAndSource() {
        for url in ["https://www.psacard.com/cert/00123456", "https://psacard.com/cert/00123456/", "https://www.psacard.com:443/cert/00123456"] {
            let code = PSACertificateCode.parse(url, kind: .qr)
            XCTAssertEqual(code?.certificateNumber, "00123456")
            XCTAssertEqual(code?.source, .psaQR)
        }
    }
    func testNumericLinearCodesAndExplicitManualEntryAreCandidatesOnly() {
        let code = PSACertificateCode.parse("00123456", kind: .code128)
        XCTAssertEqual(code?.certificateNumber, "00123456"); XCTAssertEqual(code?.source, .code128)
        let manual = PSACertificateCode.parse(" \n00123456 \t", kind: .manual)
        XCTAssertEqual(manual?.certificateNumber, "00123456"); XCTAssertEqual(manual?.source, .manual)
        XCTAssertNil(PSACertificateCode.parse("00123456", kind: .qr), "An arbitrary QR number is not an identified PSA certificate link")
    }
    func testNumericCandidateBoundariesRejectLettersNumbersWithFormattingAndUnicodeDigits() {
        for count in [6, 8, 10, 12] {
            XCTAssertNotNil(PSACertificateCode.parse(String(repeating: "0", count: count), kind: .manual))
        }
        for value in ["", "12345", "1234567890123", "1234 5678", "1234\n5678", "+12345678", "12345678.0", "1.2345678e7", "１２３４５６７８", "١٢٣٤٥٦٧٨", "ABC123456", "12345678\u{0000}"] {
            XCTAssertNil(PSACertificateCode.parse(value, kind: .manual), value)
            XCTAssertNil(PSACertificateCode.parse(value, kind: .code128), value)
        }
        XCTAssertNil(PSACertificateCode.parse(" 12345678", kind: .code128))
        XCTAssertNil(PSACertificateCode.parse("12345678\n", kind: .code128))
    }
    func testQRURLsRejectOtherHostsCredentialsUnsafePortsQueriesAndFragments() {
        for value in [
            "http://www.psacard.com/cert/12345678", "https://psacard.com.evil.example/cert/12345678",
            "https://evil.example/cert/12345678", "https://psacard.com@evil.example/cert/12345678",
            "https://user:secret@www.psacard.com/cert/12345678", "https://www.psacard.com:444/cert/12345678",
            "https://www.psacard.com/cert/12345678?next=https://evil.example", "https://www.psacard.com/cert/12345678#details",
            "https://www.psacard.com/cert/12345678?", "https://www.psacard.com/cert/12345678#",
            "https://www.psacard.com/cert/12345678\n", "https://www.psacard.com/cert/12345678\u{0000}"
        ] { XCTAssertNil(PSACertificateCode.parse(value, kind: .qr), value) }
    }
    func testQRPathsAreExactAndDoNotDecodeHiddenOrExtraPathComponents() {
        for path in ["/CERT/12345678", "//cert/12345678", "/cert//12345678", "/cert/12345678/extra", "/cert/12345678/psa",
                     "/cert/../12345678", "/cert/%31%32%33%34%35%36%37%38", "/cert%2f12345678", "/cert/12345", "/cert/1234567890123", "/cert/12345678//"] {
            XCTAssertNil(PSACertificateCode.parse("https://www.psacard.com" + path, kind: .qr), path)
        }
    }
    func testOversizedPayloadsAreRejectedBeforeURLParsing() {
        let value = String(repeating: "1", count: 513)
        for kind in [PSABarcodeKind.manual, .code128, .qr] { XCTAssertNil(PSACertificateCode.parse(value, kind: kind)) }
    }
}
