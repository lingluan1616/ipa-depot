import AppKit
import Foundation
import Observation
import IPADepotCore

/// 图标与开发者名的界面缓存：按需向 `AppLookupProviding` 请求，结果放内存供多处复用。
@MainActor
@Observable
final class ArtworkStore {
    private(set) var images: [Int64: NSImage] = [:]
    private(set) var developers: [Int64: String] = [:]

    @ObservationIgnored private let lookup: AppLookupProviding
    @ObservationIgnored private var requested: Set<Int64> = []

    init(lookup: AppLookupProviding) {
        self.lookup = lookup
    }

    func request(_ appID: Int64) async {
        guard requested.insert(appID).inserted else { return }
        let lookup = self.lookup
        if let info = await lookup.info(appID: appID), let artist = info.artistName, !artist.isEmpty {
            developers[appID] = artist
        }
        if let file = await lookup.artworkFile(appID: appID), let image = NSImage(contentsOf: file) {
            images[appID] = image
        }
    }

    /// 清理缓存后调用：丢掉内存里的引用，下次显示时重新请求。
    func reset() {
        images = [:]
        developers = [:]
        requested = []
    }
}
