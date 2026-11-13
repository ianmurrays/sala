import SwiftUI

/// Answer a holiday request, or change the answer until the deadline: Comes / Off per day and child.
struct HolidaySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    /// Shown until the request has loaded its own title.
    var fallbackTitle = ""

    struct DayState: Equatable {
        var coming: Bool?
        var entry: String?
        var exit: String?
    }

    @State private var request: HolidayRequest?
    @State private var loadError: String?
    /// child id → date → answer
    @State private var answers: [Int: [String: DayState]] = [:]
    /// child id → comment to staff (Aula keeps one per child)
    @State private var comments: [Int: String] = [:]
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let request {
                    form(request)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Can't load the request", systemImage: "exclamationmark.triangle")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Holiday request").font(.headline)
                        if let request {
                            Text(request.children.map(\.name).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "checkmark", role: .confirm) { Task { await send() } }
                            .disabled(!canSend)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    // MARK: Form

    private func form(_ r: HolidayRequest) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.title.isEmpty ? fallbackTitle : r.title).font(.headline)
                        Spacer(minLength: 0)
                        if let due = dueText(r) {
                            Text(due)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.sickButton, in: .capsule)
                        }
                    }
                    if let range = rangeText(r) {
                        Text(range).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let note = r.note, !note.isEmpty {
                        Text(note).font(.body).textSelection(.enabled)
                    }
                    if !r.editable {
                        Label("The deadline has passed.", systemImage: "lock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(r.children) { child in
                Section {
                    ForEach(child.days, id: \.date) { day in
                        dayRow(child: child, day: day, timesRequired: r.timesRequired)
                    }
                    if child.days.contains(where: \.editable) {
                        TextField(r.children.count > 1 ? "Comment about \(child.name) (optional)" : "Comment to staff (optional)",
                                  text: Binding(get: { comments[child.id] ?? "" }, set: { comments[child.id] = $0 }),
                                  axis: .vertical)
                            .lineLimit(2...6)
                    }
                } header: {
                    HStack {
                        Text(r.children.count > 1 || child.answered ? "\(child.name)\(child.answered ? " · answered" : "")" : "Days")
                        Spacer()
                        if child.days.contains(where: \.editable) {
                            Menu("Set all") {
                                Button("Comes all days", systemImage: "checkmark.circle") { setAll(child, coming: true) }
                                Button("Off all days", systemImage: "sun.max") { setAll(child, coming: false) }
                            }
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
            }

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.sickText)
                }
            }
        }
    }

    private func binding(_ child: Int, _ date: String) -> Binding<DayState> {
        Binding(
            get: { answers[child]?[date] ?? DayState() },
            set: { answers[child, default: [:]][date] = $0 }
        )
    }

    @ViewBuilder private func dayRow(child: HolidayChild, day: HolidayDay, timesRequired: Bool) -> some View {
        let state = binding(child.id, day.date)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.day(day.date).map { Fmt.format($0, "EEEdMMM") } ?? day.date)
                        .font(.body.weight(.semibold))
                    Text(detail(day, state.wrappedValue, timesRequired: timesRequired))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker(Fmt.day(day.date).map { Fmt.format($0, "EEEEdMMMM") } ?? day.date, selection: state.coming) {
                    Text("Comes").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!day.editable)
            }
            if timesRequired, day.editable, state.wrappedValue.coming == true {
                HStack {
                    TimeField(label: "Drop-off", value: state.entry)
                    Spacer()
                    TimeField(label: "Pickup", value: state.exit)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ day: HolidayDay, _ state: DayState, timesRequired: Bool) -> String {
        if !day.editable { return state.coming == nil ? "Can't be answered" : (state.coming == true ? "Comes" : "Off") }
        switch state.coming {
        case true?:
            if let a = state.entry, let b = state.exit {
                return timesRequired && a >= b ? "Drop-off must be before pickup" : "Comes · \(a)–\(b)"
            }
            return timesRequired ? "Comes · add drop-off and pickup times" : "Comes"
        case false?: return "Staying home"
        case nil: return "Not answered"
        }
    }

    private func setAll(_ child: HolidayChild, coming: Bool) {
        for day in child.days where day.editable {
            answers[child.id, default: [:]][day.date, default: DayState()].coming = coming
        }
    }

    private func dueText(_ r: HolidayRequest) -> String? {
        guard r.editable, !r.answered, let d = r.deadline.flatMap(Fmt.day) else { return nil }
        let today = store.today.flatMap { Fmt.day($0.date) } ?? Fmt.copenhagen.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: today, to: d).day ?? 99
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return nil
        }
    }

    private func rangeText(_ r: HolidayRequest) -> String? {
        var parts: [String] = []
        if let s = r.startDate.flatMap(Fmt.day) {
            let start = Fmt.format(s, "EEEdMMM")
            if let e = r.endDate.flatMap(Fmt.day), e != s { parts.append("\(start) – \(Fmt.format(e, "EEEdMMM"))") } else { parts.append(start) }
        }
        if let d = r.deadline.flatMap(Fmt.day) { parts.append("\(r.answered && r.editable ? "change" : "answer") by \(Fmt.format(d, "dMMM"))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Every editable day answered (with both times when required), for every child that has one.
    private var canSend: Bool {
        guard let r = request, r.editable else { return false }
        let open = r.children.filter { $0.days.contains(where: \.editable) }
        guard !open.isEmpty else { return false }
        return open.allSatisfy { child in
            child.days.filter(\.editable).allSatisfy { day in
                guard let s = answers[child.id]?[day.date], let coming = s.coming else { return false }
                guard coming, r.timesRequired else { return true }
                guard let a = s.entry, let b = s.exit else { return false }
                return a < b
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let r = try await store.client.holidayRequest(id)
            request = r
            answers = Dictionary(uniqueKeysWithValues: r.children.map { child in
                (child.id, Dictionary(uniqueKeysWithValues: child.days.map {
                    ($0.date, DayState(coming: $0.coming, entry: $0.entryTime, exit: $0.exitTime))
                }))
            })
            comments = Dictionary(uniqueKeysWithValues: r.children.map { ($0.id, $0.comment) })
        } catch is CancellationError {
        } catch {
            store.handle(error)
            loadError = error.localizedDescription
        }
    }

    private func send() async {
        guard let r = request else { return }
        let children = r.children.filter { $0.days.contains(where: \.editable) }.map { child in
            HolidayAnswer.Child(id: child.id, comment: comments[child.id] ?? "", days: child.days.filter(\.editable).compactMap { day in
                guard let s = answers[child.id]?[day.date], let coming = s.coming else { return nil }
                let times = coming && r.timesRequired
                return HolidayAnswer.Day(date: day.date, coming: coming,
                                         entryTime: times ? s.entry : nil, exitTime: times ? s.exit : nil)
            })
        }
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            _ = try await store.client.answerHolidayRequest(r.id, HolidayAnswer(children: children))
            await store.load()
            dismiss()
        } catch is CancellationError {
        } catch {
            saveError = store.handle(error) ?? error.localizedDescription
        }
    }
}

/// "HH:mm" as an hour-and-minute picker; empty until set.
private struct TimeField: View {
    let label: String
    @Binding var value: String?

    private var date: Binding<Date> {
        Binding(
            get: {
                let m = Fmt.minutes(value) ?? 8 * 60
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                value = Fmt.hhmm((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
        )
    }

    var body: some View {
        if value == nil {
            Button("\(label) time") { value = Fmt.hhmm(label == "Pickup" ? 15 * 60 : 8 * 60) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        } else {
            DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
                .font(.subheadline)
                .fixedSize()
        }
    }
}

/// Register a holiday or days off for one or more children (`POST /absences`), or change or cancel
/// a registered one (`editing`).
struct AbsenceSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Absence?

    @State private var selected: Set<Int> = []
    @State private var start: Date
    @State private var end: Date
    @State private var comment: String
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmCancel = false

    init(editing: Absence? = nil) {
        self.editing = editing
        let today = Fmt.copenhagen.startOfDay(for: Date())
        _start = State(initialValue: editing.flatMap { Self.day($0.startDate) } ?? today)
        _end = State(initialValue: editing.flatMap { Self.day($0.endDate) } ?? today)
        _comment = State(initialValue: editing?.comment ?? "")
    }

    /// "yyyy-MM-dd" → that day in Copenhagen.
    private static func day(_ ymd: String) -> Date? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? Fmt.copenhagen.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) : nil
    }

    private var today: Date { Fmt.copenhagen.startOfDay(for: Date()) }
    /// Aula won't move the start of an absence that has started.
    private var startLocked: Bool { editing.flatMap { Self.day($0.startDate) }.map { $0 <= today } ?? false }

    private var children: [Child] { store.today?.children ?? [] }
    private static let maxComment = 250

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    if let editing {
                        Text(editing.children.map(\.name).joined(separator: ", "))
                    } else if children.isEmpty {
                        Text("No children on this account.").foregroundStyle(.secondary)
                    }
                    ForEach(editing == nil ? children : []) { child in
                        Button {
                            if selected.contains(child.id) { selected.remove(child.id) } else { selected.insert(child.id) }
                        } label: {
                            HStack {
                                Text(child.name).foregroundStyle(Color.primary)
                                Spacer()
                                if selected.contains(child.id) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.salaAccent)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .tint(Color.primary)
                        .accessibilityAddTraits(selected.contains(child.id) ? .isSelected : [])
                    }
                }

                Section("When") {
                    DatePicker("From", selection: $start, in: (startLocked ? start : today)..., displayedComponents: .date)
                        .disabled(startLocked)
                    DatePicker("To", selection: $end, in: max(start, today)...(Fmt.copenhagen.date(byAdding: .year, value: 1, to: start) ?? start), displayedComponents: .date)
                }

                Section {
                    TextField("Optional", text: $comment, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Comment to staff")
                } footer: {
                    if comment.count > Self.maxComment {
                        Text("\(comment.count)/\(Self.maxComment) characters").foregroundStyle(Color.sickText)
                    }
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.sickText)
                    }
                }

                if editing != nil {
                    Section {
                        Button("Cancel this absence", role: .destructive) { confirmCancel = true }
                            .disabled(saving)
                    }
                }
            }
            .confirmationDialog("Cancel this absence?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel absence", role: .destructive) { Task { await cancel() } }
            } message: {
                Text("The institution will expect \(editing?.children.map(\.name).joined(separator: " and ") ?? "them") on these days.")
            }
            // Aula's days are Danish days: pick and format them in Copenhagen time.
            .environment(\.timeZone, Fmt.copenhagen.timeZone)
            .environment(\.calendar, Fmt.copenhagen)
            .navigationTitle(editing == nil ? "Holiday or days off" : "Change holiday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "checkmark", role: .confirm) { Task { await send() } }
                            .disabled((editing == nil && selected.isEmpty) || comment.count > Self.maxComment)
                    }
                }
            }
            .onChange(of: start) { _, new in if end < new { end = new } }
        }
        .presentationDetents([.large])
        .onAppear { if editing == nil, children.count == 1, let only = children.first { selected = [only.id] } }
    }

    private func send() async {
        await write {
            if let editing {
                try await store.client.changeAbsence(editing.id, AbsenceChange(startDate: Fmt.ymd(start), endDate: Fmt.ymd(end), comment: comment))
            } else {
                try await store.client.addAbsence(AbsenceRequest(childIds: children.map(\.id).filter(selected.contains),
                                                                 startDate: Fmt.ymd(start), endDate: Fmt.ymd(end), comment: comment))
            }
        }
    }

    private func cancel() async {
        guard let editing else { return }
        await write { try await store.client.cancelAbsence(editing.id) }
    }

    private func write(_ op: () async throws -> Void) async {
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            try await op()
            await store.load()
            dismiss()
        } catch is CancellationError {
        } catch {
            saveError = store.handle(error) ?? error.localizedDescription
        }
    }
}

