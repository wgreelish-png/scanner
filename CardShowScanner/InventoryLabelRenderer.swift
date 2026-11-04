import UIKit

@MainActor struct InventoryLabelBitmap {
    let raster: LabelRaster
    let previewImage: UIImage
}

/// Layout runs horizontally on the sticker, then rotates into the D110's
/// narrow-head feed orientation. The preview is decoded from the final bits.
@MainActor enum InventoryLabelRenderer {
    static func render(_ draft: InventoryLabelDraft) throws -> InventoryLabelBitmap {
        try draft.validate()
        guard let price = draft.priceText else { throw InventoryLabelFailure.invalidPrice }
        return try render(price: price, name: draft.cardName, number: draft.cardNumber,
            condition: draft.condition, style: draft.style, paper: draft.paperSize)
    }

    static func render(_ draft: CustomPriceTagDraft) throws -> InventoryLabelBitmap {
        try draft.validate()
        return try render(price: draft.priceText, name: "", number: "", condition: "",
            style: .priceOnly, paper: draft.paperSize)
    }

    private static func render(price: String, name cardName: String, number cardNumber: String, condition conditionText: String,
                               style: InventoryLabelStyle, paper: InventoryLabelSize) throws -> InventoryLabelBitmap {
        let width = paper.feedDots, height = paper.headDots
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let storage = context.data else { throw InventoryLabelFailure.invalidRaster }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let margin: CGFloat = 8, available = CGFloat(width) - margin * 2
        switch style {
        case .priceOnly:
            let font = try priceFont(price, maximum: 64, minimum: 14, width: available)
            drawCentered(price, font: font, rect: CGRect(x: margin, y: 0, width: available, height: CGFloat(height)))
        case .cardDetails:
            let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
            let number = InventoryLabelDraft.singleLine(cardNumber, maximumCharacters: 100)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let line = fittedTitle(name: cardName, number: number, font: titleFont, width: available)
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
        let grayscale = Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: UInt8.self), count: width * height))
        return try bitmap(grayscale: grayscale, landscapeWidth: width, landscapeHeight: height)
    }

    static func bitmap(grayscale: [UInt8], landscapeWidth: Int, landscapeHeight: Int) throws -> InventoryLabelBitmap {
        guard landscapeHeight == 96, [240, 320, 400].contains(landscapeWidth),
              grayscale.count == landscapeWidth * landscapeHeight else { throw InventoryLabelFailure.invalidRaster }
        var packed = [UInt8](repeating: 0, count: landscapeWidth * 12)
        for x in 0..<landscapeWidth {
            for y in 0..<landscapeHeight where grayscale[y * landscapeWidth + x] < 128 {
                let head = landscapeHeight - 1 - y
                packed[x * 12 + head / 8] |= 0x80 >> (head % 8)
            }
        }
        let raster = LabelRaster(width: landscapeHeight, height: landscapeWidth, data: Data(packed))
        try raster.validate()
        return InventoryLabelBitmap(raster: raster, previewImage: try image(raster: raster))
    }

    static func image(raster: LabelRaster) throws -> UIImage {
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
        let full = number.isEmpty ? name : name + " · #" + number
        if measured(full, font: font) <= width { return full }
        guard !number.isEmpty else { return truncated(name, font: font, width: width) }
        let suffix = truncated("#" + number, font: font, width: width * 0.45)
        let prefix = truncated(name, font: font, width: max(0, width - measured(" · " + suffix, font: font)))
        return prefix + " · " + suffix
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
