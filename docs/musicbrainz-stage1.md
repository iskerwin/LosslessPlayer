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

Normalization folds case, diacritics and width, then separates punctuation and whitespace. Unknown titles/artists cannot be queried. A candidate needs ≥75 total, ≥24 title and ≥18 artist points. Release/recording pairs are deduplicated, sorted by score descending then by release/recording MBID ascending for deterministic ties. Each candidate displays its factor scores, date, country, disambiguation and both IDs. Multiple editions remain separate choices. Missing release artist credit falls back to recording artist credit, as in MusicBrainz recording search responses. Years come from the selected release date and only fill a nil local year.

Only confirmed metadata and optional `musicBrainzReleaseMBID` / `musicBrainzRecordingMBID` catalog fields are saved, following the fill conditions below. Old catalogs decode both IDs as nil. The current catalog track is rechecked before and after network suspension to reject stale reviews and scans in progress. Persistence uses the existing atomic catalog save and indexes. A later scan of a changed audio file can reread its original tags; this stage does not change scan reconciliation.

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

## Manual album-fill extension

This remains a single-track manual action. There is no folder-name fallback, automatic save, or batch filling. No storage schema or `catalogVersion` change is needed.

| Field | Write condition after explicit confirmation |
| --- | --- |
| Album | Fill only when `ReleaseMatching.known(localAlbum)` is false (empty/未知专辑/unknown album); preserve any known album |
| Album artist | Fill only when local value is nil or blank; an empty candidate leaves it unfilled |
| Year | Fill selected release year only when local year is nil; preserve existing year |
| Genre | Fill reviewed genre only when local genre is nil; preserve existing values, including an empty string |
| Title / artist / artists | Same as stage 1: write selected candidate values after confirmation |
| Cover | Same as stage 1: existing artwork prevents CAA requests; missing artwork may be filled; 404/empty data stays absent |

When the user selects a candidate and local genre is nil, the shared MusicBrainzClient requests `ws/2/release/<selected-release-MBID>?fmt=json&inc=tags`. This is one bounded lookup (with the existing bounded 429/503 retry policy), not additional recording searches or release enumeration. It uses the same request path, FIFO gate, ≥1.05-second start interval and public User-Agent. In response order, the first tag that `AudioTags.genre(from:)` can normalize becomes the candidate genre. Missing/blank tags, malformed data, HTTP or network errors leave genre nil; no fabricated value is saved. Existing local genre prevents this lookup entirely. Candidate selection performs no catalog write.

The confirmation section retains the sending-content and catalog-only disclosure. A single candidate still requires selection and explicit confirmation; multiple candidates remain selectable. Skip/close changes nothing. Switching candidates cancels the prior review lookup and prevents its result from replacing the current selection.

- Unknown album displays `未知专辑 → <candidate album>`; a known album displays `保留现有专辑：<local album>` without an arrow to the candidate.
- Album artist and year display `未填写 → <candidate value>` when missing, `保持未填写` if no candidate value, or `保留现有：<local value>` when present.
- Genre follows the same rules. During lookup the row shows `风格：取数中…` and confirmation is disabled. Lookup failure or missing tags displays `无可用风格，保持未填写。`; confirmation can then save the other fields.
- Title and artist retain their before → after rows. Cover behavior and the two stale-review checks, atomic save, and new-thumbnail cleanup remain unchanged.

The stub-only MusicBrainz tests additionally cover unknown-album filling, known-value preservation, nil/blank album artists, nil-only year/genre filling, normalized tags, request path/UA/shared pacing, missing/failed tag queries with successful metadata confirmation, cancelled review, single-result review without saving, and favorite/play-history/queue/playback-file preservation. Existing audio byte/hash/mtime assertions remain in place.

### Device verification for 深夜港湾-甄楚倩.flac

- [ ] With the original artist/title-only file and unknown album, search, select the correct release, and inspect the album/album artist/year/genre review before confirmation. Confirm that the resulting album name is correct and persists after relaunch.
- [ ] Verify genre loading disables confirmation; unavailable tags allow confirmation without filling genre. Skip/close must preserve all metadata.
- [ ] Compare the source file SHA-256, bytes, filename and mtime before and after: all must remain unchanged.
- [ ] Verify favorite status, play count, last-played time, current playback position and queue are unaffected.
- [ ] With existing album/album artist/year/genre and artwork, confirm those values remain unchanged and no unnecessary genre/CAA lookup occurs.

Batch automatic filling is a possible follow-up only; it is not implemented here. Device verification remains pending; Linux cannot perform Xcode builds or physical-device checks.
