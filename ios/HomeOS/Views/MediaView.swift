import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MediaFilter: String, CaseIterable {
    case all = "All", photos = "Photos", videos = "Videos"
}

/// Family photos and videos (also shown on the wall's photo frame).
struct MediaView: View {
    @Environment(FamilyStore.self) private var store
    @State private var filter: MediaFilter = .all
    @State private var selection: [PhotosPickerItem] = []
    @State private var uploadTotal = 0
    @State private var uploadDone = 0
    @State private var viewing: MediaViewerLaunch?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    private var items: [MediaItem] {
        let sorted = store.media.sorted { $0.date > $1.date }
        switch filter {
        case .all: return sorted
        case .photos: return sorted.filter { !$0.isVideo }
        case .videos: return sorted.filter(\.isVideo)
        }
    }

    private struct MonthGroup: Identifiable {
        let id: Date
        let items: [MediaItem]
    }

    private var groups: [MonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) {
            calendar.dateInterval(of: .month, for: $0.date)?.start ?? .distantPast
        }
        return grouped.keys.sorted(by: >).map { MonthGroup(id: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Media", subtitle: "\(store.media.count) memories") {
                        PhotosPicker(selection: $selection, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Theme.accent, in: Circle())
                        }
                        .disabled(uploadTotal > 0)
                        .accessibilityLabel("Add photos and videos")
                    }
                    .padding(.horizontal, Theme.page)

                    SegmentedPill(MediaFilter.allCases, selection: $filter) { $0.rawValue }
                        .padding(.horizontal, Theme.page)

                    if uploadTotal > 0 {
                        uploadBanner
                            .padding(.horizontal, Theme.page)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if items.isEmpty {
                        EmptyCard(text: "Photos and videos you add here appear on the family display.", systemImage: "photo")
                            .padding(.horizontal, Theme.page)
                    }

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.id.formatted(.dateTime.month(.wide).year()))
                                .font(.headline)
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, Theme.page)
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach(group.items) { item in
                                    Button {
                                        viewing = MediaViewerLaunch(items: items, startId: item.id)
                                    } label: {
                                        MediaTile(item: item)
                                    }
                                    .buttonStyle(PressableStyle())
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.bottom, 24)
                .animation(Theme.springy, value: filter)
                .animation(Theme.springy, value: store.media)
                .animation(Theme.springy, value: uploadTotal)
            }
            .screenBackground()
            .refreshable { await store.refreshMedia() }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $viewing) { MediaViewer(launch: $0) }
            .onChange(of: selection) { _, picked in
                guard !picked.isEmpty else { return }
                Task { await upload(picked) }
            }
            .showsStoreErrors()
        }
    }

    private var uploadBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 6) {
                Text("Uploading \(min(uploadDone + 1, uploadTotal)) of \(uploadTotal)…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(uploadDone)))
                ProgressBar(value: uploadTotal == 0 ? 0 : Double(uploadDone) / Double(uploadTotal))
            }
        }
        .card(padding: 14, radius: Theme.radiusSm + 4)
    }

    @MainActor
    private func upload(_ picked: [PhotosPickerItem]) async {
        uploadTotal = picked.count
        uploadDone = 0
        for item in picked {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if let data = try? await item.loadTransferable(type: Data.self) {
                if isVideo {
                    let ext = item.supportedContentTypes.first { $0.conforms(to: .movie) }?.preferredFilenameExtension ?? "mov"
                    let metadata = await MediaTools.videoMetadata(data, fileExtension: ext)
                    await store.upload(data: data, isVideo: true, fileExtension: ext, metadata: metadata)
                } else if let photo = MediaTools.preparePhoto(data) {
                    await store.upload(data: photo.data, isVideo: false, fileExtension: "jpg", metadata: photo.metadata)
                }
            }
            withAnimation(Theme.springy) { uploadDone += 1 }
        }
        selection = []
        await store.refreshMedia()
        withAnimation(Theme.springy) { uploadTotal = 0 }
    }
}

