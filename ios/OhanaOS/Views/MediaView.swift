import AVKit
import PhotosUI
import SwiftUI
import UIKit
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
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingDelete = false

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
                    ScreenHeader(title: "Media", subtitle: headerSubtitle) {
                        HStack(spacing: 10) {
                            if selecting {
                                Button("Cancel") {
                                    withAnimation(Theme.springy) {
                                        selecting = false
                                        selected = []
                                    }
                                }
                                .buttonStyle(.pill(.soft))
                            } else {
                                if !items.isEmpty {
                                    Button("Select") { withAnimation(Theme.springy) { selecting = true } }
                                        .buttonStyle(.pill(.soft))
                                        .disabled(uploadTotal > 0)
                                        .accessibilityLabel("Select photos and videos")
                                }
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
                        }
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
                                    let isSelected = selected.contains(item.id)
                                    Button {
                                        if selecting {
                                            withAnimation(Theme.springy) {
                                                if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
                                            }
                                        } else {
                                            viewing = MediaViewerLaunch(items: items, startId: item.id)
                                        }
                                    } label: {
                                        MediaTile(item: item, selecting: selecting, selected: isSelected)
                                    }
                                    .buttonStyle(PressableStyle())
                                    .accessibilityLabel(item.isVideo ? "Video" : "Photo")
                                    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                .animation(Theme.springy, value: selecting)
            }
            .screenBackground()
            .refreshable { await store.refreshMedia() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar }
            }
            .fullScreenCover(item: $viewing) { MediaViewer(launch: $0) }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(selected.count > 1 ? "Delete \(selected.count)" : "Delete", role: .destructive) {
                    deleteSelected()
                }
            }
            .sensoryFeedback(.selection, trigger: selected.count)
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
                Text("Keep Ohana open until this finishes.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .card(padding: 14, radius: Theme.radiusSm + 4)
    }

    @MainActor
    private func upload(_ picked: [PhotosPickerItem]) async {
        uploadTotal = picked.count
        uploadDone = 0
        let keepAlive = UploadKeepAlive()
        var failed = 0
        var lastReason: String?
        for item in picked {
            var uploaded = false
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                if let video = try? await item.loadTransferable(type: MediaTools.PickedVideo.self) {
                    defer { try? FileManager.default.removeItem(at: video.url) }
                    let ext = video.url.pathExtension.isEmpty ? "mov" : video.url.pathExtension
                    let metadata = await MediaTools.videoMetadata(at: video.url)
                    uploaded = await store.upload(file: video.url, fileExtension: ext, metadata: metadata)
                } else {
                    store.errorMessage = "That video couldn't be read. Try another one."
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let photo = MediaTools.preparePhoto(data) {
                uploaded = await store.upload(data: photo.data, isVideo: false, fileExtension: "jpg", metadata: photo.metadata)
            } else {
                store.errorMessage = "That photo couldn't be used. Try another one."
            }
            if !uploaded {
                failed += 1
                lastReason = store.errorMessage ?? lastReason
            }
            withAnimation(Theme.springy) { uploadDone += 1 }
        }
        selection = []
        await store.refreshMedia()
        keepAlive.finish()
        if failed > 0, picked.count > 1 {
            // Say how many didn't make it, not only the last reason.
            let summary = failed == picked.count
                ? "None of the \(picked.count) uploaded."
                : "\(failed) of \(picked.count) didn't upload."
            store.errorMessage = [summary, lastReason].compactMap { $0 }.joined(separator: " ")
        }
        withAnimation(Theme.springy) { uploadTotal = 0 }
    }

    private var headerSubtitle: String {
        if selecting {
            return selected.isEmpty ? "Select memories" : "\(selected.count) selected"
        }
        return "\(store.media.count) memories"
    }

    private var filteredIds: Set<UUID> { Set(items.map(\.id)) }

    private var allVisibleSelected: Bool {
        !filteredIds.isEmpty && filteredIds.isSubset(of: selected)
    }

    private var deleteTitle: String {
        switch selected.count {
        case 1: return "Delete this from the family library?"
        default: return "Delete \(selected.count) items from the family library?"
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(allVisibleSelected ? "Clear" : "Select all") {
                withAnimation(Theme.springy) {
                    if allVisibleSelected {
                        selected.subtract(filteredIds)
                    } else {
                        selected.formUnion(filteredIds)
                    }
                }
            }
            .buttonStyle(.pill(.soft))
            Spacer(minLength: 8)
            Button("Delete", role: .destructive) { confirmingDelete = true }
                .buttonStyle(.pill(.destructive))
                .disabled(selected.isEmpty)
                .accessibilityLabel(selected.count == 1 ? "Delete 1 item" : "Delete \(selected.count) items")
        }
        .padding(.horizontal, Theme.page)
        .padding(.vertical, 10)
        .background(Theme.background)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }

    private func deleteSelected() {
        let chosen = store.media.filter { selected.contains($0.id) }
        let count = chosen.count
        withAnimation(Theme.springy) {
            selected = []
            selecting = false
        }
        guard count > 0 else { return }
        Task { await store.deleteMedia(chosen) }
    }
}

/// Keeps the phone from auto-locking during a batch and asks iOS for extra
/// time if Ohana goes to the background. That time is short (about 30 s), so
/// a long video still needs the app open; a cut-off upload says so.
@MainActor
private final class UploadKeepAlive {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Media upload") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func finish() {
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Square grid tile; videos get a play badge and duration.
struct MediaTile: View {
    @Environment(FamilyStore.self) private var store
    let item: MediaItem
    var selecting = false
    var selected = false
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
            .overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(selected ? Theme.accent : Color.black.opacity(0.45), in: Circle())
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Theme.accent, lineWidth: 3)
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
        .showsStoreErrors()  // a full-screen cover: Media's alert can't show over it
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
