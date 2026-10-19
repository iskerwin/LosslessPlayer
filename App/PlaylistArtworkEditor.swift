import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PlaylistArtworkEditor: View {
    @ObservedObject var library: LibraryStore
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("从照片选择", systemImage: "photo")
                }
                Button("从文件选择", systemImage: "folder") { files = true }
                Button("恢复自动封面", systemImage: "arrow.counterclockwise") {
                    library.resetPlaylistArtwork(playlist)
                    dismiss()
                }
                if loading { ProgressView("正在读取图片…") }
                if let error = library.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .disabled(loading)
            .navigationTitle("修改歌单封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        if let data = try await item.loadTransferable(type: Data.self), library.setPlaylistArtwork(data, for: playlist) { dismiss() }
                    } catch { library.errorMessage = "图片读取失败：\(error.localizedDescription)" }
                }
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let scope = url.startAccessingSecurityScopedResource()
                    defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20_000_000 else { library.errorMessage = "请选择 20MB 以内的图片。"; return }
                    if library.setPlaylistArtwork(try Data(contentsOf: url), for: playlist) { dismiss() }
                } catch { library.errorMessage = "图片读取失败：\(error.localizedDescription)" }
            }
        }
        .tint(MusicTheme.accent)
        .presentationDetents([.medium])
    }
}