/// Registered holidays and days off (tap one to change or cancel it), and the holiday requests that
/// can still be answered (tap one to change the answer).
struct HolidaysView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var absences: [Absence]?
    @State private var requests: [HolidayRequestSummary] = []
    @State private var loadError: String?
    @State private var editing: Absence?
    @State private var request: HolidayRequestSummary?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if absences != nil || loadError != nil {
                    list(absences ?? [])
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Holidays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Register holiday", systemImage: "plus") { adding = true }
                }
            }
            .sheet(item: $editing, onDismiss: reload) { AbsenceSheet(editing: $0) }
            .sheet(item: $request, onDismiss: reload) { HolidaySheet(id: $0.id, fallbackTitle: $0.title) }
            .sheet(isPresented: $adding, onDismiss: reload) { AbsenceSheet() }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    private func list(_ absences: [Absence]) -> some View {
        List {
            Section {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.sickText)
                    Button("Try again") { reload() }
                } else if absences.isEmpty {
                    Text("Nothing registered.").foregroundStyle(.secondary)
                }
                ForEach(absences) { a in
                    Button { editing = a } label: {
                        row(Self.range(a.startDate, a.endDate),
                            [a.children.map(\.name).joined(separator: ", "), a.comment].filter { !$0.isEmpty }.joined(separator: " · "),
                            locked: !a.editable)
                    }
                    .disabled(!a.editable)
                }
            } header: {
                Text("Registered")
            } footer: {
                if absences.contains(where: { !$0.editable }) {
                    Text("Locked ones can't be changed in Aula. Ask the institution.")
                }
            }
            if !requests.isEmpty {
                Section("Holiday requests") {
                    ForEach(requests) { r in
                        Button { request = r } label: {
                            row(r.title.isEmpty ? "Holiday request" : r.title,
                                [r.startDate.map { Self.range($0, r.endDate ?? $0) }, r.answered ? "Answered" : "Not answered",
                                 r.deadline.flatMap(Fmt.day).map { "\(r.answered ? "change" : "answer") by \(Fmt.format($0, "dMMM"))" }].compactMap { $0 }.joined(separator: " · "),
                                locked: false)
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ detail: String, locked: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Color.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: locked ? "lock" : "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(!locked)
                .accessibilityLabel("Can't be changed")
        }
        .contentShape(.rect)
    }

    static func range(_ start: String, _ end: String) -> String {
        guard let s = Fmt.day(start) else { return start }
        guard end != start, let e = Fmt.day(end) else { return Fmt.format(s, "EEEdMMM") }
        return "\(Fmt.format(s, "EEEdMMM")) – \(Fmt.format(e, "EEEdMMM"))"
    }

    private func reload() { Task { await load() } }

    private func load() async {
        loadError = nil
        // Separately: a failing absence list still shows the requests.
        async let r = try? store.client.holidayRequests()
        do {
            absences = try await store.client.absences()
        } catch is CancellationError {
        } catch {
            store.handle(error)
            loadError = error.localizedDescription
        }
        requests = await r ?? requests
    }
}
