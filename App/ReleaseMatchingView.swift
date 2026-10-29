import SwiftUI

struct ReleaseMatchingView: View {
    @ObservedObject var library: LibraryStore
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ReleaseCandidate] = []
    @State private var selected: ReleaseCandidate?
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
                            Button { selected = candidate } label: {
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
                        change("专辑", track.album, selected.album)
                        change("专辑艺术家", track.albumArtist ?? "未填写", selected.albumArtist)
                        change("年份", track.year.map(String.init) ?? "未填写", (selected.year ?? track.year).map(String.init) ?? "未填写")
                        Text(track.artworkFilename == nil ? "若有 front 封面则补充；无封面时保持原状。" : "保留已有封面。")
                            .font(.footnote)
                        Button("确认并应用到资料库") { apply(selected) }
                            .disabled(working || library.importing)
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
        .onDisappear { operation?.cancel() }
    }

    private func change(_ name: String, _ old: String, _ new: String) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text("\(old) → \(new)")
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
