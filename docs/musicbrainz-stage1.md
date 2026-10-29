# MusicBrainz stage 1

Use a track row's **识别专辑信息** menu item in the library, collections, or search. Tap **开始识别**, select a release, review the before/after values, then explicitly confirm. Even a single candidate requires confirmation. This applies only to that track, never its album siblings or the entire library. Skip/close preserves the catalog.

The sheet states: “识别会将艺术家、标题、专辑和时长发送至 musicbrainz.org；补封面时向 coverartarchive.org 请求所选专辑封面。仅更新资料库，不改动音频文件。” Nothing is sent until the user starts identification. CAA receives the selected release MBID when artwork is missing; it redirects artwork delivery to Internet Archive. Offline request errors are confined to the matching sheet; the scanner and player have no dependency on this client.

Search uses MusicBrainz WS2 recording search, with escaped title and artist phrases and optional album/duration boosts. Duration is sent in milliseconds with a ±3 second boost; it is never a required filter. Search returns at most 25 recordings and their associated releases. This is deliberately a bounded first-stage search, not an exhaustive discography lookup or fingerprint search.

Scores are computed locally, independent of server relevance scores:

| Factor | Maximum | Rule |
| --- | ---: | --- |
| Title | 40 | Normalized exact match gets full points, otherwise token intersection/union × weight, rounded down |
| Artist | 30 | Same rule |
| Album | 20 | Same rule; unknown/empty local tags contribute zero |
| Duration | 10 | Difference ≤3 seconds: 10; ≤10 seconds: 5; greater/missing: 0 |

Normalization folds case, diacritics and width, then separates punctuation and whitespace. Unknown titles/artists cannot be queried. A candidate needs ≥75 total, ≥24 title and ≥18 artist points. Release/recording pairs are deduplicated, sorted by score descending then by release/recording MBID ascending for deterministic ties. Each candidate displays its factor scores, date, country, disambiguation and both IDs. Multiple editions remain separate choices. Missing release artist credit falls back to recording artist credit, as in MusicBrainz recording search responses. Years come from the selected release date and existing years are retained if absent.

Only confirmed title, artist, album, album artist, available year and optional `musicBrainzReleaseMBID` / `musicBrainzRecordingMBID` catalog fields are saved. Old catalogs decode both IDs as nil. The current catalog track is rechecked before and after network suspension to reject stale reviews and scans in progress. Persistence uses the existing atomic catalog save and indexes. A later scan of a changed audio file can reread its original tags; this stage does not change scan reconciliation.

A shared actor holds an explicit FIFO gate across network suspension, allowing one request at a time, including retries and CAA downloads. Starts use monotonic uptime and are separated by ≥1.05 seconds. HTTP 429/503 have at most two retries with 2/4 second exponential backoff, honoring a longer Retry-After (seconds or HTTP date); impractically long delays fail instead of retrying early. All requests carry `LosslessPlayer/1.0 (https://github.com/iskerwin/LosslessPlayer)`.

Existing `artworkFilename` values cause no CAA request. Missing covers use CAA's front-500 endpoint; 404/empty data leaves artwork absent. Downloaded data goes through the existing AudioScanner `storeThumbnail` ImageIO path: transformed JPEG thumbnail up to 700px, `.artwork` file in the app library root, displayed by ArtworkCache. The only edit in AudioScanner is helper visibility; its scanning/parsing behavior is unchanged. New cache IDs avoid overwriting an intervening scan's thumbnail. Invalid images and failed downloads leave artwork untouched; metadata can still be saved with a notice. Failed catalog saves or stale reviews remove newly created thumbnails.

The apply path does not resolve/open an audio URL. It writes only the app's JSON catalog and thumbnail cache, never tags, PICTURE blocks, filenames, audio bytes or audio modification timestamps.

## Validation

`Tests/MusicBrainzTests.swift` uses an ephemeral URLSession with URLProtocol intercepting all requests, including unexpected hosts. Tests cover URL/query escaping, score factors/ranking/deduplication, duration tolerance, zero/one/multiple candidates, concurrent pacing, 429/503 backoff, Retry-After parsing, offline/HTTP/malformed responses, missing and invalid artwork, old/new MBID coding, explicit application, stale reviews, existing-cover preservation, downloaded thumbnails and audio byte/hash/mtime preservation. No test contacts the real services.

Linux has no Xcode: compilation, XCTest and screenshots must be verified by GitHub Actions. No physical-device checks have been claimed.

## Physical-device checklist

- [ ] Online: match a tagged track, inspect scores/IDs and confirm before/after values; relaunch and verify catalog persistence.
- [ ] Offline: matching displays a network message; scanning, browsing and local playback still work.
- [ ] Multiple editions: choose one release explicitly, or skip; skipping changes nothing.
- [ ] Zero candidates: no metadata or cover changes.
- [ ] Missing cover: confirmed release front artwork becomes a normal cached thumbnail; missing CAA art remains missing.
- [ ] Existing embedded/folder artwork: no CAA request and no replacement.
- [ ] Before and after identification compare source file SHA-256 and modification timestamp; both remain identical.
- [ ] Try a scan/edit while awaiting a cover; stale confirmation is rejected without overwriting newer library state.
