import SwiftUI

struct TodayView: View {
    @Environment(Store.self) private var store
    @State private var pickupChild: Child?
    @State private var holidayItem: AttentionItem?
    @State private var showAbsence = false
    @State private var showHolidays = false
    @State private var showContacts = false
    @State private var attachments = AttachmentOpener()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if let banner = store.banner { BannerView(text: banner) { store.banner = nil } }
                    if let error = store.loadError { BannerView(text: error) { store.loadError = nil } }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.screen)
            .refreshable { await store.load() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $pickupChild) { child in
                PickupSheet(child: child)
            }
            .sheet(item: $holidayItem) { item in
                HolidaySheet(id: item.id, fallbackTitle: item.title)
            }
            .sheet(isPresented: $showHolidays) {
                HolidaysView()
            }
            .sheet(isPresented: $showAbsence) {
                AbsenceSheet()
            }
            .sheet(isPresented: $showContacts) {
                ContactsView()
            }
            .quickLookPreview(attachments)
        }
    }

    // MARK: Header

    private var headerDate: Date { store.today.flatMap { Fmt.day($0.date) } ?? Date() }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.format(headerDate, "EEEEdMMMM").uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Today")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            // Contacts isn't a tab: with Search, a sixth tab sends the last two under iOS's More (#32).
            Button {
                showContacts = true
            } label: {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Contacts")
            Button {
                store.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let today = store.today {
            loaded(today)
        } else {
            switch store.phase {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't load Today", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await store.load() } }
                        .buttonStyle(.glassProminent)
                }
                .padding(.top, 40)
            default:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
    }

    @ViewBuilder private func loaded(_ today: Today) -> some View {
        if today.children.isEmpty {
            Text("No children on this account.")
                .foregroundStyle(.secondary)
                .card()
        }
        ForEach(today.children) { child in
            ChildCard(child: child) { pickupChild = child }
        }
        if !today.children.isEmpty {
            HStack(spacing: 10) {
                Button { showAbsence = true } label: {
                    Label("Register holiday or days off", systemImage: "sun.max")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                Button { showHolidays = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 30, minHeight: 30)
                }
                .accessibilityLabel("Registered holidays")
            }
            .buttonStyle(.glass)
            .tint(.salaAccent)
        }

        let stillSick = store.stillSickChildren
        if !today.attention.isEmpty || !stillSick.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Needs attention")
                VStack(spacing: 0) {
                    ForEach(Array(stillSick.enumerated()), id: \.element.id) { i, child in
                        if i > 0 { Divider().padding(.leading, 56) }
                        StillSickRow(child: child)
                    }
                    ForEach(Array(today.attention.enumerated()), id: \.element.id) { i, item in
                        if i > 0 || !stillSick.isEmpty { Divider().padding(.leading, 56) }
                        AttentionRow(item: item) {
                            if item.kind == "holiday_request" { holidayItem = item } else { store.openThread(item.threadId) }
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color.card, in: .rect(cornerRadius: 26, style: .continuous))
            }
        }

        if !today.upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Coming up")
                VStack(spacing: 0) {
                    ForEach(Array(today.upcoming.enumerated()), id: \.offset) { i, item in
                        if i > 0 { Divider().padding(.leading, 72) }
                        UpcomingRow(item: item)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.card, in: .rect(cornerRadius: 26, style: .continuous))
            }
        }

        if !today.posts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(postsTitle(today))
                // Lazy, so the last card appearing means it was scrolled to. Keyed on the epoch so a reload
                // that keeps the last card on screen still asks for the next page.
                LazyVStack(spacing: 12) {
                    ForEach(today.posts) { post in
                        PostCard(post: post, downloading: attachments.downloading, open: open)
                            .task(id: store.morePosts.epoch) {
                                if post.id == today.posts.last?.id { await store.loadMorePosts() }
                            }
                    }
                    LoadMoreRow(paging: store.morePosts) { await store.retryMorePosts() }
                }
            }
        }
    }

    private func postsTitle(_ today: Today) -> String {
        let names = Set(today.children.map(\.institution).filter { !$0.isEmpty })
        if names.count == 1, let name = names.first { return "From \(name)" }
        return "From the institutions"
    }

    private func open(_ attachment: Attachment) {
        attachments.open(attachment, store: store) { store.banner = $0 }
    }
}

// MARK: - Pieces

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Under a paged list: a spinner while the next page loads, or "Try again" after it failed.
struct LoadMoreRow: View {
    let paging: Paging
    let retry: () async -> Void

    var body: some View {
        if paging.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if let error = paging.error {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await retry() } }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.sickText)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.sickFill, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

