import Foundation
import Vision

final class ClipboardOCRService {
    private let queue: OperationQueue
    private var generation = 0

    init() {
        queue = OperationQueue()
        queue.name = "Droppy.ClipboardOCR"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    func recognizeText(
        in imageData: Data,
        itemID: UUID,
        completion: @escaping (UUID, String?) -> Void
    ) {
        let scheduledGeneration = generation
        queue.addOperation { [weak self] in
            guard let self, scheduledGeneration == generation else {
                return
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(data: imageData)
            try? handler.perform([request])
            let text = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard scheduledGeneration == generation else {
                return
            }
            DispatchQueue.main.async {
                completion(itemID, text?.isEmpty == false ? text : nil)
            }
        }
    }

    func cancelPending() {
        generation += 1
        queue.cancelAllOperations()
    }
}
