import Foundation

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public let schemaVersion: Int
    public let createdAt: Date

    public init(id: UUID = UUID(), schemaVersion: Int = 1, createdAt: Date = Date()) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

public enum LibraryDirectory: String, CaseIterable, Sendable {
    case packages, dumps, indexes, vectors, metadata, cache
}

public struct StorageSnapshot: Sendable {
    public let root: URL
    public let volumeName: String
    public let availableBytes: Int64?
    public let totalBytes: Int64?
    public let isReadOnly: Bool
    public let library: LibraryMetadata
}

public enum StorageError: LocalizedError {
    case notDirectory, unsafeLayout(String), unsupportedSchema(Int), identityMismatch, incompleteLibrary(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory: return "Choose an existing folder for your Sematrica library."
        case .unsafeLayout(let name): return "The library item ‘\(name)’ must be a real folder, not a file or symbolic link."
        case .unsupportedSchema(let version): return "This library uses schema \(version), which this version of Sematrica cannot open."
        case .identityMismatch: return "A different library is present at this location. Choose the intended library again."
        case .incompleteLibrary(let name): return "The library is missing ‘\(name)’. Choose this folder again to repair its structure."
        }
    }
}

public enum PackageKind: String, Codable, Sendable {
    case textOnly, standard, full, rawDump, historicalArchive
}

public enum VerificationState: String, Codable, Sendable {
    case unverified, verifying, verified, failed
}

