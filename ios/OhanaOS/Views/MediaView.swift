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
    @State private var progress = UploadProgress()
    @State private var uploadTask: Task<Void, Never>?
    @State private var viewing: MediaViewerLaunch?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingDelete = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Three across on a phone; more, at about the same tile size, on the
    /// iPhone Duo's inner display.
    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 130), spacing: 3)]
            : Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    }

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
                                        .disabled(uploadTask != nil)
                                        .accessibilityLabel("Select photos and videos")
                                }
                                // .current: hand over the original without the picker's own
                                // transcode. Videos are optimized for the wall here anyway.
                                PhotosPicker(selection: $selection, maxSelectionCount: 30, matching: .any(of: [.images, .videos]),
                                             preferredItemEncoding: .current) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Theme.accent, in: Circle())
                                }
                                .disabled(uploadTask != nil)
                                .accessibilityLabel("Add photos and videos")
                            }
                        }
                    }
                    .padding(.horizontal, Theme.page)

                    SegmentedPill(MediaFilter.allCases, selection: $filter) { $0.rawValue }
                        .padding(.horizontal, Theme.page)

                    if progress.isActive {
                        UploadBanner(progress: progress) { uploadTask?.cancel() }
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
                .animation(Theme.springy, value: progress.isActive)
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
                guard !picked.isEmpty, uploadTask == nil else { return }
                uploadTask = Task {
                    await upload(picked)
                    uploadTask = nil
                }
            }
            .showsStoreErrors()
        }
    }

    /// Uploads one item at a time (one big PUT already fills the uplink),
    /// while the next item is fetched from Photos and optimized.
    @MainActor
    private func upload(_ picked: [PhotosPickerItem]) async {
        guard !picked.isEmpty else { return }
        let progress = self.progress
        let store = self.store
        withAnimation(Theme.springy) { progress.start(total: picked.count) }
        let keepAlive = UploadKeepAlive()
        await MediaTools.removeStaleTempVideos()
        var failed = 0
        var lastReason: String?
        var next: Task<PreparedUpload, Never>? = Task { await prepare(picked[0], index: 0) }
        for i in picked.indices {
            guard let current = next else { break }
            next = nil
            // Cancel has to reach an export that's already running, not only
            // the next step: the prepare task isn't a child of this one.
            let item = await withTaskCancellationHandler {
                await current.value
            } onCancel: {
                current.cancel()
            }
            if Task.isCancelled {
                item.cleanup()
                break
            }
            if i + 1 < picked.count {
                next = Task { await prepare(picked[i + 1], index: i + 1) }
            }
            let uploaded = await send(item, index: i)
            item.cleanup()
            if Task.isCancelled { break }
            if !uploaded {
                failed += 1
                lastReason = store.errorMessage ?? lastReason
            }
            withAnimation(Theme.springy) { progress.finished(item: i) }
        }
        // After Cancel the look-ahead may still be exporting: stop it and
        // remove what it made.
        if let next {
            next.cancel()
            await next.value.cleanup()
        }
        let cancelled = Task.isCancelled
        selection = []
        // Its own task: after Cancel this one is cancelled, and the refresh
        // must still run so what did upload shows up.
        await Task { await store.refreshMedia() }.value
        keepAlive.finish()
        if !cancelled, failed > 0, picked.count > 1 {
            // Say how many didn't make it, not only the last reason.
            let summary = failed == picked.count
                ? "None of the \(picked.count) uploaded."
                : "\(failed) of \(picked.count) didn't upload."
            store.errorMessage = [summary, lastReason].compactMap { $0 }.joined(separator: " ")
        }
        withAnimation(Theme.springy) { progress.reset() }
    }

    /// Gets one picked item ready to send. Progress is reported under its
    /// index, so the banner can tell the current item from the next one.
    @MainActor
    private func prepare(_ item: PhotosPickerItem, index: Int) async -> PreparedUpload {
        let progress = self.progress
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        progress.report(.fetching(isVideo: isVideo), item: index)
        guard isVideo else {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                return .failed(Task.isCancelled ? nil : "That photo couldn't be used. Try another one.")
            }
            guard let photo = await MediaTools.preparePhotoAsync(data) else {
                return .failed("That photo couldn't be used. Try another one.")
            }
            return .photo(photo.data, photo.metadata)
        }

        let picked: URL
        do {
            guard let video = try await item.loadTransferable(type: MediaTools.PickedVideo.self) else {
                return .failed("That video couldn't be read. Try another one.")
            }
            picked = video.url
        } catch {
            return .failed(Task.isCancelled ? nil : "That video couldn't be read. Try another one.")
        }
        do {
            let video = try await MediaTools.prepareVideo(picked, progress: { fraction in
                Task { @MainActor in progress.report(.optimizing(fraction), item: index) }
            })
            // Free the space now: a 4K original can take gigabytes.
            if video.url != picked { try? FileManager.default.removeItem(at: picked) }
            return .video(video)
        } catch {
            if Task.isCancelled || error is CancellationError {
                try? FileManager.default.removeItem(at: picked)
                return .failed(nil)
            }
            if (error as? MediaTools.VideoPrepError) == .interrupted {
                // Not the original instead: a big one can't upload in the background either.
                try? FileManager.default.removeItem(at: picked)
                return .failed("A video stopped optimizing when Ohana left the screen. "
                    + "Keep Ohana open while videos upload, then add it again.")
            }
            // Last resort: the original as it is. The server makes the wall copy.
            print("OhanaOS video prep:", error)
            var metadata = await MediaTools.videoMetadata(at: picked)
            metadata.thumbnail = await MediaTools.posterJPEG(for: picked, durationSeconds: metadata.durationSeconds ?? 0)
            metadata.processing = "pending"
            let ext = picked.pathExtension.isEmpty ? "mov" : picked.pathExtension.lowercased()
            return .video(MediaTools.PreparedVideo(url: picked, fileExtension: ext, metadata: metadata))
        }
    }

    /// Uploads a prepared item. False when it failed (the store has the reason).
    @MainActor
    private func send(_ item: PreparedUpload, index: Int) async -> Bool {
        let progress = self.progress
        let onBytes: @Sendable (Int64, Int64) -> Void = { sent, total in
            Task { @MainActor in progress.report(.uploading(sent: sent, total: total), item: index) }
        }
        switch item {
        case let .photo(data, metadata):
            return await store.upload(data: data, isVideo: false, fileExtension: "jpg", metadata: metadata,
                                      progress: onBytes)
        case let .video(video):
            return await store.upload(file: video.url, fileExtension: video.fileExtension, metadata: video.metadata,
                                      progress: onBytes)
        case let .failed(reason):
            if let reason { store.errorMessage = reason }
            return false
        }
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

/// A picked item, ready to send.
private enum PreparedUpload: Sendable {
    case photo(Data, MediaMetadata)
    /// Its file is a temp copy (or an export) that `cleanup` deletes.
    case video(MediaTools.PreparedVideo)
    /// Nothing to send; the reason is shown. Nil after Cancel.
    case failed(String?)

    func cleanup() {
        if case let .video(video) = self { try? FileManager.default.removeItem(at: video.url) }
    }
}

/// What the upload banner shows. Reports carry the item's index, because
/// the next item is fetched and optimized while the current one uploads.
@MainActor
@Observable
final class UploadProgress {
    enum Phase {
        case fetching(isVideo: Bool)
        case optimizing(Double)
        case uploading(sent: Int64, total: Int64)
    }

    private struct Item {
        var phase: Phase
        var transcoded = false
        var optimized = 0.0
        var sent = 0.0
    }

    private(set) var total = 0
    /// The item being uploaded, from 0.
    private(set) var index = 0
    private var items: [Int: Item] = [:]

    var isActive: Bool { total > 0 }
    var phase: Phase? { items[index]?.phase }

    /// The next item's optimizing progress, while it runs ahead.
    var nextOptimizing: Double? {
        if case let .optimizing(fraction)? = items[index + 1]?.phase { return fraction }
        return nil
    }

    /// The whole batch, 0...1. An optimized video counts its export as 40 %
    /// of the item and the bytes as the rest; anything else just its bytes.
    var fraction: Double {
        guard total > 0 else { return 0 }
        var done = Double(index)
        if let item = items[index] {
            done += item.transcoded ? 0.4 * item.optimized + 0.6 * item.sent : item.sent
        }
        return min(1, done / Double(total))
    }

    func start(total: Int) {
        self.total = total
        index = 0
        items = [:]
    }

    func report(_ phase: Phase, item i: Int) {
        // Late news about a finished item, or after the batch ended.
        guard i >= index, i < total else { return }
        var item = items[i] ?? Item(phase: phase)
        // Updates hop to the main actor in their own tasks and can arrive
        // out of order: once bytes are moving, ignore earlier phases.
        if case .uploading = item.phase, !Self.isUploading(phase) { return }
        item.phase = phase
        switch phase {
        case .fetching:
            break
        case let .optimizing(fraction):
            item.transcoded = true
            item.optimized = max(item.optimized, min(1, fraction))
        case let .uploading(sent, total):
            item.optimized = 1
            if total > 0 { item.sent = max(item.sent, min(1, Double(sent) / Double(total))) }
        }
        items[i] = item
    }

    func finished(item i: Int) {
        items[i] = nil
        index = max(index, i + 1)
    }

    func reset() {
        total = 0
        index = 0
        items = [:]
    }

    private static func isUploading(_ phase: Phase) -> Bool {
        if case .uploading = phase { return true }
        return false
    }
}

/// "Uploading 2 of 5", what that item is doing, and Cancel.
private struct UploadBanner: View {
    let progress: UploadProgress
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 6) {
                Text("Uploading \(min(progress.index + 1, progress.total)) of \(progress.total)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(progress.index)))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
                ProgressBar(value: progress.fraction)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.pill(.soft))
                .accessibilityLabel("Cancel uploading")
        }
        .card(padding: 14, radius: Theme.radiusSm + 4)
    }

    private var detail: String? {
        switch progress.phase {
        case .fetching(let isVideo)?:
            // The picker reports no progress here (iCloud downloads included).
            return isVideo ? "Getting the video from Photos…" : "Getting the photo from Photos…"
        case .optimizing(let fraction)?:
            return "Optimizing for the wall display… \(Int((fraction * 100).rounded()))%"
        case let .uploading(sent, total)?:
            if total > 0, sent >= total { return "Saving…" }
            let file = ByteCountFormatter.CountStyle.file
            return "Uploading \(ByteCountFormatter.string(fromByteCount: sent, countStyle: file)) of "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: file)
        case nil:
            return nil
        }
    }

    private var note: String {
        if let next = progress.nextOptimizing {
            return "Next: optimizing \(Int((next * 100).rounded()))%. Keep Ohana open until this finishes."
        }
        return "Keep Ohana open until this finishes."
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
                let loaded = await MediaCache.shared.thumbnail(for: item, store: store)
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
        _ = await MediaCache.shared.thumbnail(for: item, store: store)
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

    /// The photo, or a video's poster until its player exists.
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if item.isVideo {
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay { ProgressView().tint(.white) }
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
            // A video's poster, alongside the player below rather than before
            // it, so it never holds up playback. No frame from the remote file:
            // that isn't quick, and rows without a poster just show the spinner.
            guard item.isVideo, player == nil, image == nil else { return }
            image = MediaCache.shared.cachedThumbnail(for: item)
            guard image == nil, let poster = await store.posterURL(for: item) else { return }
            let loaded = await MediaCache.shared.thumbnail(for: item, url: poster, isPoster: true)
            if player == nil { image = loaded }
        }
        .task(id: item.storagePath) {
            #if DEBUG
            if DemoMode.isOn {
                // Demo photos are drawn on the phone; demo videos have no file to play.
                if !item.isVideo { image = await DemoMedia.fullImage(for: item) }
                return
            }
            #endif
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
