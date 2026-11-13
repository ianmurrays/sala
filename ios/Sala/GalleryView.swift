import Photos
import SwiftUI

/// Albums → photo grid → full-screen viewer (API.md "Gallery"), laid out like the Photos app.
struct GalleryView: View {
    @Environment(Store.self) private var store
    @State private var albums = Paged<Album> { client, page in try await client.albums(page: page) }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
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
            .task { if albums.items == nil { await albums.load(store, reset: true) } }
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

private struct AlbumView: View {
    let album: Album
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
        self.album = album
        _photos = State(initialValue: Paged { client, page in try await client.photos(album: album.id, page: page) })
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
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarVisibility(selection == nil ? .automatic : .hidden, for: .tabBar)
        .refreshable { await photos.load(store, reset: true) }
        .task { if photos.items == nil { await photos.load(store, reset: true) } }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await photos.refreshURLs(store) } } }
        .fullScreenCover(isPresented: $viewing) {
            PhotoViewer(photos: photos, title: album.title, current: $current)
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
        .accessibilityLabel("Photo \(index + 1)")
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
/// Swiping down closes it (the zoom transition's own gesture); a tap hides the chrome;
/// pinch or double-tap zooms.
private struct PhotoViewer: View {
    let photos: Paged<Photo>
    let title: String
    @Binding var current: Int
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var chrome = true
    @State private var zoomed = false
    @State private var message: String?

    var body: some View {
        let items = photos.items ?? []
        let photo = items.first { $0.id == current }
        NavigationStack {
            TabView(selection: $current) {
                ForEach(items) { photo in
                    Zoomable(active: photo.id == current, zoomed: $zoomed) {
                        withAnimation { chrome.toggle() }
                    } content: {
                        // The cached thumbnail stands in while the original loads.
                        GalleryImage(id: photo.image, cache: false) {
                            GalleryImage(id: photo.thumbnail, cache: true).scaledToFit()
                        }
                        .scaledToFit()
                        .environment(store)
                    }
                    .tag(photo.id)
                    .onAppear { if photo.id == items.last?.id { Task { await photos.load(store) } } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Zoomed in, a pan moves within the photo instead of paging or closing.
            .scrollDisabled(zoomed)
            // The filmstrip can jump away from a zoomed page before it reports zooming out.
            .onChange(of: current) { zoomed = false }
            .background(.black)
            .ignoresSafeArea()
            .safeAreaInset(edge: .bottom) {
                if chrome { Filmstrip(items: items, current: $current) }
            }
            .navigationTitle(title)
            .navigationSubtitle(photo?.date.flatMap(Fmt.timestamp).map { Fmt.format($0, "dMMMMHHmm") } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.backward") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    if saving {
                        ProgressView()
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
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            .toolbarVisibility(chrome ? .visible : .hidden, for: .navigationBar, .bottomBar)
            .toast($message)
        }
        .interactiveDismissDisabled(zoomed)
        .colorScheme(.dark)
    }
}

/// Pinch or double-tap to zoom `content`, Photos style. `onTap` runs on a single tap, once it can't be a double-tap.
/// SwiftUI has no zoomable scroll view, hence UIKit. Leaving the page (`active` false) zooms back out.
private struct Zoomable<Content: View>: UIViewRepresentable {
    let active: Bool
    @Binding var zoomed: Bool
    let onTap: () -> Void
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(host: UIHostingController(rootView: content)) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let c = context.coordinator
        c.host.safeAreaRegions = []
        c.host.view.backgroundColor = .clear
        let scroll = ZoomScrollView(content: c.host.view)
        scroll.delegate = c
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host.rootView = content
        if !active, scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: false) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        var parent: Zoomable?
        init(host: UIHostingController<Content>) { self.host = host }

        func viewForZooming(in scroll: UIScrollView) -> UIView? { host.view }

        func scrollViewDidZoom(_ scroll: UIScrollView) {
            let zoomed = scroll.zoomScale > 1
            // Also called from updateUIView, where SwiftUI state mustn't change.
            DispatchQueue.main.async { [parent] in if parent?.zoomed != zoomed { parent?.zoomed = zoomed } }
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { return scroll.setZoomScale(1, animated: true) }
            let point = tap.location(in: host.view)
            let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }

        @objc func singleTap() { parent?.onTap() }
    }
}

/// Keeps the zoomed view the size of the page while zoomed out.
// ponytail: the view spans the page, not just the photo, so a zoomed-in landscape photo pans into its black bars.
// Size it to the image's aspect ratio if that bothers anyone.
private final class ZoomScrollView: UIScrollView {
    private let content: UIView
    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1 else { return }
        content.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}

/// The row of thumbnails under the viewer; the current one is wider and centred.
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
            try await addToPhotos(try await store.client.picture(photo.image))
        } catch {
            guard let msg = store.handle(error) else { return nil }
            return i == 0 ? "Couldn't save. \(msg)" : "Saved \(i) of \(photos.count). \(msg)"
        }
    }
    return photos.count == 1 ? "Saved to Photos" : "Saved \(photos.count) photos to Photos"
}

/// Outside the main actor: PhotoKit runs the change block on its own queue, and a block
/// written in a main-actor view would assert it's on the main thread and crash.
nonisolated private func addToPhotos(_ data: Data) async throws {
    try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
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
