import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var removing: MusicFolder?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("添加音乐文件夹", systemImage: "folder.badge.plus") { choosing = true }.disabled(library.importing)
                } footer: { Text("选择你在“文件”中能访问的音乐目录。直接索引原文件，不复制整份音乐；支持子文件夹。") }
                ForEach(library.snapshot.folders) { folder in
                    Section {
                        Label(folder.name, systemImage: "folder.fill").font(.headline)
                        let songs = library.tracks.filter { $0.folderID == folder.id }
                        Text("\(songs.count) 首歌曲 · \(songs.filter { !$0.available }.count) 首失效").font(.caption).foregroundStyle(.secondary)
                        if let date = folder.lastScan { Text("上次扫描 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        if let error = folder.scanError { Text(error).font(.caption).foregroundStyle(.red) }
                        Button("按文件夹创建歌单", systemImage: "music.note.list") { library.createPlaylistsFromFolder(folder) }.disabled(library.importing)
                        Button("重新扫描", systemImage: "arrow.clockwise") { library.startScan(folder.id) }.disabled(library.importing)
                        Button("取消授权并移除资料库条目", systemImage: "folder.badge.minus", role: .destructive) { removing = folder }.disabled(library.importing)
                    }
                }
                if library.importing {
                    Section("正在扫描") {
                        ProgressView(value: library.progress)
                        Text(library.progressText).font(.caption)
                        Button("取消扫描", role: .cancel) { library.cancelScan() }
                    }
                }
                if let summary = library.scanSummary { Section { Text(summary).font(.caption).foregroundStyle(.secondary) } }
                Section {
                    Text("离线文件夹需保留在原位置。iCloud 或其他文件提供器可能先下载文件，授权失效时请移除后重新添加。扫描只在 App 内执行，不会后台持续监视文件变化。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("音乐文件夹").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.startAddFolders(urls)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("移除此文件夹？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let folder = removing { Button("移除文件夹", role: .destructive) {
                    if let track = player.current, track.folderID == folder.id { player.stopIfCurrent(track) }
                    library.removeFolder(folder); removing = nil
                } }
            } message: { Text("只清除授权和资料库索引，不会删除原文件。") }
            .alert("无法扫描", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好") { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "") }
        }.tint(MusicTheme.accent)
    }
}
