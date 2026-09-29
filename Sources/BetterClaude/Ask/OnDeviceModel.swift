import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writing with the model built into macOS, where there is one.
enum OnDeviceModel {

    /// Streams a response, calling `onPartial` as it grows. `nil` when the model isn't
    /// available here or declines.
    @MainActor
    static func write(instructions: String, prompt: String, onPartial: @escaping (String) -> Void) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: instructions)
            var text = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2)) {
                    text = snapshot.content
                    onPartial(text)
                }
                return text
            } catch {
                return text.isEmpty ? nil : text
            }
        }
        #endif
        return nil
    }
}
