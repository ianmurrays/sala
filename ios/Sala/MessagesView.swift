import SwiftUI

struct MessagesView: View {
    @Environment(Store.self) private var store
    @State private var path: [String] = []
    @State private var moving: ThreadSummary?
    @State private var managingFolders = false

    var body: some View {
        NavigationStack(path: $path) {
            // A List (not a ScrollView) for the swipe actions; inset grouped keeps the card look.
            List {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                content
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(Color.screen)
            .refreshable {
                await store.loadThreads(reset: true)
                await store.loadFolders()
            }
            // On the root (not the stack) so it re-runs when popping back from a thread.
            .task { await store.loadThreads() }
            .task { await store.loadFolders() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                ThreadView(threadID: id)
            }
            .sheet(item: $moving) { MoveToFolderSheet(thread: $0) }
            .sheet(isPresented: $managingFolders) { ManageFoldersSheet() }
        }
        .onChange(of: store.pendingThreadID, initial: true) { openPendingThread() }
        .onChange(of: store.showSettings) { openPendingThread() }
        .onChange(of: store.selectedTab) { openPendingThread() }
    }

    /// Pushes a thread requested from Today or a deep link, but only once Messages is actually visible,
    /// so a link that arrives behind Settings isn't consumed unseen.
    private func openPendingThread() {
        guard let id = store.pendingThreadID, store.selectedTab == .messages, !store.showSettings else { return }
        store.pendingThreadID = nil
        if path != [id] { path = [id] }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.folderName ?? "Messages")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            folderMenu
        }
    }

    private var folderMenu: some View {
        Menu {
            Picker("Folder", selection: Binding(
                get: { store.folder },
                set: { id in Task { await store.selectFolder(id) } }
            )) {
                Label("Inbox", systemImage: "tray").tag(Int?.none)
                ForEach(store.folders) { f in
                    Label(f.name, systemImage: "folder").tag(Int?.some(f.id))
                }
            }
            Divider()
            Button("Manage Folders", systemImage: "folder.badge.gearshape") { managingFolders = true }
        } label: {
            Image(systemName: store.folder == nil ? "tray" : "folder")
                .font(.title3)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Folders")
    }

    @ViewBuilder private var content: some View {
        if let error = store.threadsError, store.threads != nil {
            BannerView(text: error) { store.threadsError = nil }
                .plainRow()
        }
        if let threads = store.threads {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label(store.folder == nil ? "No messages" : "Empty folder", systemImage: "tray")
                } description: {
                    Text(store.folder == nil
                         ? "Messages from the institution show up here."
                         : "Swipe left on a message and tap Move to put it here.")
                }
                .padding(.top, 40)
                .plainRow()
            } else {
                Section {
                    // Lazy, so the last row appearing means it was scrolled to (keyed on the epoch, see TodayView).
                    ForEach(Array(threads.enumerated()), id: \.element.id) { i, thread in
                        Button { path.append(thread.id) } label: {
                            ThreadRow(thread: thread)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 74 }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await store.setStarred(thread.id, !thread.starred) }
                            } label: {
                                Label(thread.starred ? "Unstar" : "Star", systemImage: thread.starred ? "star.slash" : "star.fill")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { moving = thread } label: {
                                Label("Move", systemImage: "folder")
                            }
                            .tint(.indigo)
                            Button {
                                Task { await store.setMuted(thread.id, !thread.muted) }
                            } label: {
                                Label(thread.muted ? "Unmute" : "Mute", systemImage: thread.muted ? "bell" : "bell.slash")
                            }
                            .tint(.gray)
                        }
                        .task(id: store.moreThreads.epoch) {
                            if i == threads.count - 1 { await store.loadMoreThreads() }
                        }
                    }
                }
                .listRowBackground(Color.card)
                LoadMoreRow(paging: store.moreThreads) { await store.retryMoreThreads() }
                    .plainRow()
            }
        } else if let error = store.threadsError {
            ContentUnavailableView {
                Label("Can't load messages", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.loadThreads() } }
                    .buttonStyle(.glassProminent)
            }
            .padding(.top, 40)
            .plainRow()
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .plainRow()
        }
    }
}

private extension View {
    /// A list row without the card background, separators or insets (banners, empty states).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary

    private var dateText: String { Fmt.timestamp(thread.date).map { Fmt.relative($0) } ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GroupAvatar(name: thread.from, picture: thread.picture, participants: thread.participants)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 6) {
                        if thread.unread {
                            Circle().fill(Color.salaAccent).frame(width: 9, height: 9)
                        }
                        Text(thread.subject)
                            .font(.body.weight(thread.unread ? .bold : .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        if thread.starred {
                            Image(systemName: "star.fill").foregroundStyle(Color.sickText)
                        }
                        if thread.muted {
                            Image(systemName: "bell.slash")
                        }
                        Text(dateText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                }
                Text(thread.from)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !thread.preview.isEmpty {
                    Text(thread.preview)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if thread.unread { parts.append("Unread") }
        parts.append(thread.subject)
        parts.append("from \(thread.from)")
        if thread.participants > 1 { parts.append("\(thread.participants) people") }
        parts.append(dateText)
        if thread.starred { parts.append("Starred") }
        if thread.muted { parts.append("Muted") }
        parts.append(thread.preview)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Avatars

/// Initials on a colour picked from the name, so the same sender keeps the same colour.
struct InitialsAvatar: View {
    let name: String
    var picture: String? = nil
    var size: CGFloat = 34

    private static let palette: [Color] = [
        Color(uiColor: UIColor(hex: 0x3C6E9E)), Color(uiColor: UIColor(hex: 0x8E6C4E)),
        Color(uiColor: UIColor(hex: 0x5B8C6E)), Color(uiColor: UIColor(hex: 0x7A5BA6)),
        Color(uiColor: UIColor(hex: 0xA6585B)), Color(uiColor: UIColor(hex: 0x4E8A8E)),
    ]

    static func initials(_ name: String) -> String {
        // "Leder · Børnehuset" → "LE", "Mette Lund" → "ML", "[Pædagog] · Stue" → "PÆ".
        let main = name.components(separatedBy: " · ").first ?? name
        let words = main.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters: String
        if words.count >= 2 {
            letters = String(words[0].prefix(1)) + String(words[1].prefix(1))
        } else {
            letters = String(words.first?.prefix(2) ?? "?")
        }
        return letters.uppercased()
    }

    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        ProfilePicture(id: picture, size: size) {
            Text(Self.initials(name))
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color, in: .circle)
        }
        .accessibilityHidden(true)
    }
}

/// The sender's initials with a "+N" badge for the other people in the thread.
struct GroupAvatar: View {
    let name: String
    var picture: String? = nil
    let participants: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            InitialsAvatar(name: name, picture: picture, size: participants > 2 ? 34 : 46)
                .overlay { Circle().stroke(Color.card, lineWidth: participants > 2 ? 2 : 0) }
            if participants > 2 {
                Text("+\(participants - 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Color(uiColor: .systemGray5), in: .capsule)
                    .overlay { Capsule().stroke(Color.card, lineWidth: 2) }
                    .frame(width: 46, height: 46, alignment: .bottomTrailing)
            }
        }
        .frame(width: 46, height: 46, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Messages") {
    MessagesView().environment(PreviewData.store()).tint(.salaAccent)
}
#endif
