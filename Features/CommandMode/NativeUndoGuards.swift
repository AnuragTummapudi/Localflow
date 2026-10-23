import Foundation

/// Ownership includes file identity and revision, not just equal bytes at a reused path.
struct NativeFileRevision: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let created: Date
    init(url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date,
              let created = values[.creationDate] as? Date, values[.type] as? FileAttributeType == .typeRegular else { throw ToolError.changedTarget }
        self.device = device.uint64Value; self.inode = inode.uint64Value; self.size = size.uint64Value
        self.modified = modified; self.created = created
    }
}

/// A created screenshot can be removed only while the exact owned file revision remains.
enum NativeFileUndo {
    static func remove(url: URL, revision: NativeFileRevision, data: Data) throws -> ToolVerification {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                guard try NativeFileRevision(url: coordinatedURL) == revision, try Data(contentsOf: coordinatedURL) == data else { throw ToolError.changedTarget }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        return FileManager.default.fileExists(atPath: url.path) ? .failed("Screenshot removal failed.") : .verified
    }
}