struct Avatar: View {
    let name: String
    var picture: String? = nil
    var size: CGFloat = 44
    var body: some View {
        ProfilePicture(id: picture, size: size) {
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.salaAccent)
                .frame(width: size, height: size)
                .background(Color.salaAccent.opacity(0.14), in: .circle)
        }
        .accessibilityHidden(true)
    }
}

/// A profile picture from the server, or `fallback` (initials) while it loads, when there is none, or when it fails.
struct ProfilePicture<Fallback: View>: View {
    let id: String?
    let size: CGFloat
    @ViewBuilder let fallback: Fallback
    @Environment(Store.self) private var store
    @State private var image: UIImage?

    init(id: String?, size: CGFloat, @ViewBuilder fallback: () -> Fallback) {
        self.id = id; self.size = size; self.fallback = fallback()
        _image = State(initialValue: id.flatMap { pictureCache.object(forKey: $0 as NSString) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(.circle)
            } else {
                fallback
            }
        }
        .task(id: id) {
            // A row can be reused for another person: never keep the previous face while loading.
            image = id.flatMap { pictureCache.object(forKey: $0 as NSString) }
            guard let id, image == nil else { return }
            // ponytail: a failure just keeps the initials; no banner, no retry until the view comes back.
            guard let data = try? await store.client.picture(id), let loaded = UIImage(data: data) else { return }
            pictureCache.setObject(loaded, forKey: id as NSString)
            image = loaded
        }
    }
}

/// Decoded pictures by id, so scrolling back doesn't decode again. The disk copy is `APIClient.picture`'s URL cache.
@MainActor private let pictureCache = NSCache<NSString, UIImage>()

struct StatusPill: View {
    let child: Child

    private var text: String {
        switch child.status {
        case "present":
            return child.arrivedAt.map { "\(child.statusLabel) · in \($0)" } ?? child.statusLabel
        case "gone_home":
            return child.leftAt.map { "\(child.statusLabel) · left \($0)" } ?? child.statusLabel
        default:
            return child.statusLabel
        }
    }

    private var colors: (Color, Color) { child.statusColors }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colors.0).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(colors.0)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(colors.1, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
    }
}

struct ChildCard: View {
    @Environment(Store.self) private var store
    let child: Child
    let changePickup: () -> Void

    private var isSick: Bool { child.status == "sick" }
    private var busy: Bool { store.sickInFlight.contains(child.id) }
    @State private var confirmSick = false

    /// Drop-off only matters until the child arrives; after that the status shows the arrival time.
    private var dropoff: String? { child.status == "not_arrived" ? child.dropoff : nil }

    private var pickupHeader: String {
        let title = dropoff == nil ? "Pickup today" : "Today"
        return child.closesAt.map { "\(title) · closes \($0)" } ?? title
    }

