import SwiftUI

struct PickupSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let child: Child

    @State private var options: PickupOptions?
    @State private var loadError: String?
    @State private var time: String?
    @State private var by: String?
    @State private var note = ""
    /// Set when the chosen time isn't one of the offered chips.
    @State private var customTime: String?
    @State private var showWheel = false
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    form(options)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Can't load pickup", systemImage: "exclamationmark.triangle")
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
                        Text("Pickup today").font(.headline)
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
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
                        Button("Save", systemImage: "checkmark", role: .confirm) { Task { await save() } }
                            .disabled(time == nil || by == nil || options == nil)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task { await load() }
        .sheet(isPresented: $showWheel) {
            if let options {
                TimeWheel(slots: slots(options), initial: customTime ?? time) { picked in
                    customTime = picked
                    time = picked
                }
            }
        }
    }

    private var subtitle: String {
        let date = options.flatMap { Fmt.day($0.date) } ?? store.today.flatMap { Fmt.day($0.date) } ?? Date()
        return "\(child.name) · \(Fmt.format(date, "EEEdMMM"))"
    }

    // MARK: Form

    private func form(_ o: PickupOptions) -> some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(o.times, id: \.self) { t in
                        chip(t, selected: time == t && customTime == nil) {
                            time = t
                            customTime = nil
                        }
                    }
                    chip(customTime ?? "Other…", selected: customTime != nil) {
                        showWheel = true
                    }
                    .accessibilityLabel(customTime.map { "Other time, \($0)" } ?? "Other time")
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                HStack {
                    Text("Time")
                    Spacer()
                    if let open = openingText(o) {
                        Text(open).textCase(nil)
                    }
                }
            }

            Section("Picked up by (pickup list)") {
                if o.people.isEmpty {
                    Text("No one is on the pickup list.").foregroundStyle(.secondary)
                }
                ForEach(o.people, id: \.self) { person in
                    Button {
                        by = person
                    } label: {
                        HStack {
                            Text(person).foregroundStyle(Color.primary)
                            Spacer()
                            if by == person {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.salaAccent)
                            }
                        }
                        .contentShape(.rect)
                    }
                    // Form buttons draw their label in the tint; only the checkmark should be blue.
                    .tint(Color.primary)
                    .accessibilityAddTraits(by == person ? .isSelected : [])
                }
            }

            Section("Note to staff") {
                TextField("Optional", text: $note, axis: .vertical)
                    .lineLimit(2...6)
            }

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.sickText)
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.salaAccent : Color.card, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openingText(_ o: PickupOptions) -> String? {
        switch (o.opensAt, o.closesAt) {
        case let (a?, b?): "Open \(a)–\(b)"
        case let (nil, b?): "Closes \(b)"
        case let (a?, nil): "Opens \(a)"
        default: nil
        }
    }

    /// 5-minute slots within opening hours (or the whole day when they aren't given).
    private func slots(_ o: PickupOptions) -> [String] {
        let start = Fmt.minutes(o.opensAt) ?? 0
        let end = Fmt.minutes(o.closesAt) ?? (23 * 60 + 55)
        let first = (start + 4) / 5 * 5
        guard first <= end else { return [] }
        return stride(from: first, through: end, by: 5).map(Fmt.hhmm)
    }

    // MARK: Actions

    private func load() async {
        loadError = nil
        do {
            let o = try await store.client.pickupOptions(child: child.id)
            options = o
            time = o.current?.time
            by = o.current?.by.flatMap { o.people.contains($0) ? $0 : nil }
            if let t = time, !o.times.contains(t) { customTime = t }
            note = o.note ?? ""
        } catch is CancellationError {
        } catch {
            store.handle(error)
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        guard let time, let by else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            try await store.savePickup(child: child.id, PickupUpdate(time: time, by: by, note: note))
            dismiss()
        } catch is CancellationError {
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Wheel picker over 5-minute slots.
struct TimeWheel: View {
    @Environment(\.dismiss) private var dismiss
    let slots: [String]
    let onPick: (String) -> Void
    @State private var selection: String

    init(slots: [String], initial: String?, onPick: @escaping (String) -> Void) {
        self.slots = slots
        self.onPick = onPick
        let fallback = slots.isEmpty ? "" : slots[slots.count / 2]
        // Snap the initial value to the nearest slot.
        let target = Fmt.minutes(initial)
        let nearest = target.flatMap { t in slots.min { abs((Fmt.minutes($0) ?? 0) - t) < abs((Fmt.minutes($1) ?? 0) - t) } }
        _selection = State(initialValue: nearest ?? fallback)
    }

    var body: some View {
        NavigationStack {
            Group {
                if slots.isEmpty {
                    ContentUnavailableView("No times available", systemImage: "clock")
                } else {
                    Picker("Pickup time", selection: $selection) {
                        ForEach(slots, id: \.self) { Text($0).monospacedDigit().tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                }
            }
            .navigationTitle("Other time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) {
                        onPick(selection)
                        dismiss()
                    }
                    .disabled(slots.isEmpty)
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}
