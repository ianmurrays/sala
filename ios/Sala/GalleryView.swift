import AVKit
import LazyPager
import Photos
import SwiftUI

/// Albums → photo grid → full-screen viewer (API.md "Gallery"), laid out like the Photos app.
struct GalleryView: View {
    @Environment(Store.self) private var store
    @State private var albums = Paged<Album> { client, page in try await client.albums(page: page) }
    @State private var path: [Album] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Gallery")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 8)
                    if let error = albums.error {
                        BannerView(text: error) { albums.error = nil }
                    }
                    if let items = albums.items {
                        content(items)
                    } else if albums.error == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.screen)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await albums.load(store, reset: true) }
            .task {
                if albums.items == nil { await albums.load(store, reset: true) }
                #if DEBUG
                if DemoLaunch.openPhoto, let first = albums.items?.first { path = [first] }
                #endif
            }
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await albums.refreshURLs(store) } } }
            .navigationDestination(for: Album.self) { AlbumView(album: $0) }
        }
    }

    @ViewBuilder private func content(_ items: [Album]) -> some View {
        let shared = items.filter { !$0.tagged }
        if items.isEmpty {
            ContentUnavailableView("No albums", systemImage: "photo.on.rectangle",
                                   description: Text("Photos the institution shares show up here."))
        }
        // The tagged album leads, big, like Memories in Photos' Collections.
        ForEach(items.filter(\.tagged)) { album in
            NavigationLink(value: album) { AlbumCard(album: album, hero: true) }
                .buttonStyle(.plain)
        }
        if !shared.isEmpty {
            Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader).padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(shared) { album in
                    NavigationLink(value: album) { AlbumCard(album: album, hero: false) }
                        .buttonStyle(.plain)
                        .onAppear { if album.id == items.last?.id { Task { await albums.load(store) } } }
                }
            }
        }
    }
}

/// A cover with the title over it, as in Photos' Collections.
private struct AlbumCard: View {
    let album: Album
    let hero: Bool

    var body: some View {
        Color.clear
            .aspectRatio(hero ? 4 / 3 : 1, contentMode: .fit)
            .overlay { GalleryImage(id: album.cover, cache: true).scaledToFill() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title.isEmpty ? "Untitled" : album.title)
                        .font(hero ? .title2.bold() : .headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !hero, let date = album.date.flatMap(Fmt.timestamp) {
                        Text(Fmt.format(date, "dMMMyyyy")).font(.caption)
                    }
                }
                .foregroundStyle(.white)
                .padding(hero ? 16 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: hero ? 24 : 18, style: .continuous))
            .contentShape(.rect(cornerRadius: hero ? 24 : 18, style: .continuous))
    }
}

/// A photo grid with the viewer and Save to Photos: an album, or the photos of a search.
struct AlbumView: View {
    let title: String
    @Environment(Store.self) private var store
    @State private var photos: Paged<Photo>
    @State private var current = 0
    @State private var viewing = false
    @State private var selection: Set<Int>?
    @State private var saving: Int?
    @State private var message: String?
    @State private var selectingAll = false
    @Namespace private var zoom
    @Environment(\.scenePhase) private var scenePhase

    init(album: Album) {
        self.init(title: album.title, photos: Paged { client, page in try await client.photos(album: album.id, page: page) })
    }

