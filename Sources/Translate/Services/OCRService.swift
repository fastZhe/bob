import AppKit
import Vision

/// 本地 OCR（Vision 框架）。免费、离线、支持中英日韩等主流语言。
@MainActor
final class OCRService {

    enum OCRError: LocalizedError {
        case noCGImage
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noCGImage: return "图像无法转换为 CGImage"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// 从 NSImage 识别文字，按行拼接（保留顺序）。
    func recognizeText(in image: NSImage, languages: [String] = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.noCGImage
        }
        return try await recognizeText(in: cgImage, languages: languages)
    }

    func recognizeText(in cgImage: CGImage, languages: [String] = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, error in
                if let error = error {
                    cont.resume(throwing: OCRError.underlying(error))
                    return
                }
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: "")
                    return
                }
                // 按 boundingBox.minY 排序：从上到下
                let sorted = observations.sorted { a, b in
                    a.boundingBox.maxY > b.boundingBox.maxY  // Vision 的 Y 起点是左下
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            request.revision = VNRecognizeTextRequestRevision3
            request.minimumTextHeight = 0.005

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                cont.resume(throwing: OCRError.underlying(error))
            }
        }
    }
}
