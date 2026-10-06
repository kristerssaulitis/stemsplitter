import SwiftUI
import StemCore

// MARK: - HistoryView

/// The saved-splits sheet: one row per completed split (title + date), tap to
/// reopen the mixer, swipe to delete. Deletion removes the session's stem WAVs
/// for good — the swipe-step is the confirmation, Music-app style.
public struct HistoryView: View {

    @ObservedObject var model: HistoryModel
    let onClose: () -> Void
    let onOpen: (HistoryModel.Entry) -> Void

    public init(model: HistoryModel, onClose: @escaping () -> Void, onOpen: @escaping (HistoryModel.Entry) -> Void) {
        self.model = model
        self.onClose = onClose
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if model.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color.ssGround.ignoresSafeArea())
        .onAppear { model.reload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.ssSurface))
            }
            .accessibilityLabel("Close history")

            VStack(spacing: 1) {
                Text("History")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.ssTextPrimary)
                if model.entries.isEmpty == false {
                    Text(footerLine)
                        .font(.caption)
                        .foregroundStyle(Color.ssTextSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.ssTextPrimary)
        .padding(.horizontal, DesignSystem.Spacing.unit2)
        .padding(.vertical, 8)
    }

    /// "3 splits · 128 MB on this iPhone" — the size line is the delete nudge.
    private var footerLine: String {
        let count = model.entries.count
        let bytes = ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file)
        return "\(count) \(count == 1 ? "split" : "splits") · \(bytes) on this iPhone"
    }

    private var list: some View {
        List {
            ForEach(model.entries) { entry in
                Button { onOpen(entry) } label: {
                    HistoryRow(entry: entry)
                }
                .listRowBackground(Color.ssSurface)
                .listRowSeparatorTint(Color.ssTextSecondary.opacity(0.2))
            }
            .onDelete { offsets in
                for index in offsets {
                    model.delete(model.entries[index])
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.ssTextSecondary.opacity(0.6))
            Text("No saved splits yet")
                .font(.headline)
                .foregroundStyle(Color.ssTextPrimary)
            Text("Every split you finish is kept here,\nready to play and export again.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ssTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct HistoryRow: View {

    let entry: HistoryModel.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.ssAccent.opacity(0.18)))
                .foregroundStyle(Color.ssAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ssTextPrimary)
                    .lineLimit(1)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Color.ssTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ssTextSecondary.opacity(0.6))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
