import Foundation

public struct ArticleID: Hashable, Codable, Sendable {
    public let packageID: String
    public let path: String
    public init(packageID: String, path: String) { self.packageID = packageID; self.path = path }
}

public struct Article: Sendable {
    public let id: ArticleID
    public let title: String
    public let html: String
}

public struct ArchiveResource: Sendable {
    public let path: String
    public let title: String
    public let mimeType: String
    public let byteCount: UInt64
}

/// Browsers depend on local content capabilities, not the native ZIM implementation.
public protocol ArticleProvider: FullTextSearch {
    func article(for id: ArticleID) async throws -> Article
    func info(path: String) async throws -> ArchiveResource
    func read(path: String, offset: UInt64, length: Int) async throws -> Data
}
public extension ArticleProvider {
    func info() async throws -> ArchiveResource { try await info(path: "") }
    func read(path: String, offset: UInt64) async throws -> Data { try await read(path: path, offset: offset, length: 262144) }
}

public protocol LinkResolver: Sendable {
    func resolve(_ href: String, relativeTo article: ArticleID) throws -> ArticleID?
}
