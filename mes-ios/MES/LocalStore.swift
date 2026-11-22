import Foundation

enum MESError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

/// Called on the bridge's serial storage queue.
struct LocalStore {
    let root: URL
    private let fm = FileManager.default

    private func record(_ group: String, _ key: String) throws -> URL {
        guard group == "photos" || group == "progress", !key.isEmpty, key.utf8.count <= 2048 else {
            throw MESError.message("本機紀錄識別碼無效。")
        }
        var remaining = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        var dir = root.appendingPathComponent(group, isDirectory: true)
        while remaining.count > 100 {
            dir.appendPathComponent(String(remaining.prefix(100)), isDirectory: true)
            remaining.removeFirst(100)
        }
        return dir.appendingPathComponent(remaining + ".txt")
    }

    func read(_ group: String, _ key: String) throws -> String {
        let file = try record(group, key)
        do { return try String(contentsOf: file, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
    }

    func write(_ group: String, _ key: String, _ value: String) throws {
        let file = try record(group, key)
        try prepare(file.deletingLastPathComponent())
        try Data(value.utf8).write(to: file, options: .atomic)
    }

    func removePhotos(_ keys: [String]) throws {
        for key in keys {
            let file = try record("photos", key)
            do { try fm.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    private func prepare(_ directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var privateRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateRoot.setResourceValues(values)
        #endif
    }

    static func writeExport(_ name: String, data: Data, directory: URL) throws -> URL {
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)).joined(separator: "_")
        let suffix = (safeName as NSString).pathExtension.lowercased()
        guard ["html", "json"].contains(suffix) else { throw MESError.message("不支援的匯出格式。") }
        let basename = String((safeName as NSString).deletingPathExtension.prefix(90))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var exportDir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try exportDir.setResourceValues(values)
        #endif
        for index in 0..<1000 {
            let ending = index == 0 ? "" : " (\(index))"
            let file = directory.appendingPathComponent(basename + ending + "." + suffix)
            if FileManager.default.fileExists(atPath: file.path) { continue }
            try data.write(to: file, options: .atomic)
            return file
        }
        throw MESError.message("同名匯出檔案過多。")
    }
}
