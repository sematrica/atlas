import Foundation

public struct SavedLibrary: Codable, Sendable {
    public var bookmark: Data
    public var lastKnownPath: String
    public var volumeName: String
    public var libraryID: UUID
}

public enum StorageState: Sendable {
    case unconfigured
    case available(StorageSnapshot)
    case unavailable(path: String?, volumeName: String?, reason: String)
}

public protocol BookmarkStore: Sendable {
    func load() throws -> SavedLibrary?
    func save(_ library: SavedLibrary) throws
}

public struct FileBookmarkStore: BookmarkStore {
    private let file: URL
    public init(file: URL) { self.file = file }

    public func load() throws -> SavedLibrary? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: file))
    }

    public func save(_ library: SavedLibrary) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: file, options: .atomic)
    }
}

/// Serializes disk access and bookmark updates away from the UI executor.
/// Each operation owns a bounded security scope; later readers must obtain their own scope.
public actor StorageManager {
    private let store: any BookmarkStore
    private let layout = LibraryLayout()

    public init(store: any BookmarkStore) { self.store = store }

    public func select(_ selectedURL: URL) throws -> StorageSnapshot {
        let started = selectedURL.startAccessingSecurityScopedResource()
        defer { if started { selectedURL.stopAccessingSecurityScopedResource() } }
        let root = selectedURL.standardizedFileURL
        // Create the bookmark first so unsupported locations fail before library creation.
        let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let metadata = try layout.establish(at: root)
        let snapshot = try layout.inspect(at: root, expectedID: metadata.id)
        try store.save(SavedLibrary(bookmark: bookmark, lastKnownPath: root.path,
                                    volumeName: snapshot.volumeName, libraryID: metadata.id))
        return snapshot
    }

    public func refresh() -> StorageState {
        let saved: SavedLibrary
        do {
            guard let value = try store.load() else { return .unconfigured }
            saved = value
        } catch {
            return .unavailable(path: nil, volumeName: nil,
                                reason: "Saved library settings could not be read. Choose the library again. \(error.localizedDescription)")
        }
        do {
            var stale = false
            let root = try URL(resolvingBookmarkData: saved.bookmark,
                               options: [.withSecurityScope, .withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = root.startAccessingSecurityScopedResource()
            defer { if started { root.stopAccessingSecurityScopedResource() } }
            let snapshot = try layout.inspect(at: root, expectedID: saved.libraryID)
            if stale || root.path != saved.lastKnownPath || snapshot.volumeName != saved.volumeName {
                var updated = saved
                updated.bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                updated.lastKnownPath = root.path
                updated.volumeName = snapshot.volumeName
                try store.save(updated)
            }
            return .available(snapshot)
        } catch {
            // Keep the original bookmark so reconnecting can recover without another picker.
            return .unavailable(path: saved.lastKnownPath, volumeName: saved.volumeName,
                                reason: "Reconnect the storage device, or choose the folder again to restore access. \(error.localizedDescription)")
        }
    }
}

/// Keeps the resolved bookmark grant alive for a long-running operation.
public final class LibraryAccess: @unchecked Sendable {
    public let root: URL
    public let libraryID: UUID
    private var scoped: Bool
    public init(root: URL, libraryID: UUID) throws {
        self.root = root; self.libraryID = libraryID
        scoped = root.startAccessingSecurityScopedResource()
        do { _ = try validate() } catch {
            if scoped { root.stopAccessingSecurityScopedResource(); scoped=false }
            throw error
        }
    }
    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
    @discardableResult public func validate() throws -> StorageSnapshot {
        try LibraryLayout().inspect(at: root, expectedID: libraryID)
    }
    public func file(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ["packages", "dumps", "metadata", "cache", "indexes"].contains(String(components[0])) else { throw AtlasError.invalidPath }
        var url = root
        for component in components {
            url.appendPathComponent(String(component))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AtlasError.invalidPath }
        }
        return url
    }
}

extension StorageManager {
    public func acquire() throws -> LibraryAccess {
        guard let saved = try store.load() else { throw AtlasError.storageUnavailable }
        var stale = false
        let root = try URL(resolvingBookmarkData: saved.bookmark,
                           options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        return try LibraryAccess(root: root, libraryID: saved.libraryID)
    }
}