    private var pickupText: String {
        let parts = [child.pickup?.time, child.pickup?.by].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.isEmpty { return "No pickup set" }
        return (dropoff == nil ? "" : "Pickup ") + parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: child.name, picture: child.picture)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name).font(.title3.bold())
                    Text([child.institution, child.group].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            StatusPill(child: child)
                .animation(.snappy, value: child.status)

            VStack(alignment: .leading, spacing: 4) {
                Text(pickupHeader)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let dropoff {
                    Text("Drop-off \(dropoff)")
                        .font(.title3.weight(.semibold))
                }
                Text(pickupText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(child.pickup?.time == nil && child.pickup?.by == nil ? .secondary : .primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.screen, in: .rect(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)

            // One line per label, equal heights: drop the icons before stacking the buttons.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons(icons: true) }.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { buttons(icons: false) }.fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) { buttons(icons: true) }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .sensoryFeedback(.success, trigger: child.status) { old, new in old != new && (old == "sick" || new == "sick") }
        // On the card, not the button: ViewThatFits builds the buttons up to three times.
        .confirmationDialog("Report \(child.name) sick today?", isPresented: $confirmSick, titleVisibility: .visible) {
            Button("Report sick") { Task { await store.toggleSick(child) } }
        } message: {
            Text("\(child.institution.isEmpty ? "The staff" : child.institution) will see it in Aula. You can undo it from here.")
        }
    }

    /// A pickup can't be set on an absence day (the server answers 409).
    private var canChangePickup: Bool { child.status != "vacation" }

    private func buttonLabel(_ title: String, _ icon: String, icons: Bool) -> some View {
        Group {
            if icons { Label(title, systemImage: icon) } else { Text(title) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func buttons(icons: Bool) -> some View {
        if canChangePickup {
            Button(action: changePickup) {
                buttonLabel("Change times", "clock", icons: icons)
            }
            .buttonStyle(.glassProminent)
            .tint(.salaAccent)
        }

        if isSick {
            Button {
                Task { await store.toggleSick(child) }
            } label: {
                buttonLabel("Undo sick report", "arrow.uturn.backward", icons: icons)
            }
            .buttonStyle(.glass)
            .foregroundStyle(Color.sickText)
            .disabled(busy)
        } else {
            // Secondary, not red: Change times is the everyday action, and the dialog guards this one.
            Button {
                confirmSick = true
            } label: {
                buttonLabel("Report sick…", "cross.case", icons: icons)
            }
            .buttonStyle(.glass)
            .disabled(busy || !child.canReportSick)
        }
    }
}

struct AttentionRow: View {
    let item: AttentionItem
    let open: () -> Void

    private var isMessage: Bool { item.kind == "message" }
    private var opens: Bool { isMessage || item.kind == "holiday_request" }

    var body: some View {
        if opens {
            Button(action: open) { row }
                .buttonStyle(.plain)
                .accessibilityHint(isMessage ? "Opens the message" : "Opens the request to answer it")
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: isMessage ? "bubble.left.fill" : "calendar")
                .font(.body.weight(.semibold))
                .foregroundStyle(item.urgent ? Color.sickText : Color.salaAccent)
                .frame(width: 32, height: 32)
                .background((item.urgent ? Color.sickFill : Color.salaAccent.opacity(0.12)), in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold))
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(item.urgent ? Color.sickText : .secondary)
                }
            }
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Aula reset yesterday's sick report: one tap reports the child sick again.
struct StillSickRow: View {
    @Environment(Store.self) private var store
    let child: Child

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cross.case.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.sickText)
                .frame(width: 32, height: 32)
                .background(Color.sickFill, in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Is \(child.name) still sick?").font(.body.weight(.semibold))
                Text("Aula reset the sick report overnight.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Still sick") { Task { await store.toggleSick(child) } }
                .buttonStyle(.glassProminent)
                .tint(.sickButton)
                .disabled(store.sickInFlight.contains(child.id))
            Button("Dismiss", systemImage: "xmark") { store.dismissStillSick(child.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct UpcomingRow: View {
    let item: UpcomingItem

    private var date: Date? { Fmt.day(item.date) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(date.map { Fmt.format($0, "MMM").uppercased() } ?? "")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.sickText)
                Text(date.map { Fmt.format($0, "d") } ?? item.date)
                    .font(.title3.weight(.semibold))
            }
            .frame(width: 48, height: 48)
            .background(Color.screen, in: .rect(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold))
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([date.map { Fmt.format($0, "EEEEdMMMM") }, item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

struct PostCard: View {
    @Environment(Store.self) private var store
    let post: Post
    let downloading: String?
    let open: (Attachment) -> Void
    /// Off for search results: saving works on Today's posts (`Store.toggleSaved`), and search doesn't say what's saved.
    var canSave = true
    @State private var expanded = false

    private var translationID: String { "post-\(post.id)" }
    private var bodyText: String { store.display(post.body, in: translationID) }
    private var isLong: Bool { bodyText.count > 220 || bodyText.filter { $0 == "\n" }.count > 4 }

    private var dateText: String {
        guard let d = Fmt.timestamp(post.date) else { return "" }
        return Fmt.format(d, "EEEdMMM")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: post.author, picture: post.authorPicture, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.author).font(.subheadline.weight(.semibold))
                    Text(dateText).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if canSave {
                    Button {
                        Task { await store.toggleSaved(post) }
                    } label: {
                        Image(systemName: post.saved ? "bookmark.fill" : "bookmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 24, height: 24)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(post.saved ? "Remove bookmark" : "Save post")
                    .sensoryFeedback(.selection, trigger: post.saved)
                }
            }

            if post.important {
                Label("Important", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.sickText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.sickFill, in: .capsule)
            }

            Text(store.display(post.title, in: translationID))
                .font(.headline)

            if !post.body.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bodyText)
                        .font(.body)
                        .lineLimit(expanded || !isLong ? nil : 4)
                        .textSelection(.enabled)
                    if isLong {
                        Button(expanded ? "Show less" : "Show more") {
                            withAnimation(.snappy) { expanded.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                }
            }

            AIActions(id: translationID, translate: [post.title, post.body], summarize: post.body)

            ForEach(Array(post.attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentRow(attachment: attachment, downloading: downloading) { open(attachment) }
            }
        }
        .card()
    }
}

/// Translate / Summarize for one post or message, shown only when Settings → AI can run.
/// Never runs on its own; the summary, loading and errors show inline. A translation replaces the text
/// through `Store.display`.
struct AIActions: View {
    @Environment(Store.self) private var store
    /// "post-9" or "message-12".
    let id: String
    /// What Translate translates (a post's title and body).
    let translate: [String]
    /// What Summarize summarizes.
    let summarize: String

    private var source: String? {
        AI.language(of: translate.joined(separator: "\n")).flatMap { $0.languageCode == AI.readerLanguage.languageCode ? nil : AI.name($0) }
    }

    var body: some View {
        if store.aiOn, !summarize.isEmpty || translate.contains(where: { !$0.isEmpty }) {
            let source = source
            let canSummarize = summarize.count >= AI.summaryMinLength
            VStack(alignment: .leading, spacing: 8) {
                if let summary = store.summary(of: summarize, in: id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(source.map { "Summary · translated from \($0)" } ?? "Summary", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(summary).font(.callout).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.salaAccent.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 14) {
                    if store.aiShowing[id] != nil {
                        if store.aiShowing[id] == .translate, let source { Text("Translated from \(source)").foregroundStyle(.secondary) }
                        button(store.aiShowing[id] == .summarize ? "Hide summary" : "Show original", "arrow.uturn.backward") { store.showOriginal(id) }
                    } else {
                        if source != nil { button("Translate", "translate") { await store.runAI(.translate, id: id, texts: translate) } }
                        if canSummarize { button("Summarize", "sparkles") { await store.runAI(.summarize, id: id, texts: [summarize]) } }
                    }
                    if store.aiBusy.contains(id) { ProgressView().controlSize(.small) }
                }
                .font(.footnote.weight(.semibold))
                if let error = store.aiErrors[id] {
                    Text(error).font(.footnote).foregroundStyle(Color.sickText).lineLimit(3)
                }
            }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: icon) }
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .disabled(store.aiBusy.contains(id))
    }
}

/// One attachment in a post or message. Links open in the browser; files and images download into QuickLook.
struct AttachmentRow: View {
    @Environment(\.openURL) private var openURL
    let attachment: Attachment
    /// The id of the attachment being downloaded, if any.
    let downloading: String?
    let download: () -> Void

    private var loading: Bool { !attachment.isLink && attachment.id != nil && downloading == attachment.id }
    private var icon: String {
        switch attachment.kind {
        case "image": "photo"
        case "link": "link"
        default: "doc.text"
        }
    }

    var body: some View {
        Button {
            if attachment.isLink {
                if let url = attachment.linkURL { openURL(url) }
            } else {
                download()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.salaAccent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(attachment.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if loading {
                    ProgressView()
                } else if attachment.isLink {
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.salaAccent)
                        .accessibilityHidden(true)
                } else {
                    Text("Open")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.salaAccent)
                }
            }
            .padding(12)
            .background(Color.screen, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(attachment.isLink ? attachment.linkURL == nil : (downloading != nil || attachment.id == nil))
        .accessibilityLabel(attachment.isLink ? "Open link \(attachment.name)" : "Open attachment \(attachment.name)")
    }
}

// MARK: - Previews (sample data lives only here)

#if DEBUG
enum PreviewData {
    static let json = """
    {"date":"2026-11-12",
     "children":[{"id":123,"name":"Oskar","institution":"Børnehuset","group":"Stue","status":"present","statusLabel":"Present","arrivedAt":"07:40","leftAt":null,"pickup":{"time":"16:15","by":"Jonas (Far)"},"closesAt":"16:45","canReportSick":true,"dropoff":"07:45"},
                 {"id":124,"name":"Alma","institution":"Børnehuset","group":"Vuggestue","status":"sick","statusLabel":"Sick","arrivedAt":null,"leftAt":null,"pickup":{"time":null,"by":null},"closesAt":null,"canReportSick":false}],
     "attention":[{"id":"vacation-55","kind":"holiday_request","title":"Holiday request: 21–23 Dec","subtitle":"Answer by tomorrow, 13 Nov","urgent":true,"threadId":null},
                  {"id":"msg-1","kind":"message","title":"Spare clothes tomorrow","subtitle":"Message from the staff · 11:20","urgent":false,"threadId":"123"}],
     "upcoming":[{"date":"2026-11-20","title":"Birthday in the group","subtitle":"Fødselsdag · Stue"},{"date":"2027-01-17","title":"Oskar away until 22 Feb","subtitle":null}],
     "posts":[{"id":9,"title":"Welcome to our new pædagog","author":"Leder · Børnehuset","date":"2026-11-02T09:12:00+01:00","body":"Today we welcome a new pædagog to the house. A short presentation is attached.","important":true,"saved":false,
               "attachments":[{"id":"a1b2","name":"Præsentation.pdf","kind":"file"}]}]}
    """

    @MainActor static func store() -> Store {
        let s = Store()
        s.today = try? JSONDecoder().decode(Today.self, from: Data(json.utf8))
        s.phase = .ready
        s.showSettings = false
        return s
    }
}

#Preview("Today") {
    TodayView().environment(PreviewData.store()).tint(.salaAccent)
}
#endif