/// Square grid tile; videos get a play badge and duration.
struct MediaTile: View {
    @Environment(FamilyStore.self) private var store
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        Theme.sunken
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(Theme.muted)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if let duration = MediaTools.durationLabel(item.durationSeconds) { Text(duration) }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !item.showOnFrame {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }
            .task(id: item.storagePath) {
                if let cached = MediaCache.shared.cachedThumbnail(for: item) {
                    image = cached
                    return
                }
                guard let url = await store.signedURL(for: item) else { return }
                let loaded = await MediaCache.shared.thumbnail(for: item, url: url)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}

// MARK: - Viewer

struct MediaViewerLaunch: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let startId: UUID
}

/// Full-screen pager. The backdrop takes on the current photo's average color.
struct MediaViewer: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let launch: MediaViewerLaunch

    @State private var current: UUID
    @State private var tint: Color = .black
    @State private var confirmingDelete = false
    @State private var chromeHidden = false

    init(launch: MediaViewerLaunch) {
        self.launch = launch
        _current = State(initialValue: launch.startId)
    }

    /// Live copies, so toggles and deletes show up immediately.
    private var items: [MediaItem] {
        launch.items.compactMap { item in store.media.first { $0.id == item.id } }
    }

    private var currentItem: MediaItem? { items.first { $0.id == current } }

    var body: some View {
        ZStack {
            tint
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: tint)

            TabView(selection: $current) {
                ForEach(items) { item in
                    MediaPage(item: item, isCurrent: item.id == current)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }

            if !chromeHidden {
                chrome.transition(.opacity)
            }
        }
        .statusBarHidden(chromeHidden)
        .task(id: current) { await updateTint() }
        .onChange(of: items.isEmpty) { _, empty in if empty { dismiss() } }
        .confirmationDialog("Delete this from the family library?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                if let item = currentItem {
                    VStack(spacing: 1) {
                        Text(item.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.weight(.semibold))
                        if let caption = item.caption, !caption.isEmpty {
                            Text(caption).font(.caption).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            if let item = currentItem {
                HStack(spacing: 10) {
                    Button {
                        Task { await store.setShowOnFrame(item, !item.showOnFrame) }
                    } label: {
                        Label(item.showOnFrame ? "On the wall frame" : "Hidden from frame",
                              systemImage: item.showOnFrame ? "photo.artframe" : "eye.slash")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.selection, trigger: item.showOnFrame)
                    Spacer()
                    Button { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Delete")
                }
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @MainActor
    private func updateTint() async {
        guard let item = currentItem else { return }
        if let cached = MediaCache.shared.tint(for: item) {
            tint = cached
            return
        }
        guard let url = await store.signedURL(for: item) else { return }
        _ = await MediaCache.shared.thumbnail(for: item, url: url)
        if let color = MediaCache.shared.tint(for: item) { tint = color }
    }

    private func deleteCurrent() {
        guard let item = currentItem else { return }
        let list = items
        if let index = list.firstIndex(of: item) {
            let next: MediaItem? = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            if let next { current = next.id }
        }
        Task { await store.deleteMedia(item) }
    }
}

/// One page in the viewer: a screen-sized photo or a video player.
struct MediaPage: View {
    @Environment(FamilyStore.self) private var store
    let item: MediaItem
    let isCurrent: Bool

    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if item.isVideo {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else if let thumb = MediaCache.shared.cachedThumbnail(for: item) {
                Image(uiImage: thumb).resizable().scaledToFit().blur(radius: 6)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.storagePath) {
            guard let url = await store.signedURL(for: item) else { return }
            if item.isVideo {
                if player == nil { player = AVPlayer(url: url) }
                if isCurrent { player?.play() }
            } else {
                let loaded = await MediaCache.shared.fullImage(for: item, url: url)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
        }
        .onChange(of: isCurrent) { _, nowCurrent in
            if nowCurrent { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}
