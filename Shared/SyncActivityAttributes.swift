import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and the widget
/// extension (renders it). Lives in Shared/ which is a member of both
/// targets.
struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Headline, mirrors SyncPhase.statusMessage ("Sending books (2/5)").
        var status: String
        /// Current book title while uploading, error detail on failure.
        var detail: String
        /// Overall byte progress 0...1; nil while scanning/connecting.
        var progress: Double?
        var finished: Bool
        var failed: Bool
    }
}
