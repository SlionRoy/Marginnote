import CryptoKit
import Foundation

struct ImportedPDF: Sendable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let wasCopied: Bool
}

enum DocumentImportError: LocalizedError {
    case unavailableFile
    case invalidStoredName
    case storedFileChanged
    case copyMismatch
    case missingStoredFile
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .unavailableFile: "无法读取所选 PDF。"
        case .invalidStoredName: "上次打开的文件记录无效。"
        case .storedFileChanged: "应用内已有同名 PDF，但内容与记录不符。"
        case .copyMismatch: "导入 PDF 时复制内容未通过校验。"
        case .missingStoredFile: "上次打开的 PDF 副本已不存在，请重新导入。"
        case .invalidPDF: "PDF 内容无法打开，文件可能已损坏。"
        }
    }
}

enum DocumentImport {
    private static let lastFileKey = "StudyReader.lastPDFFile"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("StudyReader", isDirectory: true)
    }

    static func copyIntoLibrary(_ source: URL,
                                libraryDirectory: URL? = nil) throws -> ImportedPDF {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }

        let bytes = try digest(of: source)
        guard bytes.count >= 16 else { throw DocumentImportError.unavailableFile }
        let fileName = bytes.map { String(format: "%02x", $0) }.joined() + ".pdf"
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                             bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11],
                             bytes[12], bytes[13], bytes[14], bytes[15]))
        let directory: URL
        if let libraryDirectory {
            directory = libraryDirectory
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } else {
            directory = try StorageProtection.prepareLibrary()
                .appendingPathComponent("Documents", isDirectory: true)
        }
        let target = directory.appendingPathComponent(fileName)
        let copied = !FileManager.default.fileExists(atPath: target.path)
        if copied {
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            guard try digest(of: temporary) == bytes else {
                throw DocumentImportError.copyMismatch
            }
            if libraryDirectory == nil { try StorageProtection.protectFile(temporary) }
            try FileManager.default.moveItem(at: temporary, to: target)
        } else {
            guard try digest(of: target) == bytes else {
                throw DocumentImportError.storedFileChanged
            }
            if libraryDirectory == nil { try StorageProtection.protectFile(target) }
        }
        return ImportedPDF(id: id, fileURL: target, fileName: fileName, wasCopied: copied)
    }

    static func remember(_ document: ImportedPDF,
                         preferences: UserDefaults = .standard) {
        preferences.set(document.fileName, forKey: lastFileKey)
    }

    static func lastDocument(libraryDirectory: URL? = nil,
                             preferences: UserDefaults = .standard) throws -> ImportedPDF? {
        guard let name = preferences.string(forKey: lastFileKey) else {
            return nil
        }
        guard name.count == 68, name.hasSuffix(".pdf"),
              name.dropLast(4).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw DocumentImportError.invalidStoredName
        }
        let expectedDigest = String(name.dropLast(4))
        let bytes = stride(from: 0, to: 32, by: 2).compactMap { offset -> UInt8? in
            let start = expectedDigest.index(expectedDigest.startIndex, offsetBy: offset)
            let end = expectedDigest.index(start, offsetBy: 2)
            return UInt8(expectedDigest[start..<end], radix: 16)
        }
        guard bytes.count == 16 else { throw DocumentImportError.invalidStoredName }
        let fileURL = (libraryDirectory ?? supportDirectory.appendingPathComponent(
            "Documents", isDirectory: true))
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DocumentImportError.missingStoredFile
        }
        let currentDigest = try digest(of: fileURL)
            .map { String(format: "%02x", $0) }.joined()
        guard currentDigest == expectedDigest else {
            throw DocumentImportError.storedFileChanged
        }
        if libraryDirectory == nil { try StorageProtection.protectFile(fileURL) }
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                             bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11],
                             bytes[12], bytes[13], bytes[14], bytes[15]))
        return ImportedPDF(id: id, fileURL: fileURL, fileName: name, wasCopied: false)
    }

    private static func digest(of fileURL: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Array(hasher.finalize())
    }
}
