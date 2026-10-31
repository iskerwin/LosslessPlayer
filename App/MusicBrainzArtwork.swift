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

/// The services a cover lookup asks, by the names the notice shows.
enum CoverSource: String {
    case musicBrainz = "MusicBrainz"
    case coverArtArchive = "Cover Art Archive"
    case apple = "Apple Music"
    case netease = "网易云音乐"
}

/// How 更新封面 ended for one song or album, specific enough to act on:
/// fix the tags, check the spelling, retry later, or accept there is none.
enum CoverUpdate: Equatable {
    case found
    /// The song has no 歌名 or 艺术家 to search with.
    case incomplete(String)
    /// No catalog has this artist's work, but one has the same title by `found`.
    case otherArtist(found: String, local: String)
    /// Services that did not answer.
    case unreachable([String])
    /// Listed, without an image anywhere.
    case noImage(String)
    case notFound(String)
    case changed

    var title: String {
        switch self {
        case .found: return "已更新"
        case .incomplete: return "信息不全"
        case .otherArtist: return "信息可能不对"
        case .unreachable: return "网络问题"
        case .noImage: return "没有封面图"
        case .notFound: return "没有找到"
        case .changed: return "信息有变动"
        }
    }

    var message: String {
        switch self {
        case .found: return "已更新封面。"
        case .incomplete(let field):
            return "歌曲信息不全：缺少\(field)，无法查找。请在文件标签里补上\(field)，或把文件名改成「歌名-艺术家」。"
        case .otherArtist(let found, let local):
            return "歌曲信息可能不对：曲库里有同名作品，但艺术家是「\(found)」，不是「\(local)」。请检查歌名和艺术家的写法。"
        case .unreachable(let services):
            return "网络问题：连不上 \(services.joined(separator: "、"))，请稍后重试。"
        case .noImage(let subject): return "找到了「\(subject)」，但各来源都没有它的封面图。"
        case .notFound(let subject):
            return "各来源都没有找到「\(subject)」：可能不在这些曲库里，或歌名、艺术家的写法不同。"
        case .changed: return "歌曲信息刚刚有变动，请再试一次。"
        }
    }
}

/// 更新封面's progress while it runs.
struct CoverProgress: Equatable {
    var done: Int
    var total: Int
}

/// One line of 更新封面's report: an album, or a song with no album.
struct CoverReportItem: Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var result: CoverUpdate
}

struct CoverReport: Identifiable, Equatable {
    let id = UUID()
    var items: [CoverReportItem]
}

enum MusicBrainzApplyError: LocalizedError {
    case changed
    var errorDescription: String? { "曲目信息已变更或正在扫描，请关闭后重新识别。" }
}
