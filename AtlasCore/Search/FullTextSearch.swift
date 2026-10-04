import Foundation

public struct SearchResult: Sendable {
    public let articleID: ArticleID
    public let title: String
    public let excerpt: String
}

/// Conventional local search. Implementations must not depend on an LLM.
public protocol FullTextSearch: Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchResult]
}
