import Foundation

/// AVFoundation does not expose every custom Vorbis field on every iOS version.
/// Read only bounded FLAC metadata blocks; never load the audio payload into RAM.
enum FLACComments {
    static func read(_ url: URL) throws -> [String: [String]] {
        guard url.pathExtension.lowercased() == "flac" else { return [:] }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return [:] }
        for _ in 0..<128 {
            try Task.checkCancellation()
            guard let header = try file.read(upToCount: 4), header.count == 4 else { return [:] }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if header[0] & 0x7f == 4 {
                guard length <= 4 * 1024 * 1024, let data = try file.read(upToCount: length), data.count == length else { return [:] }
                return parse(data)
            }
            if header[0] & 0x80 != 0 { return [:] }
            try file.seek(toOffset: file.offsetInFile + UInt64(length))
        }
        return [:]
    }

    static func parse(_ data: Data) -> [String: [String]] {
        var offset = 0
        func integer() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard let vendor = integer(), vendor <= data.count - offset else { return [:] }
        offset += vendor
        guard let count = integer(), count <= 100_000 else { return [:] }
        var result: [String: [String]] = [:]
        for _ in 0..<count {
            guard let length = integer(), length <= data.count - offset else { return [:] }
            let text = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8)
            offset += length
            if let text, let separator = text.firstIndex(of: "=") {
                let key = String(text[..<separator]).uppercased()
                result[key, default: []].append(String(text[text.index(after: separator)...]))
            }
        }
        return result
    }
}
