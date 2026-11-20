import Foundation

public enum LocalFileService {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static func listDirectory(at url: URL, showHidden: Bool) throws -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey
        ]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        return urls.compactMap { itemURL in
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false
            let size = Int64(values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate
            let modText = modDate.map { dateFormatter.string(from: $0) } ?? ""

            return FileEntry(
                name: itemURL.lastPathComponent,
                path: itemURL.path,
                isDirectory: isDir,
                isSymlink: isLink,
                symlinkTarget: nil,
                size: size,
                modifiedDate: modDate,
                modifiedText: modText,
                permissions: "",
                isRemote: false
            )
        }
    }

    public static func createDirectory(in parentURL: URL, name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw ADBError.invalidInput("Invalid folder name.")
        }
        let target = parentURL.appendingPathComponent(trimmed, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    public static func rename(itemAt url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw ADBError.invalidInput("Invalid name.")
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public static func trashItems(at urls: [URL]) throws {
        let fm = FileManager.default
        for url in urls {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    public static func sortEntries(_ entries: [FileEntry], by column: SortColumn, ascending: Bool) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            // Always keep folders grouped before files
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let result: ComparisonResult
            switch column {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.size == rhs.size {
                    result = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    result = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            case .date:
                let lDate = lhs.modifiedDate ?? .distantPast
                let rDate = rhs.modifiedDate ?? .distantPast
                if lDate == rDate {
                    result = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    result = lDate < rDate ? .orderedAscending : .orderedDescending
                }
            }
            return ascending ? (result == .orderedAscending) : (result == .orderedDescending)
        }
    }
}
