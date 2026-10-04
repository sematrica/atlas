import Foundation

/// All content stays beneath the chosen root. Only bookmark settings live on the system disk.
public struct LibraryLayout: Sendable {
    public init() {}

    public func establish(at root: URL) throws -> LibraryMetadata {
        try validateRoot(root)
        // Preflight the entire layout before changing an existing folder.
        for directory in LibraryDirectory.allCases {
            try validateDirectory(root.appendingPathComponent(directory.rawValue), required: false)
        }
        let marker = markerURL(root)
        let existing: LibraryMetadata?
        if FileManager.default.fileExists(atPath: marker.path) {
            existing = try readMetadata(at: root)
        } else {
            // Catch a dangling symbolic link as well as an ordinary metadata file.
            if (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw StorageError.unsafeLayout("metadata/library.json")
            }
            existing = nil
        }
        for directory in LibraryDirectory.allCases {
            let child = root.appendingPathComponent(directory.rawValue, isDirectory: true)
            if !FileManager.default.fileExists(atPath: child.path) {
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            }
        }
        if let existing { return existing }
        let metadata = LibraryMetadata()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: marker, options: .atomic)
        return metadata
    }

    /// Read-only: a disconnected drive or deleted folder must never be recreated by a refresh.
    public func inspect(at root: URL, expectedID: UUID) throws -> StorageSnapshot {
        try validateRoot(root)
        for directory in LibraryDirectory.allCases {
            try validateDirectory(root.appendingPathComponent(directory.rawValue), required: true)
        }
        let metadata = try readMetadata(at: root)
        guard metadata.id == expectedID else { throw StorageError.identityMismatch }
        let values = try root.resourceValues(forKeys: [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsReadOnlyKey
        ])
        return StorageSnapshot(
            root: root, volumeName: values.volumeName ?? "Unknown volume",
            availableBytes: values.volumeAvailableCapacity.map(Int64.init),
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            isReadOnly: values.volumeIsReadOnly ?? false, library: metadata
        )
    }

    private func markerURL(_ root: URL) -> URL {
        root.appendingPathComponent("metadata/library.json")
    }

    private func validateRoot(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageError.notDirectory }
    }

    private func validateDirectory(_ url: URL, required: Bool) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            if required { throw StorageError.incompleteLibrary(url.lastPathComponent) }
            return
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StorageError.unsafeLayout(url.lastPathComponent)
        }
    }

    private func readMetadata(at root: URL) throws -> LibraryMetadata {
        let url = markerURL(root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw StorageError.unsafeLayout("metadata/library.json")
        }
        let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(contentsOf: url))
        guard metadata.schemaVersion == 1 else { throw StorageError.unsupportedSchema(metadata.schemaVersion) }
        return metadata
    }
}
