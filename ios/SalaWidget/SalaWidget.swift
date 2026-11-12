import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SalaEntry: TimelineEntry {
    var date: Date
    var children: [Child] = []
    /// Shown instead of the children: "Log in needed", "Open Sala".
    var message: String?
    /// Set when showing the app's snapshot because the widget's own fetch failed.
    var asOf: Date?

    static let sample = SalaEntry(date: .now, children: [
        Child(id: 1, name: "Oskar", institution: "Børnehuset", group: "Stue", status: "present", statusLabel: "Present",
              arrivedAt: "07:40", leftAt: nil, pickup: Pickup(time: "16:00", by: "Jonas (Far)"), closesAt: "16:45", canReportSick: true),
        Child(id: 2, name: "Alma", institution: "Børnehuset", group: "Vuggestue", status: "sick", statusLabel: "Sick",
              arrivedAt: nil, leftAt: nil, pickup: Pickup(time: nil, by: nil), closesAt: "16:45", canReportSick: false),
    ])
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SalaEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SalaEntry) -> Void) {
        if context.isPreview { return completion(.sample) }
        completion(Self.fallback(Shared.snapshot, now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SalaEntry>) -> Void) {
        Task {
            let now = Date.now
            var entry: SalaEntry
            do {
                // Not saved: the app is the snapshot's only writer.
                entry = Self.entry(try await Shared.fetchToday(), now: now)
            } catch Shared.FetchError.authRequired {
                entry = SalaEntry(date: now, message: "Log in needed")
            } catch Shared.FetchError.unauthorized {
                entry = SalaEntry(date: now, message: "Check Sala settings")
            } catch {
                entry = Self.fallback(Shared.snapshot, now: now)
            }
            let refresh = Self.nextRefresh(after: now)
            var entries = [entry]
            // Data is shown for at most an hour after it was fetched, and never past its day,
            // in case WidgetKit delays the next refresh.
            if entry.message == nil,
               let midnight = Shared.calendar.date(byAdding: .day, value: 1, to: Shared.calendar.startOfDay(for: now)) {
                let expiry = min((entry.asOf ?? now).addingTimeInterval(3600), midnight)
                entries.append(SalaEntry(date: expiry, message: "Open Sala"))
            }
            completion(Timeline(entries: entries, policy: .after(refresh)))
        }
    }

    /// The children if they're for today (Copenhagen), else "Open Sala".
    static func entry(_ snapshot: TodaySnapshot?, now: Date, asOf: Date? = nil) -> SalaEntry {
        guard let snapshot, snapshot.date == Shared.ymd(now), !snapshot.children.isEmpty else {
            return SalaEntry(date: now, message: "Open Sala")
        }
        return SalaEntry(date: now, children: snapshot.children, asOf: asOf)
    }

    /// The app's snapshot, only while it's under an hour old.
    static func fallback(_ snapshot: TodaySnapshot?, now: Date) -> SalaEntry {
        guard let fetchedAt = snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 3600 else {
            return SalaEntry(date: now, message: "Open Sala")
        }
        return entry(snapshot, now: now, asOf: fetchedAt)
    }

    /// Every 15 minutes from 06:00 to 18:00 Copenhagen time, otherwise at the next 06:00.
    static func nextRefresh(after now: Date) -> Date {
        let cal = Shared.calendar
        if (6..<18).contains(cal.component(.hour, from: now)) { return now.addingTimeInterval(15 * 60) }
        let six = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        return six > now ? six : cal.date(byAdding: .day, value: 1, to: six) ?? now.addingTimeInterval(3600)
    }
}

// MARK: - Views

extension Child {
    var pickupText: String { "Pickup " + (pickup?.time ?? "–") }
    var closesText: String? { closesAt.map { "closes \($0)" } }
}

struct SalaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SalaEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { Color.card }
            .widgetURL(URL(string: "sala://today"))
    }

    @ViewBuilder private var content: some View {
        if let message = entry.message ?? (entry.children.isEmpty ? "Open Sala" : nil) {
            switch family {
            case .accessoryInline: Text("Sala: \(message)")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("Sala").font(.headline)
                    Text(message)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading) {
                    Text("Sala").font(.headline)
                    Spacer()
                    Text(message).font(.subheadline.weight(.semibold)).foregroundStyle(Color.salaAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            let child = entry.children[0]
            switch family {
            case .accessoryInline:
                Text("\(child.name) \(child.statusLabel) · pickup \(child.pickup?.time ?? "–")" + (asOf.map { " · \($0)" } ?? ""))
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("\(child.name) · \(child.statusLabel)").font(.headline)
                    Text(([child.pickupText] + [child.closesText].compactMap { $0 }).joined(separator: " · "))
                    if let asOf { Text(asOf).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    if family == .systemMedium {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(entry.children.prefix(2)) { ChildColumn(child: $0, showsPerson: true) }
                        }
                    } else {
                        ChildColumn(child: child, showsPerson: false)
                    }
                    if let asOf { Text(asOf).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// "as of 14:05" (Copenhagen) when showing the app's snapshot.
    private var asOf: String? {
        entry.asOf.map {
            let t = Shared.calendar.dateComponents([.hour, .minute], from: $0)
            return String(format: "as of %02d:%02d", t.hour ?? 0, t.minute ?? 0)
        }
    }
}

struct ChildColumn: View {
    let child: Child
    let showsPerson: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(child.name).font(.headline).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(child.statusColors.text).frame(width: 6, height: 6)
                Text(child.statusLabel).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(child.statusColors.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(child.statusColors.fill, in: .capsule)
            Spacer(minLength: 0)
            Text(child.pickupText).font(.subheadline.weight(.semibold)).lineLimit(1)
            if showsPerson, let by = child.pickup?.by {
                Text(by).font(.caption).lineLimit(1)
            }
            if let closes = child.closesText {
                Text(closes).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

@main
struct SalaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SalaToday", provider: Provider()) { SalaWidgetView(entry: $0) }
            .configurationDisplayName("Today")
            .description("Status, pickup time and closing time.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemSmall) { SalaWidget() } timeline: { SalaEntry.sample; SalaEntry(date: .now, message: "Log in needed") }
#Preview(as: .systemMedium) { SalaWidget() } timeline: { SalaEntry.sample }
#Preview(as: .accessoryRectangular) { SalaWidget() } timeline: { SalaEntry.sample }
#Preview(as: .accessoryInline) { SalaWidget() } timeline: { SalaEntry.sample }