    init(title: String, photos: Paged<Photo>) {
        self.title = title
        _photos = State(initialValue: photos)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let error = photos.error {
                    BannerView(text: error) { photos.error = nil }.padding(16)
                }
                if let items = photos.items {
                    if items.isEmpty {
                        ContentUnavailableView("No photos", systemImage: "photo", description: Text("This album has no photos."))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, photo in
                            cell(photo, index: i, last: photo.id == items.last?.id)
                        }
                    }
                } else if photos.error == nil {
                    ProgressView().padding(.top, 40)
                }
            }
            .onChange(of: viewing) { if !viewing { proxy.scrollTo(current) } }
        }
        .background(Color.screen)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarVisibility(selection == nil ? .automatic : .hidden, for: .tabBar)
        .refreshable { await photos.load(store, reset: true) }
        .task {
            if photos.items == nil { await photos.load(store, reset: true) }
            #if DEBUG
            // A photo followed by another, so SalaUITests can swipe from one photo to the next.
            let items = photos.items ?? []
            if DemoLaunch.openPhoto, let i = items.indices.first(where: { items[$0].video == nil && items.indices.contains($0 + 1) && items[$0 + 1].video == nil }) {
                DemoLaunch.openPhoto = false
                current = items[i].id
                viewing = true
            }
            #endif
        }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await photos.refreshURLs(store) } } }
        .fullScreenCover(isPresented: $viewing) {
            PhotoViewer(photos: photos, title: title, current: $current)
                .navigationTransition(.zoom(sourceID: current, in: zoom))
        }
        .toast($message)
    }

    private func cell(_ photo: Photo, index: Int, last: Bool) -> some View {
        let selected = selection?.contains(photo.id) == true
        return Button {
            if selection != nil {
                selection?.formSymmetricDifference([photo.id])
            } else {
                current = photo.id
                viewing = true
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { GalleryImage(id: photo.thumbnail, cache: true).scaledToFill() }
                .clipped()
                .overlay { if selected { Color.white.opacity(0.25) } }
                .overlay(alignment: .bottomLeading) {
                    if photo.video != nil {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .padding(4)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: photo.id, in: zoom)
        .id(photo.id)
        .accessibilityLabel(photo.video == nil ? "Photo \(index + 1)" : "Video \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onAppear { if last { Task { await photos.load(store) } } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(selection == nil ? "Select" : "Cancel") { selection = selection == nil ? [] : nil }
                .disabled(saving != nil || selectingAll || photos.items?.isEmpty != false)
        }
        if let selection {
            ToolbarItem(placement: .bottomBar) {
                if let saving {
                    Text("Saving \(saving + 1) of \(selection.count)…").font(.subheadline)
                } else {
                    Button("Save to Photos", systemImage: "square.and.arrow.down") { Task { await save() } }
                        .disabled(selection.isEmpty)
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Text(selection.isEmpty ? "Select Photos" : "\(selection.count) Selected").font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                if selectingAll {
                    ProgressView()
                } else if !selection.isEmpty, selection == Set((photos.items ?? []).map(\.id)) {
                    Button("Deselect All") { self.selection = [] }.disabled(saving != nil)
                } else {
                    // The whole album, not just the pages scrolled through so far.
                    Button("Select All") {
                        Task {
                            selectingAll = true
                            await photos.loadAll(store)
                            selectingAll = false
                            if self.selection != nil { self.selection = Set((photos.items ?? []).map(\.id)) }
                        }
                    }
                    .disabled(saving != nil)
                }
            }
        }
    }

    private func save() async {
        guard let selection else { return }
        let chosen = (photos.items ?? []).filter { selection.contains($0.id) }
        message = await saveToPhotos(chosen, store: store) { saving = $0 }
        saving = nil
        self.selection = nil
    }
}

/// Swipe between an album's photos, Photos style: title and date on top, a filmstrip below.
/// LazyPager does the paging and the gestures: dragging a page down closes it, a tap hides the chrome,
/// pinch or double-tap zooms a photo.
private struct PhotoViewer: View {
    let photos: Paged<Photo>
    let title: String
    @Binding var current: Int
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var chrome = true
    /// The black behind the pages, which LazyPager fades while a page is dragged down to close.
    @State private var backdrop: CGFloat = 1
    /// The space between the bars, and the screen's height: the pages' room for a video's controls.
    @State private var gap = CGRect.zero
    @State private var height: CGFloat = 0
    @State private var message: String?

    var body: some View {
        let items = photos.items ?? []
        let photo = items.first { $0.id == current }
        // LazyPager pages by index; the album keys photos by id.
        let index = Binding {
            items.firstIndex { $0.id == current } ?? 0
        } set: {
            if items.indices.contains($0) { current = items[$0].id }
        }
        ZStack {
            LazyPager(data: items, page: index) { photo in
                // Each page is hosted in UIKit, out of reach of the environment.
                page(photo).environment(store)
            }
            .zoomable { $0.video == nil ? .custom(min: 1, max: 4, doubleTap: .scale(0.5)) : .disabled }
            .onDismiss(backgroundOpacity: $backdrop) { dismiss() }
            .onTap { withAnimation { chrome.toggle() } }
            .shouldLoadMore { Task { await photos.load(store) } }
            .onChange(of: current) {
                // A video page has no tap to bring hidden bars back (the player takes taps), so show them.
                if photos.items?.first(where: { $0.id == current })?.video != nil { chrome = true }
            }
            .background(.black.opacity(backdrop))
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // Plain views over the pager, not a NavigationStack around it: LazyPager reads the safe area only
            // when a swipe settles, so bars that change it leave the photo off centre; and a NavigationStack
            // on top would swallow the pager's touches. Empty space here lets touches through.
            if chrome, backdrop == 1 {
                VStack(spacing: 0) {
                    ZStack {
                        VStack {
                            Text(title).font(.headline)
                            if let date = photo?.date.flatMap(Fmt.timestamp) {
                                Text(Fmt.format(date, "dMMMMHHmm")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 64)
                        bar {
                            Button("Close", systemImage: "chevron.backward") { dismiss() }
                        }
                    }
                    // The pages' room between the bars, for the video player's controls.
                    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gap = $0 }
                    Filmstrip(items: items, current: $current)
                    bar {
                        if saving {
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                guard let photo else { return }
                                Task {
                                    saving = true
                                    message = await saveToPhotos([photo], store: store)
                                    saving = false
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .toast($message)
        // LazyPager's drag closes it, moving only the page; the zoom transition's drag would move the whole cover.
        .interactiveDismissDisabled()
        // So the album shows through as a page is dragged down. The album also stays in the accessibility
        // tree, so check this screen with screenshots or the "viewer.photo" frame, not a snapshot's list.
        .presentationBackground(.clear)
        .colorScheme(.dark)
    }

    /// A row of round glass buttons at the leading edge, like a toolbar's.
    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            content().labelStyle(.iconOnly).font(.title3).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            Spacer()
        }
        .padding(.horizontal)
    }

    @ViewBuilder private func page(_ photo: Photo) -> some View {
        if let video = photo.video {
            VideoPage(video: video, still: photo.image, thumbnail: photo.thumbnail, active: photo.id == current,
                      insets: EdgeInsets(top: gap.minY, leading: 0, bottom: max(0, height - gap.maxY), trailing: 0))
        } else {
            // The cached thumbnail stands in while the original loads.
            GalleryImage(id: photo.image, cache: false) {
                GalleryImage(id: photo.thumbnail, cache: true).scaledToFit()
            }
            .scaledToFit()
            .accessibilityIdentifier("viewer.photo")
        }
    }
}

/// A video in the viewer: its still with a play button; a tap downloads the mp4 and plays it.
/// Paging away pauses it.
private struct VideoPage: View {
    let video: String
    let still: String?
    let thumbnail: String?
    let active: Bool
    let insets: EdgeInsets
    @Environment(Store.self) private var store
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var failed: String?
    @State private var load: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let player {
                // Keeps the player's controls clear of the bars and filmstrip.
                VideoPlayer(player: player).padding(insets)
            } else {
                GalleryImage(id: still, cache: false) {
                    GalleryImage(id: thumbnail, cache: true).scaledToFit()
                }
                .scaledToFit()
                Button {
                    load = Task { await play() }
                } label: {
                    if loading {
                        ProgressView().controlSize(.large).padding(24)
                    } else {
                        Image(systemName: "play.fill").font(.largeTitle).padding(24)
                    }
                }
                .glassEffect(in: .circle)
                .disabled(loading)
                .accessibilityLabel("Play video")
                if let failed {
                    Text(failed).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect().frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
                }
            }
        }
        // Paging away also drops a download still under way, so it can't start playing off screen.
        .onChange(of: active) { if !active { load?.cancel(); player?.pause() } }
        .onDisappear {
            load?.cancel()
            player?.pause()
            // Lets music or a podcast that the video interrupted resume. Fails harmlessly while another page plays.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func play() async {
        // Plays sound with the ring switch on silent, as Photos does.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        loading = true
        failed = nil
        defer { loading = false }
        do {
            let file = try await store.client.video(video)
            guard !Task.isCancelled else { return }
            let p = AVPlayer(url: file)
            player = p
            p.play()
        } catch {
            guard !Task.isCancelled else { return }
            if let msg = store.handle(error) { failed = "Couldn't load the video. \(msg)" }
        }
    }
}

private struct Filmstrip: View {
    let items: [Photo]
    @Binding var current: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 2) {
                    ForEach(items) { photo in
                        GalleryImage(id: photo.thumbnail, cache: true)
                            .scaledToFill()
                            .frame(width: photo.id == current ? 48 : 28, height: 40)
                            .clipped()
                            .padding(.horizontal, photo.id == current ? 6 : 0)
                            .onTapGesture { current = photo.id }
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 160, for: .scrollContent)
            .frame(height: 40)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

/// Fetches each original and adds it to Photos, one at a time; returns the message to show.
@MainActor private func saveToPhotos(_ photos: [Photo], store: Store, progress: (Int) -> Void = { _ in }) async -> String? {
    guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
        return "Sala may not add photos. Allow it in Settings › Apps › Sala › Photos."
    }
    for (i, photo) in photos.enumerated() {
        progress(i)
        do {
            if let video = photo.video {
                try await addVideoToPhotos(try await store.client.video(video))
            } else if let image = photo.image {
                try await addToPhotos(try await store.client.picture(image))
            }
        } catch {
            guard let msg = store.handle(error) else { return nil }
            return i == 0 ? "Couldn't save. \(msg)" : "Saved \(i) of \(photos.count). \(msg)"
        }
    }
    return photos.count == 1 ? "Saved to Photos" : "Saved \(photos.count) items to Photos"
}

/// Outside the main actor: PhotoKit runs the change block on its own queue, and a block
/// written in a main-actor view would assert it's on the main thread and crash.
nonisolated private func addToPhotos(_ data: Data) async throws {
    try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
    }
}

nonisolated private func addVideoToPhotos(_ file: URL) async throws {
    try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
    }
}

private extension View {
    /// A glass capsule at the bottom that hides itself after 3 s.
    func toast(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                Text(text)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 100)
                    .task(id: text) { try? await Task.sleep(for: .seconds(3)); message.wrappedValue = nil }
            }
        }
    }
}

/// An image from `GET /attachments/{id}`, or `placeholder` while it loads, when there is none, or when it fails.
private struct GalleryImage<Placeholder: View>: View {
    let id: String?
    /// Keep the decoded image in memory: thumbnails yes, full-size originals no (the disk cache has them).
    let cache: Bool
    @ViewBuilder let placeholder: Placeholder
    @Environment(Store.self) private var store
    @State private var image: UIImage?

    init(id: String?, cache: Bool, @ViewBuilder placeholder: () -> Placeholder = { Color.secondary.opacity(0.15) }) {
        self.id = id; self.cache = cache; self.placeholder = placeholder()
        _image = State(initialValue: id.flatMap { thumbnailCache.object(forKey: $0 as NSString) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder
            }
        }
        .task(id: id) {
            image = id.flatMap { thumbnailCache.object(forKey: $0 as NSString) }
            guard let id, image == nil else { return }
            // ponytail: a failure keeps the placeholder; scrolling away and back retries.
            guard let data = try? await store.client.picture(id),
                  let loaded = await UIImage(data: data)?.byPreparingForDisplay() else { return }
            if cache { thumbnailCache.setObject(loaded, forKey: id as NSString) }
            image = loaded
        }
    }
}

@MainActor private let thumbnailCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 300
    return cache
}()

/// A list loaded a page at a time (1-based pages, an empty page ends it), for albums and photos.
@MainActor @Observable
final class Paged<Item: Identifiable & Sendable> {
    var items: [Item]?
    var error: String?
    private var next = 1
    private var done = false
    private var loading = false
    private let fetch: @Sendable (APIClient, Int) async throws -> [Item]

    init(fetch: @escaping @Sendable (APIClient, Int) async throws -> [Item]) { self.fetch = fetch }

    /// `reset` loads page 1 again and replaces the list; otherwise loads the next page, if any.
    func load(_ store: Store, reset: Bool = false) async {
        guard !loading, reset || (!done && items != nil) else { return }
        loading = true
        defer { loading = false }
        let page = reset ? 1 : next
        do {
            let new = try await fetch(store.client, page)
            // Pages shift when photos are added meanwhile; never show one twice.
            let seen = Set((reset ? [] : items ?? []).map(\.id))
            items = (reset ? [] : items ?? []) + new.filter { !seen.contains($0.id) }
            next = page + 1
            done = new.isEmpty
            error = nil
        } catch {
            if let msg = store.handle(error) { self.error = msg }
        }
    }

    /// Requests the loaded pages again and drops the answers: ids are stable, but Aula's
    /// image URLs expire, and listing is what makes the server store fresh ones.
    func refreshURLs(_ store: Store) async {
        guard items != nil else { return }
        for page in 1..<next { _ = try? await fetch(store.client, page) }
    }

    /// Loads every remaining page, for Select All.
    func loadAll(_ store: Store) async {
        while !done, error == nil, items != nil {
            if loading { try? await Task.sleep(for: .milliseconds(100)); continue }
            let before = items?.count
            await load(store)
            if items?.count == before { break }  // nothing new: the end, or a failure handled elsewhere
        }
    }
}
