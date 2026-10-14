import Foundation
import CryptoKit
import OSLog

public enum AtlasError: LocalizedError {
    case storageUnavailable, invalidPath, catalogUnavailable, insufficientSpace, invalidResponse, resumeRejected
    case checksumMismatch, incompleteDownload, articleUnavailable, searchUnavailable, unsupportedArchive, busy, invalidManifest
    case notZIM, alreadyInLibrary, importInterrupted
    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Reconnect your library drive or choose its folder again."
        case .invalidPath: "This library contains an unsafe file location. Choose a dedicated Sematrica folder."
        case .catalogUnavailable: "The package catalog is unavailable. Check your connection and try again."
        case .insufficientSpace: "There isn’t enough free space on the library drive for this package."
        case .invalidResponse: "The download server returned an unexpected response. Try again later."
        case .resumeRejected: "The server can’t continue this partial download. Cancel it and download again."
        case .checksumMismatch: "Verification failed. The package may be corrupted. Delete or cancel it and download again."
        case .incompleteDownload: "The download was interrupted. Resume to continue from the saved partial file."
        case .articleUnavailable: "This article or resource isn’t included in the installed package."
        case .searchUnavailable: "The archive’s search index could not be opened. Try verifying the package."
        case .unsupportedArchive: "This dataset is archive-only and cannot be browsed in Sematrica."
        case .busy: "Wait for the current package operation to finish."
        case .invalidManifest: "The package manifest could not be read. Existing files have been preserved."
        case .notZIM: "This file isn’t a ZIM archive Sematrica can open."
        case .alreadyInLibrary: "This package is already in your library."
        case .importInterrupted: "This import was interrupted. Remove it and import the file again."
        }
    }
}
public enum AtlasLog {
    private static let logger = Logger(subsystem: "com.atlas.knowledge", category: "Library")
    public static func message(_ error: Error) -> String {
        logger.error("\(String(describing: error), privacy: .public)")
        if let known = error as? AtlasError { return known.localizedDescription }
        if let storage = error as? StorageError { return storage.localizedDescription }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteOutOfSpaceError { return AtlasError.insufficientSpace.localizedDescription }
        if cocoa.domain == NSURLErrorDomain { return "The connection was interrupted. Check your network and resume the download." }
        return "Sematrica couldn’t access the library files. Reconnect the drive, check its permissions, and try again."
    }
}
public enum PackageFormat: String, Codable, Sendable { case zim, archive }
public struct PackageChecksum: Codable, Equatable, Sendable {
    public enum Algorithm: String, Codable, Sendable { case sha256, sha1, md5 }
    public let algorithm: Algorithm
    public let value: String
    public init(algorithm: Algorithm, value: String) { self.algorithm = algorithm; self.value = value.lowercased() }
}
public struct WikipediaPackage: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let languageCode: String
    public let kind: PackageKind
    public let summary: String
    public let version: String
    public var downloadURL: URL
    public var downloadBytes: Int64
    public var checksum: PackageChecksum?
    public let format: PackageFormat
    public let source: String
    public let family: String
    /// The Kiwix collection it comes from ("wikipedia", "wiktionary", "gutenberg"…); nil for
    /// Wikimedia archives, imported files and packages recorded before collections existed.
    public var category: String?
    public var language: String { Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode }
    public var storageKey: String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
    public var capabilities: String { format == .zim ? "Browsable · Title search" : "Archive only" }
    public init(id: String, name: String, languageCode: String, kind: PackageKind, summary: String, version: String,
                downloadURL: URL, downloadBytes: Int64, checksum: PackageChecksum? = nil, format: PackageFormat,
                source: String, family: String, category: String? = nil) {
        self.id=id; self.name=name; self.languageCode=languageCode; self.kind=kind; self.summary=summary; self.version=version
        self.downloadURL=downloadURL; self.downloadBytes=downloadBytes; self.checksum=checksum; self.format=format
        self.source=source; self.family=family; self.category=category
    }
    /// Copied in from a file the user chose, not downloaded.
    public var isImported: Bool { source == PackageImport.source }
}
extension PackageKind {
    public var label: String {
        switch self {
        case .textOnly: "Text only"
        case .standard: "Standard / images"
        case .full: "Full / images"
        case .rawDump: "Raw dump"
        case .historicalArchive: "Historical archive"
        }
    }
}
public enum InstallationState: String, Codable, Sendable {
    case paused, downloading, verifying, installed, failed, corrupted
}
public struct PackageRecord: Identifiable, Codable, Sendable {
    public var id: String { package.id }
    public var package: WikipediaPackage
    public var relativePath: String
    public var state: InstallationState
    public var receivedBytes: Int64
    public var etag: String?
    public var lastModified: String?
    public var verification: VerificationState
    public var message: String?
    public var updatedAt: Date
    public var partialPath: String { relativePath + ".partial" }
    public init(package: WikipediaPackage) {
        self.package=package
        let ext = package.format == .zim ? "zim" : package.downloadURL.lastPathComponent.split(separator: ".").dropFirst().joined(separator: ".")
        relativePath = (package.format == .zim ? "packages/" : "dumps/") + package.storageKey + "." + (ext.isEmpty ? "archive" : ext)
        state = .paused; receivedBytes = 0; verification = .unverified; updatedAt = Date()
    }
}
public struct TransferProgress: Sendable {
    public var bytesPerSecond: Double = 0
    public var verificationFraction: Double? = nil
    public init(bytesPerSecond: Double = 0, verificationFraction: Double? = nil) {
        self.bytesPerSecond=bytesPerSecond; self.verificationFraction=verificationFraction
    }
}
