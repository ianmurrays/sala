import SwiftUI

struct TodayView: View {
    @Environment(Store.self) private var store
    @State private var pickupChild: Child?
    @State private var attachments = AttachmentOpener()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if let banner = store.banner { BannerView(text: banner) { store.banner = nil } }
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
            Button {
                store.showSettings = true
            } label: {
                Image(systemName: "person.fill")
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
                    Button("Settings") { store.showSettings = true }
                }
                .padding(.top, 40)
            case .unauthorized:
                ContentUnavailableView {
                    Label("Token rejected", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text("The server didn't accept the token. Check it in Settings.")
                } actions: {
                    Button("Open Settings") { store.showSettings = true }
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

        if !today.attention.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Needs attention")
                VStack(spacing: 0) {
                    ForEach(Array(today.attention.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 56) }
                        AttentionRow(item: item) {
                            store.openThread(item.threadId)
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
                VStack(spacing: 12) {
                    ForEach(today.posts) { post in
                        PostCard(post: post, downloading: attachments.downloading, open: open)
                    }
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
    var size: CGFloat = 44
    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.salaAccent)
            .frame(width: size, height: size)
            .background(Color.salaAccent.opacity(0.14), in: .circle)
            .accessibilityHidden(true)
    }
}

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

    private var colors: (Color, Color) {
        switch child.status {
        case "present": (.presentText, .presentFill)
        case "sick": (.sickText, .sickFill)
        default: (.secondary, Color(uiColor: .tertiarySystemFill))
        }
    }

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

    private var pickupHeader: String {
        child.closesAt.map { "Pickup today · closes \($0)" } ?? "Pickup today"
    }

    private var pickupText: String {
        let parts = [child.pickup?.time, child.pickup?.by].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "No pickup set" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: child.name)
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
                Text(pickupText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(child.pickup?.time == nil && child.pickup?.by == nil ? .secondary : .primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.screen, in: .rect(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 10) { buttons }
            }
        }
        .card()
        .sensoryFeedback(.success, trigger: child.status) { old, new in old != new && (old == "sick" || new == "sick") }
    }

    @ViewBuilder private var buttons: some View {
        Button(action: changePickup) {
            Label("Change pickup", systemImage: "clock")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.salaAccent)

        if isSick {
            Button {
                Task { await store.toggleSick(child) }
            } label: {
                Label("Undo sick report", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .foregroundStyle(Color.sickText)
            .disabled(busy)
        } else {
            Button {
                Task { await store.toggleSick(child) }
            } label: {
                Label("Report sick", systemImage: "cross.case")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.sickButton)
            .disabled(busy || !child.canReportSick)
        }
    }
}

struct AttentionRow: View {
    let item: AttentionItem
    let openMessage: () -> Void

    private var isMessage: Bool { item.kind == "message" }

    var body: some View {
        if isMessage {
            Button(action: openMessage) { row }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the message")
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
            if isMessage {
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
    @State private var expanded = false

    private var isLong: Bool { post.body.count > 220 || post.body.filter { $0 == "\n" }.count > 4 }

    private var dateText: String {
        guard let d = Fmt.timestamp(post.date) else { return "" }
        return Fmt.format(d, "EEEdMMM")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: post.author, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.author).font(.subheadline.weight(.semibold))
                    Text(dateText).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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

            if post.important {
                Label("Important", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.sickText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.sickFill, in: .capsule)
            }

            Text(post.title)
                .font(.headline)

            if !post.body.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.body)
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

            ForEach(post.attachments) { attachment in
                AttachmentRow(attachment: attachment, loading: downloading == attachment.id, disabled: downloading != nil) {
                    open(attachment)
                }
            }
        }
        .card()
    }
}

struct AttachmentRow: View {
    let attachment: Attachment
    let loading: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: attachment.kind == "image" ? "photo" : "doc.text")
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
        .disabled(disabled)
        .accessibilityLabel("Open attachment \(attachment.name)")
    }
}

// MARK: - Previews (sample data lives only here)

#if DEBUG
enum PreviewData {
    static let json = """
    {"date":"2026-11-12",
     "children":[{"id":123,"name":"Oskar","institution":"Børnehuset","group":"Stue","status":"present","statusLabel":"Present","arrivedAt":"07:40","leftAt":null,"pickup":{"time":"16:15","by":"Jonas (Far)"},"closesAt":"16:45","canReportSick":true},
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
