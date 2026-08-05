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

enum LibraryBackup {
    /// Stage the library into a temp dir → produce a .zip → return its URL.
    /// The returned URL points at a file in NSTemporaryDirectory; the
    /// caller is responsible for sharing it before another backup overwrites
    /// the same path.
    nonisolated static func createBackupArchive() throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Whitelist user-owned library data. Caches, downloads, device-file
        // exports, and OTA staging files are intentionally regenerable.
        let foldersToInclude = ["Books", "BookState", "Covers"]
        let filesToInclude = ["books_meta.json", "collections.json",
                              "opds_servers.json", "device_state.json"]

        // Use a per-invocation staging dir so two backups in flight don't
        // collide. The dir gets removed on the way out.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        let datestamp = formatter.string(from: Date())
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
        defer { try? fm.removeItem(at: stageRoot) }

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
        do {
            try readme.data(using: .utf8)?.write(to: stage.appendingPathComponent("README.txt"))
        } catch {
            throw LibraryBackupError.stagingFailed(error.localizedDescription)
        }

        do {
            for folder in foldersToInclude {
                let src = docs.appendingPathComponent(folder)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = stage.appendingPathComponent(folder)
                try fm.copyItem(at: src, to: dst)
            }
            for file in filesToInclude {
                let src = docs.appendingPathComponent(file)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = stage.appendingPathComponent(file)
                try fm.copyItem(at: src, to: dst)
            }
        } catch {
            throw LibraryBackupError.stagingFailed(error.localizedDescription)
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
        if let coordError {
            throw LibraryBackupError.zipFailed(coordError.localizedDescription)
        }
        guard let url = producedURL else {
            throw LibraryBackupError.zipFailed("File coordinator produced no output")
        }
        return url
    }
}
