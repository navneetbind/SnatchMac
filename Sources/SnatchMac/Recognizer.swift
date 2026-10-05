import CoreGraphics
import Foundation
import Vision

struct Recognition {
    enum Kind { case text, link, code }
    let kind: Kind
    let text: String
}

enum Recognizer {
    struct Options {
        var fast = Settings.fastMode
        var keepLineBreaks = Settings.keepLineBreaks
        var languageCorrection = Settings.languageCorrection
        var language = Settings.recognitionLanguage
        var detectCodes = Settings.detectCodes
        var cleanup = Settings.cleanupText
    }

    /// Languages Vision can read on this Mac (accurate mode), for the Settings picker.
    static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    static func recognize(_ image: CGImage, options: Options = Options()) async throws -> Recognition? {
        try await Task.detached(priority: .userInitiated) {
            try run(image, options: options)
        }.value
    }

    private static func run(_ image: CGImage, options: Options) throws -> Recognition? {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = options.fast ? .fast : .accurate
        textRequest.usesLanguageCorrection = options.languageCorrection
        if options.language == "auto" {
            textRequest.automaticallyDetectsLanguage = true
        } else {
            textRequest.recognitionLanguages = [options.language]
        }

        let codeRequest = VNDetectBarcodesRequest()
        let requests: [VNRequest] = options.detectCodes ? [codeRequest, textRequest] : [textRequest]

        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)

        // A QR code or barcode in the selection wins over the text around it.
        var seen = Set<String>()
        let codes = (options.detectCodes ? codeRequest.results ?? [] : [])
            .compactMap(\.payloadStringValue)
            .filter { seen.insert($0).inserted }
        if !codes.isEmpty {
            return Recognition(kind: .code, text: codes.joined(separator: "\n"))
        }

        var lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        if options.cleanup { lines = TextCleanup.merge(lines) }
        let text = lines.joined(separator: options.keepLineBreaks ? "\n" : " ")
        return Recognition(kind: isSingleURL(text) ? .link : .text, text: text)
    }

    /// The first recognition loads Vision's models and takes a few seconds; do it at launch
    /// so the first real ⌘⇧2 is instant.
    static func warmUp() {
        Task.detached(priority: .utility) {
            let size = CGSize(width: 240, height: 48)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: 20, y: 20, width: 200, height: 8))
            if let image = ctx.makeImage() { _ = try? run(image, options: Options()) }
        }
    }

    static func isSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector.firstMatch(in: trimmed, range: range)?.range == range
    }
}
