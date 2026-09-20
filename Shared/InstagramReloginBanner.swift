import SwiftUI

/// Instagram のセッション切れを知らせて再ログインへ誘導するバナー。
/// 本体アプリと共有シート拡張で同じものを使う
struct InstagramReloginBanner: View {
    let onRelogin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Instagramのセッションが切れました")
                    .font(.footnote.bold())
                Text("カルーセル全枚数・非公開投稿は再ログインが必要です")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("再ログイン", action: onRelogin)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
