import Foundation
import ImageIO

extension AudioScanner {
    /// CAA data uses the scanner's existing 700px JPEG storeThumbnail path.
    /// A fresh cache ID avoids overwriting thumbnails during an intervening scan.
    func storeThumbnail(data: Data) -> String? {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return storeThumbnail(source, id: UUID())
    }
}

/// How 更新封面 ended. A request that went unanswered reads differently
/// from services that answered but had no cover.
enum CoverUpdate: Equatable {
    case found, notFound, unreachable, changed
    var message: String {
        switch self {
        case .found: return "已更新封面。"
        case .notFound: return "没有找到这首歌的封面。"
        case .unreachable: return "网络问题：连不上专辑信息或封面服务，请稍后重试。"
        case .changed: return "歌曲信息刚刚有变动，请再试一次。"
        }
    }
}

enum MusicBrainzApplyError: LocalizedError {
    case changed
    var errorDescription: String? { "曲目信息已变更或正在扫描，请关闭后重新识别。" }
}
