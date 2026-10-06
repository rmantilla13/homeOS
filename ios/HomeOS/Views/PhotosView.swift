import PhotosUI
import SwiftUI

struct PhotosView: View {
    @Environment(FamilyStore.self) private var store
    @State private var selection: [PhotosPickerItem] = []
    @State private var uploading = 0

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(store.media) { item in
                        MediaThumbnail(item: item)
                    }
                }
            }
            .overlay {
                if store.media.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "photo",
                                           description: Text("Photos you add here appear on the family display."))
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                if uploading > 0 {
                    ProgressView("Uploading \(uploading)…")
                } else {
                    PhotosPicker(selection: $selection, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task { await upload(items) }
            }
            .refreshable { await store.refresh() }
            .showsStoreErrors()
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        uploading = items.count
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            // TODO(M3): downscale photos to ~2560px and transcode HEIC → JPEG before upload.
            if let data = try? await item.loadTransferable(type: Data.self) {
                await store.upload(data: data, isVideo: isVideo, fileExtension: ext, takenAt: nil)
            }
            uploading -= 1
        }
        selection = []
    }
}

struct MediaThumbnail: View {
    @Environment(FamilyStore.self) private var store
    let item: MediaItem
    @State private var url: URL?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    if item.kind == "video" { Image(systemName: "video") }
                }
            }
            .clipped()
            .task { url = await store.signedURL(for: item) }
    }
}
