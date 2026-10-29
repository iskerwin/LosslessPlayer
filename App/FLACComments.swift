import Foundation

/// AVFoundation does not expose every custom Vorbis field on every iOS version.
/// Read only bounded FLAC metadata blocks; never load the audio payload into RAM.
enum FLACComments {
    // Match the existing AVAsset artwork limit (strictly less than 12 MB).
    static let artworkByteLimit = 12_000_000

    struct Metadata {
        var comments: [String: [String]] = [:]
        var picture: Data?
    }

    static func read(_ url: URL) throws -> [String: [String]] {
        try readMetadata(url).comments
    }

    static func readMetadata(_ url: URL) throws -> Metadata {
        var result = Metadata()
        guard url.pathExtension.lowercased() == "flac" else { return result }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let fileEnd = try file.seekToEnd()
        try file.seek(toOffset: 0)
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return result }
        var foundComments = false
        var foundFrontCover = false
        for _ in 0..<128 {
            try Task.checkCancellation()
            guard let header = try file.read(upToCount: 4), header.count == 4 else { break }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let start = file.offsetInFile
            guard start <= fileEnd, UInt64(length) <= fileEnd - start else { break }
            let end = start + UInt64(length)
            switch header[0] & 0x7f {
            case 4 where !foundComments:
                // Preserve the first VORBIS_COMMENT block's parsing semantics.
                foundComments = true
                if length <= 4 * 1024 * 1024,
                   let data = try file.read(upToCount: length), data.count == length {
                    result.comments = parse(data)
                }
            case 6 where !foundFrontCover:
                if let picture = try readPicture(file, end: end),
                   result.picture == nil || picture.type == 3 {
                    result.picture = picture.data
                    foundFrontCover = picture.type == 3
                }
            default: break
            }
            if header[0] & 0x80 != 0 { break }
            try file.seek(toOffset: end)
        }
        return result
    }

    /// Read field-by-field within this block, seeking over strings instead of
    /// allocating untrusted MIME/description lengths or the entire picture block.
    private static func readPicture(_ file: FileHandle, end: UInt64) throws -> (type: Int, data: Data)? {
        func integer() throws -> Int? {
            guard file.offsetInFile <= end, end - file.offsetInFile >= 4,
                  let bytes = try file.read(upToCount: 4), bytes.count == 4 else { return nil }
            return bytes.reduce(0) { ($0 << 8) | Int($1) }
        }
        func skipString() throws -> Bool {
            guard let length = try integer(), UInt64(length) <= end - file.offsetInFile else { return false }
            try file.seek(toOffset: file.offsetInFile + UInt64(length))
            return true
        }
        guard let type = try integer(), try skipString(), try skipString() else { return nil }
        // Width, height, color depth, indexed color count.
        for _ in 0..<4 { guard try integer() != nil else { return nil } }
        guard let length = try integer(), length > 0, length < artworkByteLimit,
              UInt64(length) <= end - file.offsetInFile,
              let data = try file.read(upToCount: length), data.count == length else { return nil }
        return (type, data)
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
