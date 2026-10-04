import Foundation

public struct GroundedPassage: Sendable {
    public let articleID: ArticleID
    public let text: String
}

/// Runtime-neutral boundary only. No runtime, retrieval, embeddings, or networking in Stage 1.
public protocol LLMProvider: Sendable {
    func answer(question: String, passages: [GroundedPassage]) async throws -> String
}
