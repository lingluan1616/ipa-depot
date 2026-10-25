import Foundation
import Observation
import IPADepotCore

/// 下载记录（`history.json`）。新记录在前。
@MainActor
@Observable
final class HistoryViewModel {
    private(set) var records: [DownloadRecord] = []
    private(set) var saveError: ErrorPresentation?

    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let fileExists: (String) -> Bool

    init(store: HistoryStore, fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.store = store
        self.fileExists = fileExists
        records = store.load().sorted { $0.completedAt > $1.completedAt }
    }

    func exists(_ record: DownloadRecord) -> Bool { fileExists(record.path) }

    func add(_ record: DownloadRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        persist()
    }

    func remove(_ id: DownloadRecord.ID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    private func persist() {
        do {
            try store.save(records)
            saveError = nil
        } catch {
            saveError = ErrorPresentation(message: String(localized: "无法保存下载记录。"), raw: error.localizedDescription)
        }
    }
}
