import UIKit

enum ScreenshotFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotMode") }

    static func install() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let art = artworkJPEG() {
            try? art.write(to: root.appendingPathComponent("cover.jpg"), options: .atomic)
        }
        let audio = wavData()
        let songs = [
            ("Apologize", "OneRepublic"),
            ("Stop and Stare", "OneRepublic"),
            ("Mercy", "OneRepublic"),
            ("Good Life", "OneRepublic"),
            ("All the Right Moves", "OneRepublic"),
            ("Come Home", "OneRepublic")
        ]
        var tracks: [Track] = []
        for (index, song) in songs.enumerated() {
            let filename = "track-\(index).wav"
            try? audio.write(to: root.appendingPathComponent(filename), options: .atomic)
            var track = Track(
                id: UUID(), filename: filename, title: song.0, artist: song.1,
                album: "Dreaming Out Loud", duration: 211, sampleRate: 48000, bitDepth: 24
            )
            track.artworkFilename = "cover.jpg"
            track.addedAt = Date().addingTimeInterval(TimeInterval(-index * 3600))
            tracks.append(track)
        }
        var playlist = Playlist(name: "深夜")
        playlist.trackIDs = tracks.map(\.id)
        playlist.coverTrackID = tracks.first?.id
        var snapshot = LibrarySnapshot()
        snapshot.tracks = tracks
        snapshot.playlists = [playlist]
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
        }
        var playback = PlaybackState(currentID: tracks.first?.id, position: 4, queueIDs: tracks.map(\.id), contextOrder: tracks.map(\.id))
        if let data = try? encoder.encode(playback) {
            try? data.write(to: root.appendingPathComponent("playback.json"), options: .atomic)
        }
    }

    private static func artworkJPEG() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800))
        let image = renderer.image { ctx in
            let colors = [
                UIColor(red: 0.04, green: 0.09, blue: 0.24, alpha: 1).cgColor,
                UIColor(red: 0.12, green: 0.28, blue: 0.48, alpha: 1).cgColor
            ] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 800), options: [])
            }
            ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
            ctx.cgContext.setLineWidth(4)
            ctx.cgContext.setLineCap(.round)
            let trunk = CGPoint(x: 400, y: 560)
            ctx.cgContext.move(to: trunk)
            ctx.cgContext.addLine(to: CGPoint(x: 400, y: 340))
            ctx.cgContext.move(to: CGPoint(x: 400, y: 460))
            ctx.cgContext.addLine(to: CGPoint(x: 280, y: 300))
            ctx.cgContext.move(to: CGPoint(x: 400, y: 430))
            ctx.cgContext.addLine(to: CGPoint(x: 540, y: 270))
            ctx.cgContext.move(to: CGPoint(x: 400, y: 380))
            ctx.cgContext.addLine(to: CGPoint(x: 330, y: 250))
            ctx.cgContext.strokePath()
        }
        return image.jpegData(compressionQuality: 0.86)
    }

    private static func wavData() -> Data {
        let frames = 44100 * 8
        let dataSize = frames * 2
        var data = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append32(16)
        append16(1)
        append16(1)
        append32(44100)
        append32(88200)
        append16(2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
