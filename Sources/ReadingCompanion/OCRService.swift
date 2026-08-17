import AppKit
import PDFKit
import Vision

struct OCRLineObservation: Equatable {
    var text: String
    var boundingBox: CGRect
}

enum OCRLayoutReconstructor {
    static func text(from observations: [OCRLineObservation]) -> String {
        let usable = observations.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return "" }

        let vertical = usable.filter { $0.boundingBox.height > $0.boundingBox.width * 1.35 }
        let candidates: [[OCRLineObservation]]
        if vertical.count >= max(3, usable.count / 3) {
            candidates = [verticalReadingOrder(usable), topDownReadingOrder(usable)]
        } else if hasTwoColumns(usable) {
            candidates = [columnReadingOrder(usable), topDownReadingOrder(usable)]
        } else {
            candidates = [topDownReadingOrder(usable)]
        }
        // A TOC is one of the few page types whose correct reading order can be
        // checked locally: it yields more complete title/page pairs and a mostly
        // increasing printed-page sequence. This prevents row-wise OCR from
        // interleaving the left and right columns.
        let ordered = candidates.max { tocLayoutScore($0) < tocLayoutScore($1) } ?? candidates[0]
        return ordered.map(\.text).joined(separator: "\n")
    }

    private static func tocLayoutScore(_ lines: [OCRLineObservation]) -> Double {
        let source = lines.map(\.text).joined(separator: "\n")
        let entries = TOCReliableParser.parse(source)
        guard !entries.isEmpty else { return 0 }
        let pages = entries.compactMap(\.printedPage)
        let increasing = zip(pages, pages.dropFirst()).filter { $1 >= $0 }.count
        let monotonic = pages.count < 2 ? 0 : Double(increasing) / Double(pages.count - 1)
        return Double(pages.count * 4 + entries.count) + monotonic * 8
    }

    private static func topDownReadingOrder(_ lines: [OCRLineObservation]) -> [OCRLineObservation] {
        lines.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.018 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    private static func hasTwoColumns(_ lines: [OCRLineObservation]) -> Bool {
        let candidates = lines.filter { $0.boundingBox.width < 0.62 && $0.boundingBox.height < $0.boundingBox.width * 1.35 }
        let left = candidates.filter { $0.boundingBox.midX < 0.46 }
        let right = candidates.filter { $0.boundingBox.midX > 0.54 }
        guard left.count >= 2, right.count >= 2 else { return false }
        let leftMax = left.map(\.boundingBox.maxX).sorted()[left.count / 2]
        let rightMin = right.map(\.boundingBox.minX).sorted()[right.count / 2]
        return rightMin - leftMax > -0.08
    }

    private static func columnReadingOrder(_ lines: [OCRLineObservation]) -> [OCRLineObservation] {
        let spanning = lines.filter { $0.boundingBox.width >= 0.62 || ($0.boundingBox.minX < 0.46 && $0.boundingBox.maxX > 0.54) }
        let body = lines.filter { line in !spanning.contains(line) }
        let left = body.filter { $0.boundingBox.midX < 0.5 }
        let right = body.filter { $0.boundingBox.midX >= 0.5 }
        return topDownReadingOrder(spanning) + topDownReadingOrder(left) + topDownReadingOrder(right)
    }

    private static func verticalReadingOrder(_ lines: [OCRLineObservation]) -> [OCRLineObservation] {
        let headers = lines.filter { $0.boundingBox.width >= $0.boundingBox.height * 1.35 }
        let body = lines.filter { line in !headers.contains(line) }
        return topDownReadingOrder(headers) + body.sorted {
            if abs($0.boundingBox.midX - $1.boundingBox.midX) > 0.018 {
                return $0.boundingBox.midX > $1.boundingBox.midX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
    }
}

enum OCRService {
    @MainActor
    static func extract(
        from document: PDFDocument,
        progress: @MainActor (Int, Int) -> Void
    ) async -> [PageText] {
        var pages: [PageText] = []
        for pageIndex in 0..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: pageIndex) else { break }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if embedded.count >= 24 {
                pages.append(PageText(pageIndex: pageIndex, text: embedded, cameFromOCR: false, pageLabel: page.label))
            } else if let image = render(page: page) {
                let recognized = OCRTextNormalizer.removeSpuriousCJKSpaces((try? await recognize(image)) ?? embedded)
                pages.append(PageText(pageIndex: pageIndex, text: recognized, cameFromOCR: true, pageLabel: page.label))
            } else {
                pages.append(PageText(pageIndex: pageIndex, text: embedded, cameFromOCR: false, pageLabel: page.label))
            }
            progress(pageIndex + 1, document.pageCount)
            await Task.yield()
        }
        return pages
    }

    @MainActor
    static func reextract(
        pageIndices: [Int],
        from document: PDFDocument,
        progress: @MainActor (Int, Int) -> Void
    ) async -> [PageText] {
        var refreshed: [PageText] = []
        let validIndices = pageIndices.filter { (0..<document.pageCount).contains($0) }
        for (position, pageIndex) in validIndices.enumerated() {
            guard !Task.isCancelled, let page = document.page(at: pageIndex) else { break }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let image = render(page: page) {
                let recognized = OCRTextNormalizer.removeSpuriousCJKSpaces(
                    (try? await recognize(image))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
                // 强制视觉 OCR 用于修复 PDF 文本层错序；识别结果太短时保留原文本层。
                let text = recognized.count >= 12 ? recognized : embedded
                refreshed.append(PageText(pageIndex: pageIndex, text: text, cameFromOCR: recognized.count >= 12, pageLabel: page.label))
            } else {
                refreshed.append(PageText(pageIndex: pageIndex, text: embedded, cameFromOCR: false, pageLabel: page.label))
            }
            progress(position + 1, validIndices.count)
            await Task.yield()
        }
        return refreshed
    }

    @MainActor
    static func recognizeSelection(
        fragments: [HighlightFragment],
        from document: PDFDocument
    ) async -> String? {
        var lines: [String] = []
        for fragment in fragments {
            guard !Task.isCancelled,
                  let page = document.page(at: fragment.pageIndex),
                  let pageImage = render(page: page),
                  let crop = crop(pageImage, pageBounds: page.bounds(for: .mediaBox), selection: fragment.bounds.cgRect),
                  let recognized = try? await recognize(crop) else { continue }
            let line = HighlightTextNormalizer.inline(recognized)
            if !line.isEmpty { lines.append(line) }
        }
        guard !lines.isEmpty else { return nil }
        return HighlightTextNormalizer.inline(lines.joined(separator: "\n"))
    }

    private static func crop(
        _ image: CGImage,
        pageBounds: CGRect,
        selection: CGRect
    ) -> CGImage? {
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        let padded = selection.insetBy(dx: -2, dy: -1.5).intersection(pageBounds)
        let scaleX = CGFloat(image.width) / pageBounds.width
        let scaleY = CGFloat(image.height) / pageBounds.height
        let pixelRect = CGRect(
            x: (padded.minX - pageBounds.minX) * scaleX,
            y: (pageBounds.maxY - padded.maxY) * scaleY,
            width: padded.width * scaleX,
            height: padded.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }
        return image.cropping(to: pixelRect)
    }

    @MainActor
    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let maxSide: CGFloat = 2_400
        let scale = min(maxSide / max(bounds.width, bounds.height), 2.0)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        image.unlockFocus()
        var proposed = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let observations = (request.results ?? []).compactMap { observation -> OCRLineObservation? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return OCRLineObservation(text: text, boundingBox: observation.boundingBox)
            }
            return OCRLayoutReconstructor.text(from: observations)
        }.value
    }
}
