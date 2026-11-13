import SwiftUI

/// Aula's global search (API.md "Search"): messages, posts and photos, one type at a time.
struct SearchView: View {
    @Environment(Store.self) private var store
    @State private var text = ""
    @State private var run: SearchRun?
    @State private var type = SearchRun.types[0]
    @State private var attachments = AttachmentOpener()
    @State private var banner: String?

    var body: some View {
        NavigationStack {
            content
                .background(Color.screen)
                .navigationTitle("Search")
                .navigationDestination(for: String.self) { ThreadView(threadID: $0) }
                .quickLookPreview(attachments)
        }
        .searchable(text: $text, prompt: "Messages, posts and photos")
        .onSubmit(of: .search) { search() }
    }

    @ViewBuilder private var content: some View {
        if let run {
            if let counts = run.counts {
                let shown = SearchRun.types.filter { counts[$0] > 0 }
                if shown.isEmpty {
                    ContentUnavailableView.search(text: run.query)
                } else {
                    results(run, counts: counts, shown: shown)
                }
            } else if let error = run.error {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        } else {
            ContentUnavailableView("Search Aula", systemImage: "magnifyingglass",
                description: Text("Find messages, posts and photos by a word in them."))
        }
    }

    private func results(_ run: SearchRun, counts: SearchResults.Counts, shown: [String]) -> some View {
        Group {
            switch type {
            case "posts": posts(run.posts)
            case "photos": AlbumView(title: "Photos", photos: run.photos).id(ObjectIdentifier(run))
            default: messages(run.messages)
            }
        }
        .safeAreaInset(edge: .top) {
            if shown.count > 1 {
                Picker("Type", selection: $type) {
                    ForEach(shown, id: \.self) { Text("\(SearchRun.label($0)) \(counts[$0])").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private func messages(_ paged: Paged<SearchMessage>) -> some View {
        List {
            if let error = paged.error { BannerView(text: error) { paged.error = nil } }
            ForEach(paged.items ?? []) { m in
                NavigationLink(value: m.threadId) { SearchMessageRow(message: m) }
                    .onAppear { if m.id == paged.items?.last?.id { Task { await paged.load(store) } } }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay { if paged.items == nil && paged.error == nil { ProgressView() } }
        .task(id: ObjectIdentifier(paged)) { if paged.items == nil { await paged.load(store, reset: true) } }
    }

    private func posts(_ paged: Paged<Post>) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let banner { BannerView(text: banner) { self.banner = nil } }
                if let error = paged.error { BannerView(text: error) { paged.error = nil } }
                ForEach(paged.items ?? []) { post in
                    PostCard(post: post, downloading: attachments.downloading, open: open, canSave: false)
                        .onAppear { if post.id == paged.items?.last?.id { Task { await paged.load(store) } } }
                }
            }
            .padding(16)
        }
        .overlay { if paged.items == nil && paged.error == nil { ProgressView() } }
        .task(id: ObjectIdentifier(paged)) { if paged.items == nil { await paged.load(store, reset: true) } }
    }

    private func open(_ attachment: Attachment) {
        attachments.open(attachment, store: store) { banner = $0 }
    }

    private func search() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let run = SearchRun(query)
        self.run = run
        Task {
            // ponytail: page 1 of messages is fetched again by its list; one extra call per search for the counts.
            do {
                let first = try await store.client.search(query, type: "messages", page: 1)
                guard self.run === run else { return }
                run.counts = first.counts
                type = SearchRun.types.first { first.counts[$0] > 0 } ?? SearchRun.types[0]
            } catch {
                run.error = store.handle(error) ?? "Couldn't search."
            }
        }
    }
}

/// One submitted search: its counts and a pager per type, replaced on the next submit so a late answer can't land.
@MainActor @Observable
final class SearchRun {
    static let types = ["messages", "posts", "photos"]
    static func label(_ type: String) -> String { ["messages": "Messages", "posts": "Posts", "photos": "Photos"][type] ?? type }

    let query: String
    var counts: SearchResults.Counts?
    var error: String?
    let messages: Paged<SearchMessage>
    let posts: Paged<Post>
    let photos: Paged<Photo>

    init(_ query: String) {
        self.query = query
        messages = Paged { try await $0.search(query, type: "messages", page: $1).messages }
        posts = Paged { try await $0.search(query, type: "posts", page: $1).posts }
        photos = Paged { try await $0.search(query, type: "photos", page: $1).photos }
    }
}

extension SearchResults.Counts {
    subscript(type: String) -> Int {
        switch type {
        case "posts": posts
        case "photos": photos
        default: messages
        }
    }
}

private struct SearchMessageRow: View {
    let message: SearchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.timestamp(message.date).map { Fmt.relative($0) } ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(message.from).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if !message.preview.isEmpty {
                Text(message.preview).font(.subheadline).foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
