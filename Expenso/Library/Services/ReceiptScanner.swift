import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

enum ReceiptScanError: LocalizedError {
    case invalidImage, imageTooLarge, noText, onePageOnly

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image couldn't be read. Choose a clear receipt photo or screenshot."
        case .imageTooLarge: return "This image is too large. Choose a smaller receipt image (up to 20 MB)."
        case .noText: return "No readable receipt text was found. Try better lighting or a closer crop."
        case .onePageOnly: return "Scan one receipt page at a time. Multiple pages weren't imported or combined."
        }
    }
}

struct ReceiptScanPayload: Sendable {
    let extraction: ReceiptExtraction
    let imageData: Data
}

/// Vision runs on this actor's executor, never synchronously on the UI actor.
/// Only a downsampled image and local text are retained; there is no network client.
actor ReceiptScanner {
    static let shared = ReceiptScanner()

    func recognize(data: Data) async throws -> ReceiptScanPayload {
        try Task.checkCancellation()
        guard data.count <= 20 * 1_024 * 1_024 else { throw ReceiptScanError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_400
              ] as CFDictionary) else { throw ReceiptScanError.invalidImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // Do not spell-correct merchant names or figures.
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["en-US", "ru-RU", "hr-HR", "bs-Latn"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        let observations = request.results ?? []
        let lines = Self.lines(from: observations)
        guard !lines.isEmpty else { throw ReceiptScanError.noText }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ReceiptScanError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ReceiptScanError.invalidImage }
        let extraction = try await ReceiptInterpreter.extract(lines: lines)
        try Task.checkCancellation()
        return ReceiptScanPayload(extraction: extraction, imageData: output as Data)
    }

    /// Merge separately recognized left/right columns into receipt rows before parsing.
    private static func lines(from observations: [VNRecognizedTextObservation]) -> [String] {
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - observation.boundingBox.midY) < min(anchor.boundingBox.height, observation.boundingBox.height) * 0.55 {
                rows[rows.count - 1].append(observation)
            } else { rows.append([observation]) }
        }
        return rows.compactMap { row in
            let text = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
