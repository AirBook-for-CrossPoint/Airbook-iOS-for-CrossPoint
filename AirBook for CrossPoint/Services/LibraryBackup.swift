import Foundation

// MARK: - Library backup
//
// Single-shot zip exporter for the iOS library. Walks the Documents
// directory and stages the user-meaningful subfolders (books, covers,
// reading-state sidecars, the books metadata index) into a temp dir,
// then uses NSFileCoordinator with .forUploading to compress the
// directory into a .zip and produce a URL the caller can share.
//
// We don't bring in a third-party zip dependency — NSFileCoordinator's
// "forUploading" reading option is the documented Apple way to
// generate a zip for sharing on iOS.

enum LibraryBackupError: Error, LocalizedError {
    case stagingFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .stagingFailed(let m): return "Couldn't prepare backup: \(m)"
        case .zipFailed(let m):     return "Couldn't compress backup: \(m)"
        }
    }
}

@MainActor
enum LibraryBackup {
    /// Whitelist of Documents subdirectories that go into the backup. Skips
    /// `metadata_cache/` (regenerable, large), `DeviceFiles/`, `zlib_download/`,
    /// the OTA staging files, etc.
    private static let foldersToInclude = ["Books", "BookState", "Covers"]
    /// JSON manifests that live at the Documents root.
    private static let filesToInclude = ["books_meta.json", "collections.json",
                                          "opds_servers.json"]

    /// Stage the library into a temp dir → produce a .zip → return its URL.
    /// The returned URL points at a file in NSTemporaryDirectory; the
    /// caller is responsible for sharing it before another backup overwrites
    /// the same path.
    static func createBackupArchive() throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Use a per-invocation staging dir so two backups in flight don't
        // collide. The dir gets removed on the way out.
        let datestamp = ISO8601DateFormatter.dateOnly.string(from: Date())
        let stageRoot = fm.temporaryDirectory
            .appendingPathComponent("AirBookBackup-\(datestamp)-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        let stage = stageRoot.appendingPathComponent("AirBook-\(datestamp)", isDirectory: true)
        try? fm.removeItem(at: stageRoot)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        } catch {
            throw LibraryBackupError.stagingFailed(error.localizedDescription)
        }

        // Drop a tiny README so a curious user opening the zip understands
        // what each folder is.
        let readme = """
        AirBook for CrossPoint — Library Backup
        Exported \(Date().formatted(date: .abbreviated, time: .shortened))

        Books/        — original ebook files (epub, txt, bmp, xtc, xtch)
        BookState/    — per-book reading state (progress, bookmarks, highlights)
        Covers/       — extracted / downloaded cover images
        books_meta.json    — title/author/metadata index
        collections.json   — collection tags
        opds_servers.json  — OPDS servers configured in the app
        """
        try? readme.data(using: .utf8)?.write(to: stage.appendingPathComponent("README.txt"))

        for folder in foldersToInclude {
            let src = docs.appendingPathComponent(folder)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = stage.appendingPathComponent(folder)
            try? fm.copyItem(at: src, to: dst)
        }
        for file in filesToInclude {
            let src = docs.appendingPathComponent(file)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = stage.appendingPathComponent(file)
            try? fm.copyItem(at: src, to: dst)
        }

        // NSFileCoordinator's .forUploading reading option produces a zip
        // for the coordinated URL into a temporary location. We get a
        // chance to move it somewhere stable inside the block.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var producedURL: URL?
        coordinator.coordinate(readingItemAt: stage,
                               options: [.forUploading],
                               error: &coordError) { tempZipURL in
            let outputName = "AirBook-\(datestamp).zip"
            let dest = fm.temporaryDirectory.appendingPathComponent(outputName)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: tempZipURL, to: dest)
                producedURL = dest
            } catch {
                producedURL = nil
            }
        }
        // Drop the staging copy whether we succeeded or not — it's heavy.
        try? fm.removeItem(at: stageRoot)

        if let coordError {
            throw LibraryBackupError.zipFailed(coordError.localizedDescription)
        }
        guard let url = producedURL else {
            throw LibraryBackupError.zipFailed("File coordinator produced no output")
        }
        return url
    }
}

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        return f
    }()
}
