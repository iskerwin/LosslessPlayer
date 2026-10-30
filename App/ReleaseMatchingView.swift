import SwiftUI

struct ReleaseMatchingView: View {
    @ObservedObject var library: LibraryStore
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ReleaseCandidate] = []
    @State private var selected: ReleaseCandidate?
    @State private var loadingGenre = false
    @State private var genreOperation: Task<Void, Never>?
    @State private var working = false
    @State private var searched = false
    @State private var message: String?
    @State private var saved = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("识别会将艺术家、标题、专辑和时长发送至 musicbrainz.org；补封面时向 coverartarchive.org 请求所选专辑封面。仅更新资料库，不改动音频文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("\(track.title) · \(track.artist)")
                    if !searched && !working {
                        Button("开始识别") { startSearch() }
                    }
                    if working { ProgressView("正在处理…") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
                if searched && candidates.isEmpty && !working && message == nil {
                    Section { Text("没有找到高分候选。可跳过并保留现有信息。") }
                }
                if !candidates.isEmpty && !saved {
                    Section("选择候选（\(candidates.count)）") {
                        ForEach(candidates) { candidate in
                            Button { select(candidate) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(candidate.album).font(.headline)
                                        Spacer()
                                        if selected?.id == candidate.id { Image(systemName: "checkmark.circle.fill") }
                                    }
                                    Text("\(candidate.artist) · \(candidate.title)")
                                    Text([candidate.date, candidate.country, candidate.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    Text("评分 \(candidate.score)/100：标题 \(candidate.titleScore)，艺术家 \(candidate.artistScore)，专辑 \(candidate.albumScore)，时长 \(candidate.durationScore)")
                                        .font(.caption)
                                    Text("Release: \(candidate.releaseMBID)").font(.caption2)
                                    Text("Recording: \(candidate.recordingMBID)").font(.caption2)
                                }.foregroundStyle(.primary)
                            }
                        }
                    }.disabled(working)
                }
                if let selected, !saved {
                    Section("确认改动（仅此曲目）") {
                        change("标题", track.title, selected.title)
                        change("艺术家", track.artist, selected.artist)
                        if ReleaseMatching.known(track.album) {
                            Text("保留现有专辑：\(track.album)")
                        } else {
                            change("专辑", "未知专辑", selected.album)
                        }
                        fillChange("专辑艺术家", track.albumArtist, selected.albumArtist, emptyIsMissing: true)
                        fillChange("年份", track.year.map(String.init), selected.year.map(String.init))
                        if loadingGenre {
                            ProgressView("风格：取数中…")
                        } else {
                            fillChange("风格", track.genre, selected.genre)
                            if track.genre == nil && selected.genre == nil {
                                Text("无可用风格，保持未填写。").font(.footnote)
                            }
                        }
                        Text(track.artworkFilename == nil ? "若有 front 封面则补充；无封面时保持原状。" : "保留已有封面。")
                            .font(.footnote)
                        Button("确认并应用到资料库") { apply(selected) }
                            .disabled(working || loadingGenre || library.importing)
                    }
                }
                if saved {
                    Button("完成") { dismiss() }
                } else {
                    Button("跳过，保留现有信息") { operation?.cancel(); dismiss() }
                        .disabled(working)
                }
            }
            .navigationTitle("识别专辑信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { operation?.cancel(); dismiss() }.disabled(working)
            } }
            .interactiveDismissDisabled(working)
        }
        .onDisappear { operation?.cancel(); genreOperation?.cancel() }
    }

    private func change(_ name: String, _ old: String, _ new: String) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text("\(old) → \(new)")
        }
    }

    private func fillChange(_ name: String, _ old: String?, _ new: String?, emptyIsMissing: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            if let old, !(emptyIsMissing && old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Text("保留现有：\(old)")
            } else if let new, !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("未填写 → \(new)")
            } else {
                Text("保持未填写")
            }
        }
    }

    private func select(_ candidate: ReleaseCandidate) {
        genreOperation?.cancel()
        selected = candidate
        loadingGenre = track.genre == nil
        guard loadingGenre else { return }
        genreOperation = Task { @MainActor in
            do {
                let reviewed = try await MusicBrainzClient.shared.candidateForReview(candidate, track: track)
                try Task.checkCancellation()
                selected = reviewed
                loadingGenre = false
            } catch {
                // A cancelled selection must never replace the newly selected candidate.
                guard !Task.isCancelled else { return }
                loadingGenre = false
            }
        }
    }

    private func startSearch() {
        working = true; message = nil
        operation = Task { @MainActor in
            defer { working = false }
            do {
                candidates = try await MusicBrainzClient.shared.candidates(for: track)
                try Task.checkCancellation()
                searched = true
            } catch { message = errorText(error) }
        }
    }

    private func apply(_ candidate: ReleaseCandidate) {
        guard !loadingGenre else { return }
        working = true; message = nil
        operation = Task { @MainActor in
            defer { working = false }
            do {
                if try await library.applyMusicBrainz(candidate, reviewed: track) {
                    saved = true
                    message = library.musicBrainzNotice ?? "已更新资料库；音频文件保持不变。"
                } else { message = library.errorMessage ?? "保存失败，请重试。" }
            } catch { message = errorText(error) }
        }
    }

    private func errorText(_ error: Error) -> String {
        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dataNotAllowed].contains(error.code) {
            return "无网络或无法连接识别服务，请检查网络后重试。本地扫描、播放和资料库可照常使用。"
        }
        return error.localizedDescription
    }
}
