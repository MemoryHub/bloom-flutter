import UIKit
import ImageIO
import CoreText

/// WidgetKit cannot run the host's Flutter renderer after the host is killed.
/// This adapter renders the shared descriptor only; it never selects content.
/// Originals, item identity and timeline entries are the same files as Flutter.
enum BloomWidgetRenderer {
    static let version = "bloom-widget-native-v2-bounded"
    static let sizes: [String: CGSize] = [
        "portrait": CGSize(width: 720, height: 1200),
        "square": CGSize(width: 720, height: 720),
        "largeSquare": CGSize(width: 1200, height: 1200),
    ]
    private static let registered: Void = {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        for name in ["mmxj.ttf", "Arimo.ttf"] {
            let url = app.appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/fonts/\(name)")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func image(at url: URL, maxPixels: Int = 800) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func render(_ image: UIImage, item: [String: Any], family: String) -> Data? {
        _ = registered
        let size = sizes[family] ?? sizes["square"]!
        let format = UIGraphicsImageRendererFormat()
        // Keep the established layout in logical coordinates, but allocate
        // only the pixels a desktop widget needs. Automatic wide-color output
        // can double the buffer; every family releases its own render pool.
        let maximum: CGFloat = family == "largeSquare" ? 800 : 480
        format.scale = min(1, maximum / max(size.width, size.height))
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let canvas = context.cgContext
            let isArt = item["source_name"] as? String == "art"
            let photo = item["photo"] as? [String: Any] ?? [:]
            let target = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height * (isArt ? 1 : 0.75)))
            let fx = isArt ? 0.5 : (photo["focus_x"] as? NSNumber)?.doubleValue ?? 0.5
            let fy = isArt ? 0.45 : (photo["focus_y"] as? NSNumber)?.doubleValue ?? 0.45
            cover(image, target: target, focusX: fx, focusY: fy, canvas: canvas)
            if isArt {
                artwork(item["content_snapshot"] as? [String: Any] ?? [:], size: size, canvas: canvas)
            } else {
                letter(item, rect: CGRect(x: 0, y: target.height, width: size.width, height: size.height - target.height), family: family, canvas: canvas)
            }
        }
    }

    private static func cover(_ image: UIImage, target: CGRect, focusX: Double, focusY: Double, canvas: CGContext) {
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        let x = min(max(CGFloat(focusX) * width - target.width / 2, 0), width - target.width)
        let y = min(max(CGFloat(focusY) * height - target.height / 2, 0), height - target.height)
        canvas.saveGState()
        canvas.clip(to: target)
        image.draw(in: CGRect(x: target.minX - x, y: target.minY - y, width: width, height: height))
        canvas.restoreGState()
    }

    private static func clean(_ value: Any?) -> String {
        guard let value, value is String || value is NSNumber else { return "" }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["none", "null", "undefined"].contains(text.lowercased()) ? "" : text
    }

    private static func font(_ size: CGFloat, chinese: Bool = false, bold: Bool = false) -> UIFont {
        let base = UIFont(name: chinese ? "mmxj-Regular" : "Arimo-Regular", size: size)
            ?? UIFont.systemFont(ofSize: size)
        if bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private struct Run {
        var text: String
        var font: UIFont
        var color: UIColor
        var width: CGFloat
        var lines: Int
        var height: CGFloat {
            min(CGFloat(lines) * font.lineHeight, ceil((text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            ).height))
        }
        func draw(x: CGFloat, y: CGFloat, align: NSTextAlignment = .left) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = align
            paragraph.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
        }
    }

    private static func artwork(_ meta: [String: Any], size: CGSize, canvas: CGContext) {
        let unit = min(size.width, size.height) / 720, compact = size.width == size.height
        let width = (compact ? 340.0 : 336.0) * unit, pad = 18 * unit
        let textWidth = width - 2 * pad, inset = (compact ? 56.0 : 52.0) * unit
        var runs: [(Run, CGFloat)] = []
        func add(_ text: String, size: CGFloat, bold: Bool = false, lines: Int = 1, gray: CGFloat = 0.12, gap: CGFloat) {
            if !text.isEmpty { runs.append((Run(text: text, font: font(size * unit, bold: bold), color: UIColor(white: gray, alpha: 1), width: textWidth, lines: lines), gap * unit)) }
        }
        add(clean(meta["title"]).isEmpty ? "Artwork" : clean(meta["title"]), size: compact ? 32 : 34, lines: 2, gap: compact ? 8 : 10)
        let fullArtist = clean(meta["artist"])
        let displayArtist = clean(meta["artist_display_name"])
        let artist = fullArtist.isEmpty ? "" : (displayArtist.isEmpty ? fullArtist : displayArtist)
        add(artist, size: 22, bold: true, gap: 6)
        let birth = clean(meta["artist_birth_year"]), death = clean(meta["artist_death_year"])
        let pattern = "^(?:c\\.\\s*)?[1-9]\\d{2,3}(?:/\\d{1,4})?$"
        let validBirth = birth.range(of: pattern, options: .regularExpression) != nil
        let validDeath = death.range(of: pattern, options: .regularExpression) != nil
        var life = validBirth && validDeath ? "\(birth)–\(death)" : validBirth ? "b. \(birth)" : validDeath ? "d. \(death)" : ""
        if let b = Int(birth), let d = Int(death), b > d { life = "" }
        let flags = ["JP":"🇯🇵", "NL":"🇳🇱", "FR":"🇫🇷", "AT":"🇦🇹", "IT":"🇮🇹", "GB":"🇬🇧", "US":"🇺🇸", "DE":"🇩🇪", "ES":"🇪🇸", "UA":"🇺🇦"]
        let flag = flags[clean(meta["artist_country_code"]).uppercased()] ?? ""
        var lifeRun: Run?
        if !artist.isEmpty, (!life.isEmpty || !flag.isEmpty), runs.count > 1 {
            let text = [life, flag].filter { !$0.isEmpty }.joined(separator: "  ")
            let lifeFont = font((compact ? 14 : 16) * unit)
            let lifeWidth = min(145 * unit, ceil((text as NSString).size(withAttributes: [.font: lifeFont]).width))
            lifeRun = Run(text: text, font: lifeFont, color: UIColor(white: 0.41, alpha: 1), width: lifeWidth, lines: 1)
            runs[1].0.width = max(1, textWidth - lifeWidth - 10 * unit)
        }
        add(clean(meta["year"]), size: 20, gray: 0.24, gap: 12)
        if !compact {
            let explicit = clean(meta["label_caption"])
            let body = explicit.isEmpty ? clean(meta["short_description"]) : explicit
            let clipped = body.count > 110 ? String(body.prefix(107)) + "…" : body
            add(clipped, size: 20, lines: 2, gray: 0.32, gap: 0)
        }
        let height = 2 * pad + runs.enumerated().reduce(CGFloat(0)) { sum, pair in
            sum + pair.element.0.height + (pair.offset == runs.count - 1 ? 0 : pair.element.1)
        }
        let card = CGRect(x: size.width - inset - width, y: size.height - inset - height, width: width, height: height)
        func paper(_ rect: CGRect) {
            canvas.saveGState()
            canvas.setShadow(offset: CGSize(width: 3 * unit, height: 4 * unit), blur: 3 * unit, color: UIColor.black.withAlphaComponent(0.11).cgColor)
            canvas.setFillColor(UIColor(red: 0.969, green: 0.965, blue: 0.941, alpha: 1).cgColor)
            canvas.fill(rect)
            canvas.restoreGState()
        }
        paper(card)
        var y = card.minY + pad
        for (index, pair) in runs.enumerated() {
            pair.0.draw(x: card.minX + pad, y: y)
            if index == 1, let lifeRun {
                let actualWidth = min(pair.0.width, (pair.0.text as NSString).size(withAttributes: [.font: pair.0.font]).width)
                lifeRun.draw(x: card.minX + pad + actualWidth + 10 * unit, y: y + pair.0.font.ascender - lifeRun.font.ascender)
            }
            y += pair.0.height + pair.1
        }
        let note = clean(meta["bloom_note_zh"])
        if !note.isEmpty {
            let run = Run(text: note, font: font((compact ? 22 : 24) * unit, chinese: true), color: UIColor(white: 0.17, alpha: 1), width: textWidth, lines: 4)
            let notePad = (compact ? 12.0 : 16.0) * unit
            let rect = CGRect(x: card.minX, y: card.minY - (compact ? 8.0 : 9.0) * unit - run.height - 2 * notePad, width: width, height: run.height + 2 * notePad)
            paper(rect)
            run.draw(x: rect.minX + pad, y: rect.minY + notePad)
        }
    }

    private static func letter(_ item: [String: Any], rect: CGRect, family: String, canvas: CGContext) {
        let colors = [UIColor(red: 0.98, green: 0.969, blue: 0.937, alpha: 1).cgColor,
                      UIColor(red: 0.945, green: 0.925, blue: 0.878, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            canvas.saveGState(); canvas.clip(to: rect)
            canvas.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            canvas.restoreGState()
        }
        let caption = item["caption"] as? [String: Any] ?? [:]
        let raw = clean(caption["zh"]).trimmingCharacters(in: CharacterSet(charactersIn: "「」"))
        let chinese = "「\(raw.isEmpty ? "今天，也值得看一眼。" : raw)」"
        let pad = rect.width * 0.095, width = rect.width - 2 * pad
        var zh = Run(text: chinese, font: font(max(30, min(86, rect.height * (family == "square" ? 0.22 : 0.20))), chinese: true), color: UIColor(white: 0.16, alpha: 1), width: width, lines: 2)
        while zh.font.pointSize > 24 {
            let measured = (chinese as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: zh.font], context: nil).height
            if measured <= zh.font.lineHeight * 2 { break }
            zh.font = font(zh.font.pointSize - 1, chinese: true)
        }
        let english = clean(caption["en"]).replacingOccurrences(of: "^[—–-]\\s*", with: "", options: .regularExpression)
        let en = Run(text: english.isEmpty ? "" : "— \(english)", font: font(max(24, min(44, rect.height * 0.10)), chinese: true), color: UIColor(white: 0.29, alpha: 1), width: width, lines: family == "square" ? 1 : 2)
        let metaFont = font(max(22, min(40, rect.height * 0.095)), chinese: true)
        let date = Run(text: clean(item["captured_date_text"]), font: metaFont, color: UIColor(white: 0.44, alpha: 1), width: width * 0.42, lines: 1)
        let place = Run(text: clean(item["location_text"]), font: metaFont, color: UIColor(white: 0.44, alpha: 1), width: width * 0.48, lines: 1)
        let gap = rect.height * 0.045, metadataHeight = max(date.height, place.height)
        let showEnglish = !en.text.isEmpty && zh.height + en.height + metadataHeight + 2 * gap <= rect.height * 0.85
        let total = zh.height + (showEnglish ? gap + en.height : 0) + (metadataHeight > 0 ? gap + metadataHeight : 0)
        var y = rect.minY + max(rect.height * 0.075, (rect.height - total) / 2)
        zh.draw(x: pad, y: y); y += zh.height
        if showEnglish { y += gap; en.draw(x: pad, y: y); y += en.height }
        if metadataHeight > 0 {
            y += gap; date.draw(x: pad, y: y)
            place.draw(x: rect.maxX - pad - place.width, y: y, align: .right)
        }
    }
}
