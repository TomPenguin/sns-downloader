import SwiftUI

// MARK: - 進行中ジョブのカプセル表示

/// 1 ジョブ分の進行状況。本体アプリと共有シート拡張で同じものを使う
struct JobCapsule: View {
    let job: DownloadJob
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.status.label)
                        .font(.footnote)
                }

                Spacer()

                if case .failed = job.status {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if case .downloading(_, _, let fraction) = job.status {
                ProgressView(value: fraction)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var displayURL: String {
        let host = (job.sourceURL.host ?? "").replacingOccurrences(of: "www.", with: "")
        return host + job.sourceURL.path
    }

    private var iconName: String {
        switch job.status {
        case .waiting: return "clock"
        case .extracting: return "magnifyingglass"
        case .selecting: return "checklist"
        case .downloading: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
