import UIKit

@MainActor struct InventoryLabelBitmap {
    let raster: LabelRaster
    let previewImage: UIImage
}

/// Layout runs horizontally on the sticker, then rotates into the D110's
/// narrow-head feed orientation. The preview is decoded from the final bits.
@MainActor enum InventoryLabelRenderer {
    static func render(_ draft: InventoryLabelDraft) throws -> InventoryLabelBitmap {
        let raster = try renderRaster(draft)
        return InventoryLabelBitmap(raster: raster, previewImage: try image(raster: raster, paper: draft.paperSize))
    }

    /// Queue preparation needs only the exact printer bits. Preview decoding is
    /// reserved for screens that display an image, rather than every batch copy.
    static func renderRaster(_ draft: InventoryLabelDraft) throws -> LabelRaster {
        try draft.validate()
        guard let price = draft.priceText else { throw InventoryLabelFailure.invalidPrice }
        return try Self.raster(price: price, name: draft.cardName, number: draft.cardNumber,
            condition: draft.condition, style: draft.style, paper: draft.paperSize,
            isBulk: draft.isBulk, pricePosition: draft.pricePosition)
    }

    static func render(_ draft: CustomPriceTagDraft) throws -> InventoryLabelBitmap {
        let raster = try renderRaster(draft)
        return InventoryLabelBitmap(raster: raster, previewImage: try image(raster: raster, paper: draft.paperSize))
    }

    static func renderRaster(_ draft: CustomPriceTagDraft) throws -> LabelRaster {
        try draft.validate()
        return try Self.raster(price: draft.priceText, name: "", number: "", condition: "",
            style: .priceOnly, paper: draft.paperSize, isBulk: draft.isBulk, pricePosition: draft.pricePosition)
    }

