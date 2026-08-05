import Foundation

// MARK: - Book Library Status
//
// What the library grid shows for a single book at a glance. Composed by
// BookStore.libraryStatus(for:sync:) from deviceStates, pendingFileRemovals,
// sentBookIDs and (when a sync is in flight) the SyncManager's per-entry
// action.

enum BookLibraryStatus: Equatable {
    /// Book exists only locally — never sent.
    case notOnDevice
    /// Active upload, with 0…1 progress.
    case uploading(progress: Double)
    /// Entry + file on device, ready to read.
    case syncedFull
    /// Entry on device, file freed by the user to save space.
    case syncedEntryOnly
    /// On device but not owned by this app.
    case foreign
    /// Planned for the next sync.
    case queuedForUpload
    /// User asked to free space at next sync.
    case queuedForFileRemoval
    /// Local deletion will propagate at next sync.
    case queuedForEntryDeletion
    /// Last attempt failed with the bundled message.
    case failed(String)
    /// No info yet (e.g. first launch, never synced).
    case unknown
}

extension BookStore {
    /// Live-or-static badge for the library grid. Pass the active sync to
    /// surface in-flight transitions; pass nil to read just the last known
    /// device state.
    func libraryStatus(for book: Book, sync: SyncManager? = nil) -> BookLibraryStatus {
        // In-flight state from the active sync overrides the static view.
        if let sync, sync.phase.isActive,
           let entry = sync.bookEntries.first(where: { $0.id == book.id }) {
            switch entry.action {
            case .uploading:
                return .uploading(progress: entry.progress)
            case .willUpload:
                return .queuedForUpload
            case .uploaded, .alreadyPresent:
                return .syncedFull
            case .willDeleteEntry, .deletingEntry, .entryDeleted:
                return .queuedForEntryDeletion
            case .willRemoveFile, .removingFile:
                return .queuedForFileRemoval
            case .fileRemoved:
                return .syncedEntryOnly
            case .foreign:
                return .foreign
            case .failed(let message):
                return .failed(message)
            case .keep, .keepEntryOnly:
                break  // fall through to static state
            }
        }

        // Static state: user-queued operations win over the raw device snapshot.
        if pendingFileRemovals.contains(book.id) {
            return .queuedForFileRemoval
        }
        switch deviceStates[book.id] {
        case .some(.filePresent): return .syncedFull
        case .some(.entryOnly):   return .syncedEntryOnly
        case .some(.absent):      return .notOnDevice
        case .none:               return .notOnDevice
        }
    }
}
