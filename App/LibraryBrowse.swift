import Foundation

struct ArtistBucket: Identifiable, Equatable {
    var name: String
    var tracks: [Track]
    var id: String { name }
}

/// Album, artist, favorite, and recently-played groupings for the library UI.
/// Rebuilt only when the catalog snapshot changes. Recomputing this from
/// `LibraryView.body` made every play/pause an O(artists × tracks) string
/// normalization, because the player and the library share one view tree.
struct LibraryBrowseIndex {
    var albumsByName: [AlbumGroup] = []
    var albumsByRecent: [AlbumGroup] = []
    var albumsByID: [String: AlbumGroup] = [:]
    var artists: [ArtistBucket] = []
    var artistsByName: [String: [Track]] = [:]
    var favorites: [Track] = []
    var recentlyPlayed: [Track] = []

    static let empty = LibraryBrowseIndex()

    static func build(tracks: [Track]) -> LibraryBrowseIndex {
        var index = LibraryBrowseIndex()
        let albums = AlbumGroup.groups(tracks)
        index.albumsByName = albums
        index.albumsByRecent = albums.sorted { $0.latest > $1.latest }
        var albumsByID: [String: AlbumGroup] = [:]
        albumsByID.reserveCapacity(albums.count)
        for album in albums { albumsByID[album.id] = album }
        index.albumsByID = albumsByID

        var byNorm: [String: [Track]] = [:]
        for track in tracks {
            var seen = Set<String>()
            for name in track.artistNames {
                let key = AudioTags.normalized(name)
                if seen.insert(key).inserted {
                    byNorm[key, default: []].append(track)
                }
            }
        }
        let names = Array(Set(tracks.flatMap(\.artistNames))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        index.artists = names.map { name in
            ArtistBucket(name: name, tracks: byNorm[AudioTags.normalized(name)] ?? [])
        }
        var artistsByName: [String: [Track]] = [:]
        artistsByName.reserveCapacity(index.artists.count)
        for artist in index.artists { artistsByName[artist.name] = artist.tracks }
        index.artistsByName = artistsByName

        index.favorites = tracks.filter(\.favorite)
        index.recentlyPlayed = tracks.filter { $0.lastPlayed != nil }.sorted {
            ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
        }
        return index
    }
}