    private static func raster(price: String, name cardName: String, number cardNumber: String, condition conditionText: String,
                               style: InventoryLabelStyle, paper: InventoryLabelSize, isBulk: Bool = false,
                               pricePosition: LabelPricePosition) throws -> LabelRaster {
        if let geometry = paper.geometry {
            return try adaptiveRaster(price: price, name: cardName, number: cardNumber, condition: conditionText,
                                      style: style, isBulk: isBulk, pricePosition: pricePosition, geometry: geometry)
        }
        let width = paper.feedDots, height = paper.headDots
        // Draw the branded vectors at four samples per printer dot, then use
        // area coverage for the final bit decision. Card details retain their
        // established native-dot rendering exactly.
        let samplesPerDot = style == .priceOnly ? 4 : 1
        let sampleWidth = width * samplesPerDot, sampleHeight = height * samplesPerDot
        guard let context = CGContext(data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
            bytesPerRow: sampleWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let storage = context.data else { throw InventoryLabelFailure.invalidRaster }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(sampleWidth), height: CGFloat(sampleHeight)))
        context.scaleBy(x: CGFloat(samplesPerDot), y: CGFloat(samplesPerDot))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let margin: CGFloat = 8, available = CGFloat(width) - margin * 2
        switch style {
        case .priceOnly:
            try drawBrandedPrice(price, isBulk: isBulk, width: width, height: height,
                                 pricePosition: pricePosition, context: context)
        case .cardDetails:
            let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
            let title = titleComponents(name: cardName, number: cardNumber)
            let line = fittedTitle(name: title.name, number: title.number, font: titleFont, width: available)
            drawCentered(line, font: titleFont, rect: CGRect(x: margin, y: 4, width: available, height: 24))
            let conditionFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
            let minimumPriceWidth = measured(price, font: .monospacedDigitSystemFont(ofSize: 14, weight: .bold))
            let condition = truncated(conditionText, font: conditionFont,
                width: max(0, min(66, available / 3, available - minimumPriceWidth - 9)))
            let conditionWidth = measured(condition, font: conditionFont)
            let gap: CGFloat = condition.isEmpty ? 0 : 9
            let font = try priceFont(price, maximum: 42, minimum: 14, width: available - conditionWidth - gap)
            let priceWidth = measured(price, font: font)
            let left = margin + max(0, (available - priceWidth - conditionWidth - gap) / 2)
            drawCentered(price, font: font, rect: CGRect(x: left, y: 31, width: priceWidth, height: 56))
            drawCentered(condition, font: conditionFont,
                rect: CGRect(x: left + priceWidth + gap, y: 31, width: conditionWidth, height: 56))
        }
        let grayscale = Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: UInt8.self), count: sampleWidth * sampleHeight))
        return try Self.raster(grayscale: grayscale, landscapeWidth: width, landscapeHeight: height,
                               samplesPerDot: samplesPerDot)
    }

    /// A detected roll supplies physical geometry, never finished artwork.
    /// Draw into one usable region so a queue copy still produces one design.
    private static func adaptiveRaster(price: String, name: String, number: String, condition: String,
                                       style: InventoryLabelStyle, isBulk: Bool,
                                       pricePosition: LabelPricePosition, geometry: LabelPrintGeometry) throws -> LabelRaster {
        let width = geometry.feedDots, height = geometry.headDots, samples = 4
        let area = geometry.printableArea
        guard (1...800).contains(width), height == 96,
              [area.x, area.y, area.width, area.height].allSatisfy({ $0.isFinite }) else {
            throw InventoryLabelFailure.invalidRaster
        }
        // Whole-dot containment prevents a partially covered printer dot from
        // crossing the supplied region or the physical print-head boundary.
        let left = ceil(max(0, area.x)), top = ceil(max(0, area.y))
        let right = floor(min(Double(width), area.x + area.width))
        let bottom = floor(min(Double(height), area.y + area.height))
        let bounds = CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(right - left), height: CGFloat(bottom - top))
        guard bounds.width >= 24, bounds.height >= 16,
              let context = CGContext(data: nil, width: width * samples, height: height * samples,
                bitsPerComponent: 8, bytesPerRow: width * samples, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue), let storage = context.data else {
            throw InventoryLabelFailure.invalidRaster
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width * samples), height: CGFloat(height * samples)))
        context.scaleBy(x: CGFloat(samples), y: CGFloat(samples))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.clip(to: bounds)
        context.translateBy(x: bounds.minX, y: bounds.minY)
        if geometry.contentRotation == 180 {
            context.translateBy(x: bounds.width, y: bounds.height)
            context.scaleBy(x: -1, y: -1)
        }
        switch style {
        case .priceOnly:
            try drawAdaptivePrice(price, isBulk: isBulk, size: bounds.size,
                                  pricePosition: pricePosition, context: context)
        case .cardDetails:
            try drawAdaptiveDetails(price: price, name: name, number: number, condition: condition, size: bounds.size)
        }
        let count = width * height * samples * samples
        let grayscale = Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: UInt8.self), count: count))
        return try Self.raster(grayscale: grayscale, landscapeWidth: width, landscapeHeight: height, samplesPerDot: samples)
    }

    static func adaptiveBrandedPriceLayout(width: CGFloat, height: CGFloat, price: String,
                                           pricePosition: LabelPricePosition) -> BrandedPriceLayout {
        let padding = max(2, min(6, height * 0.07))
        // Long prices may borrow room from the logo, keeping the entire amount
        // intact rather than cutting off digits on shorter decorative labels.
        let minimumPriceWidth = measured(price, font: .monospacedDigitSystemFont(ofSize: 6, weight: .bold))
        let priceWidth = max(width * 0.44, min(width * 0.66, minimumPriceWidth + padding * 3))
        let divider = floor(width - priceWidth)
        let logo = CGRect(x: padding * 1.5, y: padding * 2,
                          width: divider - padding * 3, height: height - padding * 4)
        let amount = CGRect(x: divider + padding, y: padding,
                            width: width - divider - padding * 2, height: height - padding * 2)
        guard pricePosition == .left else {
            return BrandedPriceLayout(dividerX: divider, logoArea: logo, priceArea: amount)
        }
        return BrandedPriceLayout(dividerX: width - divider,
            logoArea: CGRect(x: width - logo.maxX, y: logo.minY, width: logo.width, height: logo.height),
            priceArea: CGRect(x: width - amount.maxX, y: amount.minY, width: amount.width, height: amount.height))
    }

    private static func drawAdaptivePrice(_ price: String, isBulk: Bool, size: CGSize,
                                          pricePosition: LabelPricePosition, context: CGContext) throws {
        guard let page = labelBrandDocument?.page(at: 1) else { throw InventoryLabelFailure.invalidRaster }
        let pageBounds = page.getBoxRect(.mediaBox)
        let text = isBulk && size.width < 270 ? "2/$1" : price
        let layout = adaptiveBrandedPriceLayout(width: size.width, height: size.height, price: text, pricePosition: pricePosition)
        guard pageBounds.width > 0, pageBounds.height > 0,
              layout.logoArea.width > 0, layout.logoArea.height > 0 else { throw InventoryLabelFailure.invalidRaster }
        let padding = max(2, min(6, size.height * 0.07))
        context.saveGState()
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(max(1, min(2, size.height / 48)))
        let border = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: padding / 2, dy: padding / 2),
                                  cornerRadius: min(10, size.height / 8))
        context.addPath(border.cgPath)
        context.strokePath()
        context.move(to: CGPoint(x: layout.dividerX, y: padding * 2))
        context.addLine(to: CGPoint(x: layout.dividerX, y: size.height - padding * 2))
        context.strokePath()
        let scale = min(layout.logoArea.width / pageBounds.width, layout.logoArea.height / pageBounds.height)
        let logoSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        context.translateBy(x: layout.logoArea.midX - logoSize.width / 2, y: layout.logoArea.midY + logoSize.height / 2)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        context.drawPDFPage(page)
        context.restoreGState()
        let maximum: CGFloat = isBulk ? min(44, size.height * 0.6) : min(64, size.height * 0.75)
        let font = try fittedPriceFont(text, maximum: maximum, rect: layout.priceArea)
        drawCentered(text, font: font, rect: layout.priceArea)
    }

    private static func drawAdaptiveDetails(price: String, name: String, number: String,
                                            condition: String, size: CGSize) throws {
        let padding = max(2, min(6, size.height * 0.07)), available = size.width - padding * 2
        let titleRect = CGRect(x: padding, y: padding, width: available, height: size.height * 0.28)
        var titleSize = min(17, titleRect.height * 0.75)
        while UIFont.systemFont(ofSize: titleSize, weight: .semibold).lineHeight > titleRect.height && titleSize > 4 {
            titleSize -= 0.5
        }
        let titleFont = UIFont.systemFont(ofSize: titleSize, weight: .semibold)
        let title = titleComponents(name: name, number: number)
        drawCentered(fittedTitle(name: title.name, number: title.number, font: titleFont, width: available),
                     font: titleFont, rect: titleRect)
        let row = CGRect(x: padding, y: size.height * 0.36, width: available, height: size.height * 0.56)
        let conditionFont = UIFont.systemFont(ofSize: min(15, size.height * 0.18), weight: .semibold)
        let minimumPriceWidth = measured(price, font: .monospacedDigitSystemFont(ofSize: 5, weight: .bold))
        let conditionText = truncated(condition, font: conditionFont,
            width: max(0, min(available * 0.3, available - minimumPriceWidth - padding)))
        let conditionWidth = measured(conditionText, font: conditionFont)
        let gap = conditionText.isEmpty ? 0 : padding
        let priceArea = CGRect(x: row.minX, y: row.minY, width: row.width - conditionWidth - gap, height: row.height)
        let font = try fittedPriceFont(price, maximum: min(42, size.height * 0.54), rect: priceArea, minimum: 5)
        drawCentered(price, font: font, rect: priceArea)
        drawCentered(conditionText, font: conditionFont,
            rect: CGRect(x: priceArea.maxX + gap, y: row.minY, width: conditionWidth, height: row.height))
    }

    private static func fittedPriceFont(_ text: String, maximum: CGFloat, rect: CGRect, minimum: CGFloat = 6) throws -> UIFont {
        var size = floor(maximum * 2) / 2
        while size >= minimum {
            let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            if measured(text, font: font) <= rect.width && font.lineHeight <= rect.height { return font }
            size -= 0.5
        }
        throw InventoryLabelFailure.invalidPrice
    }

    struct BrandedPriceLayout {
        let dividerX: CGFloat
        let logoArea: CGRect
        let priceArea: CGRect
    }

    static func brandedPriceLayout(width: Int, height: Int, pricePosition: LabelPricePosition) -> BrandedPriceLayout {
        let dividerX = floor(CGFloat(width) * 0.56)
        let logoArea = CGRect(x: 12, y: 14, width: dividerX - 24, height: CGFloat(height) - 28)
        let priceArea = CGRect(x: dividerX + 8, y: 8, width: CGFloat(width) - dividerX - 18,
                               height: CGFloat(height) - 16)
        guard pricePosition == .left else {
            return BrandedPriceLayout(dividerX: dividerX, logoArea: logoArea, priceArea: priceArea)
        }
        // Reflect only the content boxes. Each block keeps its dimensions and
        // draws normally at its new origin, so letters and digits stay readable.
        return BrandedPriceLayout(dividerX: CGFloat(width) - dividerX,
            logoArea: CGRect(x: CGFloat(width) - logoArea.maxX, y: logoArea.minY,
                             width: logoArea.width, height: logoArea.height),
            priceArea: CGRect(x: CGFloat(width) - priceArea.maxX, y: priceArea.minY,
                              width: priceArea.width, height: priceArea.height))
    }

    private static func drawBrandedPrice(_ price: String, isBulk: Bool, width: Int, height: Int,
                                         pricePosition: LabelPricePosition,
                                         context: CGContext) throws {
        guard let page = labelBrandDocument?.page(at: 1) else { throw InventoryLabelFailure.invalidRaster }
        let bounds = page.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { throw InventoryLabelFailure.invalidRaster }
        let layout = brandedPriceLayout(width: width, height: height, pricePosition: pricePosition)
        let dividerX = layout.dividerX
        context.saveGState()
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(2)
        let border = UIBezierPath(roundedRect: CGRect(x: 4, y: 4,
            width: CGFloat(width) - 8, height: CGFloat(height) - 8), cornerRadius: 10)
        context.addPath(border.cgPath)
        context.strokePath()
        context.move(to: CGPoint(x: dividerX, y: 13))
        context.addLine(to: CGPoint(x: dividerX, y: CGFloat(height) - 13))
        context.strokePath()

        let logoArea = layout.logoArea
        let scale = min(logoArea.width / bounds.width, logoArea.height / bounds.height)
        let logoSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let logoRect = CGRect(x: logoArea.midX - logoSize.width / 2, y: logoArea.midY - logoSize.height / 2,
                              width: logoSize.width, height: logoSize.height)
        // PDF paths use a bottom-left origin; the label's drawing coordinates
        // use a top-left origin. Draw the outlined letters directly, preserving
        // vectors until the final printer-dot coverage calculation.
        context.translateBy(x: logoRect.minX, y: logoRect.maxY)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(page)
        context.restoreGState()

        let priceArea = layout.priceArea
        if isBulk {
            let deal = width == 240 ? "2/$1" : "2 FOR $1"
            let font = try priceFont(deal, maximum: width == 240 ? 44 : 32, minimum: 9, width: priceArea.width)
            drawCentered(deal, font: font, rect: priceArea)
        } else {
            // Normal show prices remain large. Very long valid amounts shrink
            // as a complete string, rather than clipping digits or currency.
            let font = try priceFont(price, maximum: 64, minimum: 9, width: priceArea.width)
            drawCentered(price, font: font, rect: priceArea)
        }
    }

    /// The supplied reference lettering is bundled as outlined vector paths,
    /// avoiding app-icon crops, bitmap enlargement and font substitution.
    private static let labelBrandDocument: CGPDFDocument? = {
        guard let data = NSDataAsset(name: "PokeDenWordmark")?.data,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }()

    static func bitmap(grayscale: [UInt8], landscapeWidth: Int, landscapeHeight: Int,
                       samplesPerDot: Int = 1) throws -> InventoryLabelBitmap {
        let raster = try Self.raster(grayscale: grayscale, landscapeWidth: landscapeWidth, landscapeHeight: landscapeHeight,
                                     samplesPerDot: samplesPerDot)
        return InventoryLabelBitmap(raster: raster, previewImage: try image(raster: raster))
    }

    private static func raster(grayscale: [UInt8], landscapeWidth: Int, landscapeHeight: Int,
                               samplesPerDot: Int = 1) throws -> LabelRaster {
        guard landscapeHeight == 96, (1...800).contains(landscapeWidth),
              [1, 4].contains(samplesPerDot),
              grayscale.count == landscapeWidth * landscapeHeight * samplesPerDot * samplesPerDot else {
            throw InventoryLabelFailure.invalidRaster
        }
        var packed = [UInt8](repeating: 0, count: landscapeWidth * 12)
        let sampleWidth = landscapeWidth * samplesPerDot
        let threshold = 128 * samplesPerDot * samplesPerDot
        for x in 0..<landscapeWidth {
            for y in 0..<landscapeHeight {
                var coverage = 0
                for sampleY in 0..<samplesPerDot {
                    let row = (y * samplesPerDot + sampleY) * sampleWidth + x * samplesPerDot
                    for sampleX in 0..<samplesPerDot { coverage += Int(grayscale[row + sampleX]) }
                }
                if coverage < threshold {
                    let head = landscapeHeight - 1 - y
                    packed[x * 12 + head / 8] |= 0x80 >> (head % 8)
                }
            }
        }
        let raster = LabelRaster(width: landscapeHeight, height: landscapeWidth, data: Data(packed))
        try raster.validate()
        return raster
    }

    /// Some catalog titles already end in their collector code. Remove only an
    /// exact, separately delimited copy for this sticker; saved names and numbers
    /// remain untouched. Plain name numbers need explicit metadata decoration.
    static func titleComponents(name: String, number: String) -> (name: String, number: String) {
        let name = InventoryLabelDraft.singleLine(name, maximumCharacters: 500)
        let number = InventoryLabelDraft.singleLine(number, maximumCharacters: 100)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#")))
        guard !number.isEmpty, number.rangeOfCharacter(from: .decimalDigits) != nil else { return (name, number) }

        let code = NSRegularExpression.escapedPattern(for: number)
        // A slash, dash, underscore or decimal can be part of a larger code;
        // letters/digits on either side likewise make a match incidental.
        let tokenCharacters = #"[\p{L}\p{N}_/\.\-]"#
        let endBoundary = "(?!" + tokenCharacters + ")"
        let wrapped = #"(?:\(\s*#?\s*"# + code + #"\s*\)|\[\s*#?\s*"# + code + #"\s*\])"#
        let hashtag = #"#\s*"# + code + endBoundary
        let structured = number.rangeOfCharacter(from: .letters.union(CharacterSet(charactersIn: "/-_."))) != nil
        let standalone = structured
            ? "(?<!" + tokenCharacters + ")" + code + endBoundary
            : #"\s+[-–—·|:]\s*"# + code + endBoundary + #"(?=\s*$)"#
        guard let expression = try? NSRegularExpression(pattern: wrapped + "|" + hashtag + "|" + standalone,
                                                         options: .caseInsensitive) else { return (name, number) }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        let matches = expression.matches(in: name, range: range)
        guard let first = matches.first, let last = matches.last,
              let firstRange = Range(first.range, in: name), let lastRange = Range(last.range, in: name) else { return (name, number) }
        let removedAtStart = name[..<firstRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let removedAtEnd = name[lastRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var cleaned = expression.stringByReplacingMatches(in: name, range: range, withTemplate: " ")
        if removedAtStart {
            cleaned = cleaned.replacingOccurrences(of: #"^(?:\s*[-–—·|:;,]\s*)+"#, with: "", options: .regularExpression)
        }
        if removedAtEnd {
            cleaned = cleaned.replacingOccurrences(of: #"(?:\s*[-–—·|:;,]\s*)+$"#, with: "", options: .regularExpression)
        }
        // Keep meaningful surrounding metadata when the code was nested inside
        // it, while removing whitespace left just inside a closing bracket.
        cleaned = cleaned.replacingOccurrences(of: #"\s+([\)\]])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"([-–—·|:;,])(?:\s+\1)+"#, with: "$1", options: .regularExpression)
        return (InventoryLabelDraft.singleLine(cleaned, maximumCharacters: 500), number)
    }

    static func image(raster: LabelRaster, paper: InventoryLabelSize? = nil) throws -> UIImage {
        try raster.validate()
        let landscapeWidth = raster.height, landscapeHeight = raster.width
        let packed = Array(raster.data)
        // Reconstruct from the packed raster rather than from the source canvas.
        var preview = [UInt8](repeating: 255, count: landscapeWidth * landscapeHeight)
        for row in 0..<raster.height {
            for head in 0..<raster.width where packed[row * 12 + head / 8] & (0x80 >> (head % 8)) != 0 {
                preview[(landscapeHeight - 1 - head) * landscapeWidth + row] = 0
            }
        }
        // The 270-degree stock uses the opposite feed orientation. The saved
        // printer bits stay untouched; only its decoded preview turns upright.
        if paper?.geometry?.contentRotation == 180 { preview.reverse() }
        guard let provider = CGDataProvider(data: Data(preview) as CFData),
              let image = CGImage(width: landscapeWidth, height: landscapeHeight, bitsPerComponent: 8,
                bitsPerPixel: 8, bytesPerRow: landscapeWidth, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else { throw InventoryLabelFailure.invalidRaster }
        return UIImage(cgImage: image)
    }

    private static func priceFont(_ text: String, maximum: CGFloat, minimum: CGFloat, width: CGFloat) throws -> UIFont {
        var size = maximum
        while size >= minimum {
            let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            if measured(text, font: font) <= width { return font }
            size -= 1
        }
        throw InventoryLabelFailure.invalidPrice
    }
    private static func measured(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private static func drawCentered(_ text: String, font: UIFont, rect: CGRect) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }
    private static func fittedTitle(name: String, number: String, font: UIFont, width: CGFloat) -> String {
        let full = number.isEmpty ? name : name.isEmpty ? "#" + number : name + " · #" + number
        if measured(full, font: font) <= width { return full }
        guard !number.isEmpty else { return truncated(name, font: font, width: width) }
        guard !name.isEmpty else { return truncated("#" + number, font: font, width: width) }
        let suffix = truncated("#" + number, font: font, width: width * 0.45)
        let prefix = truncated(name, font: font, width: max(0, width - measured(" · " + suffix, font: font)))
        return prefix.isEmpty ? suffix : prefix + " · " + suffix
    }
    private static func truncated(_ text: String, font: UIFont, width: CGFloat) -> String {
        if measured(text, font: font) <= width { return text }
        let chars = Array(text), suffix = "…"
        guard measured(suffix, font: font) <= width else { return "" }
        var low = 0, high = chars.count
        while low < high {
            let middle = (low + high + 1) / 2
            if measured(String(chars.prefix(middle)) + suffix, font: font) <= width { low = middle }
            else { high = middle - 1 }
        }
        return String(chars.prefix(low)) + suffix
    }
}
