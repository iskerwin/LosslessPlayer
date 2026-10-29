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

enum MusicBrainzApplyError: LocalizedError {
    case changed
    var errorDescription: String? { "曲目信息已变更或正在扫描，请关闭后重新识别。" }
}
