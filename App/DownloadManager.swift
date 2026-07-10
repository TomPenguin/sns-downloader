import Foundation
import SwiftUI

struct DownloadJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var status: JobStatus = .waiting
}

/// 複数メディアの投稿で「どれを保存するか」をユーザーに選ばせるための保留状態
struct PendingSelection: Identifiable {
    let id = UUID()
    let jobID: UUID
    let items: [MediaItem]
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    /// 現在表示中の選択シート(nil なら非表示)
    @Published var activeSelection: PendingSelection?

    private var selectionQueue: [PendingSelection] = []

    // MARK: - ジョブの追加

    /// テキストから URL を取り出してジョブに追加し、順番に処理する
    func addAndStart(text: String) {
        let urls = HTTP.allURLs(in: text)
        guard !urls.isEmpty else { return }

        // 処理中・処理済みと同じ URL は追加しない
        let existing = Set(jobs.map(\.sourceURL.absoluteString))
        let newURLs = urls.filter { !existing.contains($0.absoluteString) }

        for url in newURLs {
            let job = DownloadJob(sourceURL: url)
            jobs.insert(job, at: 0)
            start(jobID: job.id, url: url)
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status.isFinished else { return }
        jobs[index].status = .waiting
        start(jobID: jobID, url: jobs[index].sourceURL)
    }

    // MARK: - メディア選択

    /// 選択シートで「保存」が押された
    func confirmSelection(_ selection: PendingSelection, selectedIndices: Set<Int>) {
        activeSelection = nil
        let items = selection.items.enumerated()
            .filter { selectedIndices.contains($0.offset) }
            .map(\.element)

        if items.isEmpty {
            update(jobID: selection.jobID, status: .failed("キャンセルしました"))
        } else {
            let jobID = selection.jobID
            Task {
                _ = await DownloadPipeline.downloadAndSave(items: items) { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.update(jobID: jobID, status: status)
                    }
                }
            }
        }
        presentNextSelectionLater()
    }

    /// 選択シートが閉じられた(スワイプで閉じた場合も含む)
    func cancelSelection(_ selection: PendingSelection) {
        activeSelection = nil
        update(jobID: selection.jobID, status: .failed("キャンセルしました"))
        presentNextSelectionLater()
    }

    /// シートの onDismiss。confirm/cancel を経ずに閉じられたときの後始末
    func handleSelectionDismiss() {
        if let selection = activeSelection {
            cancelSelection(selection)
        }
    }

    // MARK: - 内部処理

    private func start(jobID: UUID, url: URL) {
        Task {
            update(jobID: jobID, status: .extracting)
            do {
                let items = try await ExtractorRouter.extract(from: url)
                if items.count > 1 {
                    // 複数メディア → ユーザーに選択させる
                    update(jobID: jobID, status: .selecting)
                    enqueueSelection(PendingSelection(jobID: jobID, items: items))
                } else {
                    _ = await DownloadPipeline.downloadAndSave(items: items) { [weak self] status in
                        Task { @MainActor [weak self] in
                            self?.update(jobID: jobID, status: status)
                        }
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                update(jobID: jobID, status: .failed(message))
            }
        }
    }

    private func enqueueSelection(_ selection: PendingSelection) {
        if activeSelection == nil {
            activeSelection = selection
        } else {
            selectionQueue.append(selection)
        }
    }

    /// シートの閉じるアニメーションと被らないよう少し待ってから次の選択を表示する
    private func presentNextSelectionLater() {
        guard !selectionQueue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.activeSelection == nil, !self.selectionQueue.isEmpty else { return }
            self.activeSelection = self.selectionQueue.removeFirst()
        }
    }

    private func update(jobID: UUID, status: JobStatus) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = status
    }
}
