import ActivityKit
import SwiftUI
import WidgetKit

// Paper design tokens, mirrored from the app (ContentView.swift). The widget
// extension can't see the app module, so the values are duplicated here —
// keep in sync if the app palette ever changes.
private extension Color {
    static let paperBackground = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
            : UIColor(red: 0.976, green: 0.969, blue: 0.957, alpha: 1)
    })

    static let paperInk = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.91, green: 0.90, blue: 0.88, alpha: 1)
            : UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1)
    })

    static let paperRule = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.46, blue: 0.44, alpha: 1)
            : UIColor(red: 0.50, green: 0.48, blue: 0.45, alpha: 1)
    })

    static let paperError = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.44, blue: 0.16, alpha: 1)
            : UIColor(red: 0.48, green: 0.28, blue: 0.05, alpha: 1)
    })
}

struct AirBookSyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            SyncLockScreenView(state: context.state)
                .activityBackgroundTint(Color.paperBackground)
                .activitySystemActionForegroundColor(Color.paperInk)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.failed
                          ? "exclamationmark.triangle" : "book.closed.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let progress = context.state.progress, !context.state.finished {
                        Text(percentText(progress))
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                        .font(.system(.subheadline, design: .serif).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.system(.caption, design: .serif))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        if let progress = context.state.progress {
                            InkProgressBar(progress: progress, tint: .white)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.failed
                      ? "exclamationmark.triangle" : "book.closed.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                if context.state.finished {
                    Image(systemName: context.state.failed ? "xmark" : "checkmark")
                        .foregroundStyle(.white)
                } else if let progress = context.state.progress {
                    Text(percentText(progress))
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.white)
                }
            } minimal: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.white)
            }
        }
    }
}

private func percentText(_ progress: Double) -> String {
    "\(Int((progress * 100).rounded()))%"
}

// MARK: - Lock screen banner

private struct SyncLockScreenView: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Masthead, echoing the app's serif wordmark + rule lines.
            HStack(spacing: 6) {
                (Text("Air").font(.system(.footnote, design: .serif).weight(.light))
                    + Text("Book").font(.system(.footnote, design: .serif).weight(.bold)))
                    .foregroundStyle(Color.paperInk)
                Text("· CROSSPOINT SYNC")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.paperRule)
                Spacer()
                if state.finished {
                    Image(systemName: state.failed ? "exclamationmark.triangle" : "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(state.failed ? Color.paperError : Color.paperInk)
                }
            }

            Rectangle()
                .fill(Color.paperInk)
                .frame(height: 1)

            Text(state.status)
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(state.failed ? Color.paperError : Color.paperInk)
                .lineLimit(1)

            if !state.detail.isEmpty {
                Text(state.detail)
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(Color.paperRule)
                    .lineLimit(1)
            }

            if let progress = state.progress, !state.finished {
                HStack(spacing: 8) {
                    InkProgressBar(progress: progress, tint: .paperInk)
                    Text(percentText(progress))
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color.paperInk)
                }
            }
        }
        .padding(14)
    }
}

// Thin ruled progress bar — a hairline track with an ink fill, matching the
// app's e-paper aesthetic instead of the system rounded bar.
private struct InkProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(tint.opacity(0.25))
                Rectangle()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
    }
}
