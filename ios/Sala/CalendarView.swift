import EventKit
import EventKitUI
import SwiftUI

/// Month grid with a dot on days that have something, and the month's items below (API.md "Calendar").
/// Tapping a day shows only that day's items.
struct CalendarView: View {
    @Environment(Store.self) private var store
    @State private var month = Fmt.copenhagen.date(from: Fmt.copenhagen.dateComponents([.year, .month], from: Date()))!
    @State private var events: [String: [CalendarEvent]] = [:]
    @State private var selected: String?
    @State private var error: String?
    @State private var adding: CalendarEvent?

    private var key: String { Self.ymd(month).prefix(7).description }
    private var today: String { Self.ymd(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Calendar")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 8)
                    if let error { BannerView(text: error) { self.error = nil } }
                    grid.card()
                    list
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.screen)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load(force: true) }
            .task(id: key) { await load(force: false) }
            .sheet(item: $adding) { AddToCalendar(event: $0) { adding = nil }.ignoresSafeArea() }
        }
    }

    // MARK: grid

    private var grid: some View {
        let cal = Fmt.copenhagen
        let days = cal.range(of: .day, in: .month, for: month)!.count
        // Monday first: blanks before the 1st.
        let lead = (cal.component(.weekday, from: month) + 5) % 7
        let items = events[key] ?? []
        return VStack(spacing: 12) {
            HStack {
                Button("Previous month", systemImage: "chevron.left") { step(-1) }
                Spacer()
                Text(Fmt.format(month, "MMMMyyyy")).font(.headline)
                Spacer()
                Button("Next month", systemImage: "chevron.right") { step(1) }
            }
            .labelStyle(.iconOnly)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                // One ForEach with distinct ids: separate ForEachs over 0..<n collide inside a LazyVGrid.
                ForEach(0..<(7 + lead + days), id: \.self) { i in
                    if i < 7 {
                        Text(["M", "T", "W", "T", "F", "S", "S"][i])
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    } else if i < 7 + lead {
                        Color.clear.frame(height: 40)
                    } else {
                        let d = i - 6 - lead
                        let ymd = "\(key)-\(String(format: "%02d", d))"
                        dayCell(d, ymd, busy: items.contains { $0.covers(ymd) })
                    }
                }
            }
        }
    }

    private func dayCell(_ d: Int, _ ymd: String, busy: Bool) -> some View {
        let isSelected = selected == ymd
        return Button {
            selected = isSelected ? nil : ymd
        } label: {
            VStack(spacing: 3) {
                Text("\(d)")
                    .font(.body.weight(ymd == today ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : ymd == today ? Color.salaAccent : .primary)
                    .frame(width: 32, height: 32)
                    .background(isSelected ? Color.salaAccent : .clear, in: .circle)
                Circle().fill(busy ? Color.salaAccent : .clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Fmt.day(ymd).map { Fmt.format($0, "EEEEdMMMM") } ?? ymd)
        .accessibilityValue(busy ? "Has events" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func step(_ by: Int) {
        selected = nil
        month = Fmt.copenhagen.date(byAdding: .month, value: by, to: month)!
    }

    // MARK: list

    @ViewBuilder private var list: some View {
        if let items = events[key] {
            let shown = selected.map { day in items.filter { $0.covers(day) } } ?? items
            // Grouped by the day each item starts, or the 1st for one that started last month.
            let groups = Dictionary(grouping: shown) { selected ?? max($0.startDate, "\(key)-01") }
            if shown.isEmpty {
                ContentUnavailableView(selected == nil ? "Nothing this month" : "Nothing this day", systemImage: "calendar")
            }
            ForEach(groups.keys.sorted(), id: \.self) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Fmt.day(day).map { Fmt.format($0, "EEEEdMMMM") } ?? day)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(groups[day]!) { row($0) }
                }
            }
        } else if error == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
        }
    }

    private func row(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(e.kind.color).frame(width: 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.body.weight(.medium))
                if let s = e.subtitle { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                Text(Self.when(e)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu("More", systemImage: "ellipsis") {
                Button("Add to Calendar", systemImage: "calendar.badge.plus") { adding = e }
            }
            .labelStyle(.iconOnly)
        }
        .card()
        .contextMenu {
            Button("Add to Calendar", systemImage: "calendar.badge.plus") { adding = e }
        }
    }

    static func when(_ e: CalendarEvent) -> String {
        let range = e.startDate == e.endDate ? nil
            : [e.startDate, e.endDate].compactMap(Fmt.day).map { Fmt.format($0, "dMMM") }.joined(separator: " – ")
        if let s = e.startTime {
            let t = e.endTime.map { "\(s)–\($0)" } ?? s
            return range.map { "\($0), \(t)" } ?? t
        }
        return range ?? "All day"
    }

    static func ymd(_ date: Date) -> String {
        let c = Fmt.copenhagen.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func load(force: Bool) async {
        let k = key
        if events[k] != nil && !force { return }
        do {
            events[k] = try await store.client.calendar(month: k)
            error = nil
        } catch {
            self.error = store.handle(error)
        }
    }
}

extension CalendarEvent.Kind {
    var color: Color {
        switch self {
        case .absence: .orange
        case .meeting: .blue
        case .birthday: .pink
        case .event: .salaAccent
        }
    }
}

/// iOS's own "new event" sheet, filled in. Runs out of process, so it needs no calendar access.
private struct AddToCalendar: UIViewControllerRepresentable {
    let event: CalendarEvent
    let done: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let vc = EKEventEditViewController()
        vc.eventStore = store
        let ev = EKEvent(eventStore: store)
        event.fill(ev)
        vc.event = ev
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done()
        }
    }
}
