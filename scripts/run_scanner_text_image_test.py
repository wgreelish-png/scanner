#!/usr/bin/env python3
"""Run the unchanged production Vision reader/parser on a privately supplied JPEG.

macOS-only diagnostic. No screenshot is added to the repository or test artifacts.
The catalog matcher is outside this test: it needs the user's saved game pack.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


DRIVER = r'''
import Foundation
import ImageIO
import CryptoKit

@main struct ImageTest {
    @MainActor
    static func inspect(_ data: Data, label: String) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let observations = try await ScannerTextRecognizer().recognize(data)
        let hints = ScannerTextHintParser.hints(from: observations)
        let target = hints.filter { $0.name.localizedCaseInsensitiveContains("Krookodile") }
        // Report only the card identity the user asked to test, never unrelated
        // screen text, complete observations, image bytes or other inventory.
        let titleLines = observations.filter { $0.text.localizedCaseInsensitiveContains("Krookodile") }
        let numberLines = observations.filter {
            $0.text.range(of: #"0?55\s*/\s*0?86"#, options: .regularExpression) != nil
        }
        return ["case": label, "observations": observations.count,
            "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
            "title_seen_by_ocr": !titleLines.isEmpty,
            "collector_seen_by_ocr": !numberLines.isEmpty,
            "target_title_lines": titleLines.map { ["text": $0.text, "confidence": Double($0.confidence)] },
            "target_collector_lines": numberLines.map { ["text": $0.text, "confidence": Double($0.confidence)] },
            "parsed_target_hints": target.map { ["name": $0.name, "number": $0.number] },
            "title_reaches_catalog_search": !target.isEmpty,
            "title_and_number_reach_catalog_search": target.contains {
                $0.number.replacingOccurrences(of: " ", with: "") == "055/086"
            }]
    }

    @MainActor
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var cases = [try await inspect(data, label: "original_screenshot")]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // Supplemental diagnostic only: remove the screenshot's native
            // header/footer. This is not a change to production preprocessing.
            let box = CGRect(x: 0, y: Double(image.height) * 150 / 1280,
                width: Double(image.width), height: Double(image.height) * 840 / 1280).integral
            if let crop = image.cropping(to: box) {
                let output = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, crop,
                        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    if CGImageDestinationFinalize(destination) {
                        cases.append(try await inspect(output as Data, label: "camera_area_crop_diagnostic_only"))
                    }
                }
            }
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let result: [String: Any] = ["engine": "production ScannerTextRecognizer + ScannerTextHintParser",
            "platform": "macOS Apple Vision; iPhone validation remains separate",
            "source_image_sha256": hash, "source_image_bytes": data.count,
            "catalog_lookup_executed": false, "cases": cases]
        let report = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print(String(decoding: report, as: UTF8.self))
    }
}
'''


def production_ocr_source(root):
    source = (root / "CardShowScanner/ScannerTextRecognition.swift").read_text()
    boundary = "struct ScannerTextCatalogMatcher: Sendable {"
    if source.count(boundary) != 1:
        raise ValueError("Production OCR boundary changed; review the image test harness")
    # Compile the actual recognizer and parser verbatim, not a Python/JS port or
    # supplied OCR text. Only the catalog-dependent component is omitted.
    return source.split(boundary, 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    work = Path(os.environ.get("IMAGE_WORK_DIRECTORY", args.image.parent))
    work.mkdir(parents=True, exist_ok=True)
    report = work / "report.json"
    if not 0 < args.image.stat().st_size <= 2_000_000:
        raise ValueError("Image is outside the production byte bound")
    with tempfile.TemporaryDirectory(prefix="scanner-text-image-") as temp:
        temp = Path(temp)
        source, driver, executable = temp / "ProductionOCR.swift", temp / "ImageTest.swift", temp / "image-test"
        source.write_text(production_ocr_source(root))
        driver.write_text(DRIVER)
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(source), str(driver),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(args.image.resolve()), str(report.resolve())], check=True, timeout=60)
    result = json.loads(report.read_text())
    if not result.get("cases"):
        raise ValueError("The actual image was not processed")


if __name__ == "__main__":
    main()
