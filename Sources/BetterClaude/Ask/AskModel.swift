import CoworkKit
import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers a question about your past conversations with the model built into macOS, from
/// passages the history index finds. Nothing leaves the Mac.
@MainActor
@Observable
final class AskModel {
    enum Phase: Equatable {
        case idle
        case searching
        case answering
        case done
        /// Nothing in the history matched the question's words.
        case nothingFound
        case failed(String)
    }

    enum Availability: Equatable {
        case available
        /// Why the model can't answer here, in a sentence for a person.
        case unavailable(String)
    }

    var question = ""
    private(set) var askedQuestion = ""
    private(set) var answer = ""
    private(set) var sources: [AskRetrieval.Source] = []

    /// Once the answer is in, the sources it cites; everything searched until then, or if it
    /// cites none.
    var shownSources: [AskRetrieval.Source] {
        guard phase == .done else { return sources }
        let cited = Set(answer.matches(of: /\d+/).compactMap { Int($0.output) }
            .filter { number in answer.contains("[\(number)") || answer.contains(", \(number)]") })
        let chosen = sources.filter { cited.contains($0.number) }
        return chosen.isEmpty ? sources : chosen
    }
    private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in System Settings to ask questions here.")
            case .unavailable(.modelNotReady):
                return .unavailable("Apple Intelligence is still getting ready on this Mac. Try again in a little while.")
            case .unavailable(.deviceNotEligible):
                return .unavailable("Asking needs a Mac with Apple Intelligence.")
            case .unavailable:
                return .unavailable("The model built into macOS isn't available right now.")
            }
        }
        #endif
        return .unavailable("Asking needs macOS 26 or later, with Apple Intelligence.")
    }

    func ask(index: HistoryIndex?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let index else { return }
        task?.cancel()
        askedQuestion = question
        answer = ""
        sources = []
        phase = .searching
        task = Task {
            do {
                let (found, context) = try await AskRetrieval.gather(question: question, index: index)
                guard !Task.isCancelled else { return }
                sources = found
                guard !found.isEmpty else {
                    phase = .nothingFound
                    return
                }
                phase = .answering
                try await respond(question: question, context: context)
                if !Task.isCancelled { phase = .done }
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(Self.explain(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        if phase == .searching || phase == .answering { phase = answer.isEmpty ? .idle : .done }
    }

    private func respond(question: String, context: String) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: AskRetrieval.instructions)
            let stream = session.streamResponse(to: AskRetrieval.prompt(question: question, context: context),
                                                options: GenerationOptions(temperature: 0.2))
            for try await snapshot in stream {
                try Task.checkCancellation()
                answer = snapshot.content
            }
            return
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    static func explain(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return "The passages were too long for the model built into macOS. Try a narrower question."
            case .guardrailViolation:
                return "The model built into macOS declined to answer this one. The sources below may still help."
            default:
                break
            }
        }
        #endif
        return "Couldn't answer: \(error.localizedDescription)"
    }
}
