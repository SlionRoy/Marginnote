import Foundation

public enum StudyStoreError: LocalizedError, Equatable, Sendable {
    case invalidData
    case unsupportedVersion(Int)
    case duplicateIdentifier
    case sourceChanged
    case staleRevision
    case invalidArchive
    case unsupportedArchiveVersion(Int)
    case archiveTooLarge
    case archiveConflict

    public var errorDescription: String? {
        switch self {
        case .invalidData: "笔记文件已损坏，现有数据未被覆盖。"
        case .unsupportedVersion: "笔记文件版本尚不支持。"
        case .duplicateIdentifier: "笔记文件中有重复记录。"
        case .sourceChanged: "摘录来源与已保存记录不一致。"
        case .staleRevision: "已有更新的笔记版本。"
        case .invalidArchive: "所选文件不是有效的摘录备份。"
        case .unsupportedArchiveVersion: "摘录备份版本尚不支持。"
        case .archiveTooLarge: "摘录备份超过 20 MB 限制。"
        case .archiveConflict: "备份中的摘录与现有来源冲突，未导入任何记录。"
        }
    }
}

private struct ExcerptFile: Codable {
    let schemaVersion: Int
    var excerpts: [StudyExcerpt]
}

private struct ExcerptArchive: Codable {
    let format: String
    let version: Int
    let excerpts: [StudyExcerpt]
}

public struct ArchiveMergeResult: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int
    public let unchanged: Int
}

/// A single-writer local store. The caller supplies an Application Support file URL.
public actor ExcerptFileStore {
    private static let currentVersion = 1
    private static let archiveFormat = "studyreader-excerpts"
    private static let archiveVersion = 1
    public static let maximumArchiveBytes = 20 * 1_024 * 1_024
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() throws -> [StudyExcerpt] {
        try readFile().excerpts
    }

    /// Export only independent note data. Matching PDFs must be imported separately.
    public func exportArchive() throws -> Data {
        let file = try readFile()
        let archive = ExcerptArchive(format: Self.archiveFormat,
                                     version: Self.archiveVersion,
                                     excerpts: file.excerpts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumArchiveBytes else {
            throw StudyStoreError.archiveTooLarge
        }
        return data
    }

    /// Merge atomically; source conflicts reject the entire incoming archive.
    public func mergeArchive(_ data: Data) throws -> ArchiveMergeResult {
        guard data.count <= Self.maximumArchiveBytes else {
            throw StudyStoreError.archiveTooLarge
        }
        let archive: ExcerptArchive
        do {
            archive = try JSONDecoder().decode(ExcerptArchive.self, from: data)
        } catch {
            throw StudyStoreError.invalidArchive
        }
        guard archive.format == Self.archiveFormat else {
            throw StudyStoreError.invalidArchive
        }
        guard archive.version == Self.archiveVersion else {
            throw StudyStoreError.unsupportedArchiveVersion(archive.version)
        }
        guard Set(archive.excerpts.map(\.id)).count == archive.excerpts.count else {
            throw StudyStoreError.invalidArchive
        }

        var file = try readFile()
        var indices = Dictionary(uniqueKeysWithValues:
            file.excerpts.enumerated().map { ($0.element.id, $0.offset) })
        var inserted = 0
        var updated = 0
        var unchanged = 0
        for incoming in archive.excerpts {
            if let index = indices[incoming.id] {
                let current = file.excerpts[index]
                guard current.selection == incoming.selection,
                      current.createdAt == incoming.createdAt else {
                    throw StudyStoreError.archiveConflict
                }
                if incoming.updatedAt > current.updatedAt {
                    file.excerpts[index] = incoming
                    updated += 1
                } else if incoming.updatedAt == current.updatedAt,
                          incoming != current {
                    throw StudyStoreError.archiveConflict
                } else {
                    unchanged += 1
                }
            } else {
                indices[incoming.id] = file.excerpts.count
                file.excerpts.append(incoming)
                inserted += 1
            }
        }
        if inserted > 0 || updated > 0 { try writeFile(file) }
        return ArchiveMergeResult(inserted: inserted, updated: updated,
                                  unchanged: unchanged)
    }

    public func upsert(_ excerpt: StudyExcerpt) throws {
        var file = try readFile()
        if let index = file.excerpts.firstIndex(where: { $0.id == excerpt.id }) {
            let previous = file.excerpts[index]
            guard previous.selection == excerpt.selection,
                  previous.createdAt == excerpt.createdAt else {
                throw StudyStoreError.sourceChanged
            }
            guard excerpt.updatedAt > previous.updatedAt || excerpt == previous else {
                throw StudyStoreError.staleRevision
            }
            file.excerpts[index] = excerpt
        } else {
            file.excerpts.append(excerpt)
        }
        try writeFile(file)
    }

    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        var file = try readFile()
        guard let index = file.excerpts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        file.excerpts.remove(at: index)
        try writeFile(file)
        return true
    }

    private func readFile() throws -> ExcerptFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ExcerptFile(schemaVersion: Self.currentVersion, excerpts: [])
        }
        let data = try Data(contentsOf: fileURL)
        let file: ExcerptFile
        do {
            file = try JSONDecoder().decode(ExcerptFile.self, from: data)
        } catch {
            throw StudyStoreError.invalidData
        }
        guard file.schemaVersion == Self.currentVersion else {
            throw StudyStoreError.unsupportedVersion(file.schemaVersion)
        }
        guard Set(file.excerpts.map(\.id)).count == file.excerpts.count else {
            throw StudyStoreError.duplicateIdentifier
        }
        return file
    }

    private func writeFile(_ file: ExcerptFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication
        ])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}
