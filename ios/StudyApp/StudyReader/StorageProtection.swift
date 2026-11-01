import Foundation

/// Keeps imported documents and notes inside the app's local-only library.
enum StorageProtection {
    static func prepareLibrary() throws -> URL {
        let root = DocumentImport.supportDirectory
        try secureDirectory(root)
        try secureDirectory(root.appendingPathComponent("Documents", isDirectory: true))
        let notes = root.appendingPathComponent("excerpts.json")
        if FileManager.default.fileExists(atPath: notes.path) {
            try protectFile(notes)
        }
        return root
    }

    static func secureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        var mutableURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    static func protectFile(_ fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        var mutableURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
