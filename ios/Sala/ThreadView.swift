import SwiftUI

struct ThreadView: View {
    @Environment(Store.self) private var store
    let threadID: String

    @State private var thread: MessageThread?
    @State private var loadError: String?
    @State private var attachments = AttachmentOpener()
    /// Non-fatal error (failed attachment, failed refresh after sending).
    @State private var banner: String?

    // Composer
    @State private var text = ""
    /// Deliberately starts empty: the user must pick who gets the reply every time.
    @State private var audience: ReplyAudience?
    @State private var sending = false
    @State private var sendError: String?
    @State private var sentPrivately: SentPrivately?
    @State private var moving: ThreadSummary?
    @FocusState private var fieldFocused: Bool

    private struct SentPrivately: Equatable {
        var name: String
        var threadID: String?
    }

    private var summary: ThreadSummary? { store.threads?.first { $0.id == threadID } }
    private var title: String { thread?.subject ?? summary?.subject ?? "" }
    private var participants: Int? { summary.map(\.participants).flatMap { $0 > 0 ? $0 : nil } }
    /// The latest message not from me: the target of a "Sender only" reply.
    private var latestFromOthers: Message? { thread?.messages.last { !$0.fromMe } }

    var body: some View {
        content
            .background(Color.screen)
            .navigationTitle(title)
            .navigationSubtitle(participants.map { $0 > 1 ? "You + \($0 - 1) \($0 == 2 ? "person" : "people")" : "" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview(attachments)
            .toolbar {
                // Only for a thread in the shown list (the server needs it listed, see API.md).
                if let summary {
                    ToolbarItem(placement: .topBarTrailing) { actionsMenu(summary) }
                }
            }
            .sheet(item: $moving) { MoveToFolderSheet(thread: $0) }
            .task { await load() }
    }

    private func actionsMenu(_ t: ThreadSummary) -> some View {
        Menu {
            Button(t.starred ? "Unstar" : "Star", systemImage: t.starred ? "star.slash" : "star") {
                Task { await store.setStarred(t.id, !t.starred) }
            }
            Button(t.muted ? "Unmute" : "Mute", systemImage: t.muted ? "bell" : "bell.slash") {
                Task { await store.setMuted(t.id, !t.muted) }
            }
            Button("Move…", systemImage: "folder") { moving = t }
        } label: {
            Label("Actions", systemImage: "ellipsis")
        }
    }

    @ViewBuilder private var content: some View {
        if let thread {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let banner { BannerView(text: banner) { self.banner = nil } }
                        ForEach(thread.messages) { message in
                            MessageBubble(message: message, downloading: attachments.downloading) { open($0) }
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await load() }
                .onChange(of: thread.messages.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .safeAreaInset(edge: .bottom) {
                    if thread.canReply { composer(thread) }
                }
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't load the conversation", systemImage: "exclamationmark.bubble")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.glassProminent)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Composer

    private func composer(_ thread: MessageThread) -> some View {
        let target = latestFromOthers
        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && audience != nil && !sending

        return VStack(alignment: .leading, spacing: 10) {
            if let sent = sentPrivately {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.presentText)
                        .accessibilityHidden(true)
                    Text("Sent privately to \(sent.name)")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let id = sent.threadID {
                        NavigationLink(value: id) {
                            Text("Open").font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Open the private thread")
                    }
                    Button("Dismiss", systemImage: "xmark") { sentPrivately = nil }
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 8) {
                Text("Reply to")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                AudiencePicker(selection: $audience, senderEnabled: target != nil)
            }

            Text(explanation(target: target))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 4)

            if let sendError {
                Label(sendError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.sickText)
                    .padding(.horizontal, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
                    .accessibilityLabel("Reply")
                Button {
                    Task { await send() }
                } label: {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.body.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend || sending ? Color.salaAccent : Color.secondary.opacity(0.4), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: sentPrivately)
        .animation(.snappy, value: sendError)
    }

    private func explanation(target: Message?) -> String {
        switch audience {
        case .sender:
            "Sender only: a new private thread to \(target?.sender ?? "the sender")"
        case .everyone:
            participants.map { "Everyone: all \($0) people in this thread" } ?? "Everyone: everyone in this thread"
        case nil:
            target == nil ? "Every message here is yours, so only Everyone is available." : "Choose who gets your reply."
        }
    }

    // MARK: Actions

    private func load() async {
        loadError = nil
        let c = store.client
        let id = threadID
        let result = await Task { try await c.thread(id) }.result
        switch result {
        case .success(let t):
            thread = t
            store.markThreadRead(threadID)
        case .failure(let error):
            let msg: String? = if case APIError.notFound = error {
                "This conversation doesn't exist any more."
            } else {
                store.handle(error)
            }
            guard let msg else { return }
            if thread == nil { loadError = msg } else { banner = msg }
        }
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let audience, !body.isEmpty, !sending else { return }
        let target = latestFromOthers
        if audience == .sender && target == nil { return }

        sending = true
        sendError = nil
        sentPrivately = nil

        let request = ReplyRequest(text: body, audience: audience, messageId: audience == .sender ? target?.id : nil)
        let c = store.client
        let id = threadID
        let result = await Task { try await c.reply(thread: id, request) }.result
        sending = false
        // Every send needs a fresh, deliberate choice.
        self.audience = nil
        switch result {
        case .success(let response):
            text = ""
            fieldFocused = false
            switch audience {
            case .everyone:
                let myName = thread?.messages.last(where: \.fromMe)?.sender ?? "You"
                let iso = ISO8601DateFormatter().string(from: Date())
                thread?.messages.append(Message(id: "local-\(UUID().uuidString)", sender: myName, fromMe: true, date: iso, text: body))
                await load()
            case .sender:
                sentPrivately = SentPrivately(name: target?.sender ?? "the sender", threadID: response.threadId)
            }
            Task { await store.loadThreads() }
        case .failure(let error):
            sendError = store.handle(error).map { "Not sent. \($0)" }
        }
    }

    private func open(_ attachment: Attachment) {
        attachments.open(attachment, store: store) { banner = $0 }
    }
}

// MARK: - Pieces

/// Two-segment control with no default selection, so the audience is always picked on purpose.
struct AudiencePicker: View {
    @Binding var selection: ReplyAudience?
    let senderEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Sender only", .sender, enabled: senderEnabled)
            segment("Everyone", .everyone, enabled: true)
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func segment(_ title: String, _ value: ReplyAudience, enabled: Bool) -> some View {
        let on = selection == value
        return Button {
            selection = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    if on {
                        Capsule().fill(Color.card).shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct MessageBubble: View {
    let message: Message
    let downloading: String?
    let open: (Attachment) -> Void

    private var timeText: String { Fmt.timestamp(message.date).map { Fmt.messageTime($0) } ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.fromMe {
                Spacer(minLength: 44)
            } else {
                InitialsAvatar(name: message.sender)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.fromMe ? "You" : message.sender)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(timeText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentRow(attachment: attachment, downloading: downloading) { open(attachment) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(message.fromMe ? Color.salaAccent.opacity(0.14) : Color.card,
                        in: .rect(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }
}
