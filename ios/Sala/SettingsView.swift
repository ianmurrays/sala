import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var calendarSync = CalendarSync.enabled
    @State private var calendarDenied = false
    @State private var syncStatus = CalendarSync.status
    @State private var appLock = AppLock.enabled
    @State private var notifications = Notifier.enabled
    @State private var notificationsDenied = false
    @State private var refreshStatus = BackgroundRefresh.status
    #if DEBUG
    @State private var captureTraffic = TrafficLog.enabled
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Log out of Aula", role: .destructive) { confirmLogout = true }
                } footer: {
                    Text("Sala talks to Aula directly from this phone. Logging out forgets the session; you'll need MitID to log in again.")
                }

                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        LabeledContent("Translate and summarize", value: store.aiOn ? AI.provider.title : "Off")
                    }
                } footer: {
                    Text("AI that translates or summarizes a message or post when you tap it.")
                }

                Section {
                    Toggle("Lock with Face ID", isOn: Binding(get: { appLock }, set: { on in
                        appLock = on
                        Task {
                            if !on { AppLock.enabled = false; return }
                            appLock = await AppLock.shared.enable()
                        }
                    }))
                } footer: {
                    Text("Asks for Face ID or your passcode when Sala opens, and when you come back after more than 5 minutes away. The widget still shows today.")
                }

                Section {
                    Toggle("Sync to iOS Calendar", isOn: Binding(get: { calendarSync }, set: { on in
                        calendarSync = on
                        Task {
                            if !on { CalendarSync.disable(); return }
                            calendarSync = await CalendarSync.enable()
                            calendarDenied = !calendarSync
                            if calendarSync { await CalendarSync.sync(store.client) }
                            syncStatus = CalendarSync.status
                        }
                    }))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(calendarDenied
                            ? "Sala needs full calendar access for this. Turn it on in the Settings app under Privacy & Security → Calendars."
                            : "Keeps a Sala calendar with the next \(CalendarSync.months) months of Aula events, updated each time you open the app. Turning it off removes that calendar.")
                        if calendarSync, let s = syncStatus { Text(s) }
                    }
                }

                Section {
                    Toggle("Notifications", isOn: Binding(get: { notifications }, set: { on in
                        notifications = on
                        guard on else { return Notifier.disable() }
                        Task {
                            notifications = await Notifier.enable()
                            notificationsDenied = !notifications
                        }
                    }))
                } footer: {
                    Text(notificationsDenied
                        ? "Sala isn't allowed to notify. Turn notifications on for Sala in the Settings app."
                        : "New direct messages, important posts, holiday requests and their deadlines, and when Aula needs you to log in again. iOS decides when Sala may check in the background: often a few times a day, and never after you swipe Sala away, so they can arrive hours late.")
                }

                #if DEBUG
                Section {
                    Toggle("Capture Aula traffic", isOn: Binding(get: { captureTraffic }, set: {
                        captureTraffic = $0
                        TrafficLog.enabled = $0
                    }))
                    Button("Clear captured traffic", role: .destructive) { TrafficLog.clear() }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Writes every Aula call and its answer to aula-traffic.jsonl. Pull it with scripts/pull-aula-traffic.sh.")
                }

                Section {
                    Button("Expire the Aula session and reload") {
                        Task {
                            await Aula.shared.debugExpireSession()
                            await store.load()
                            dismiss()
                        }
                    }
                    Button("Run background refresh now") {
                        Task {
                            await BackgroundRefresh.run()
                            refreshStatus = BackgroundRefresh.status
                        }
                    }
                    Button("Test still-sick notification in 5 s") {
                        let child = store.today?.children.first
                        Task { await StillSick.schedule(child: child?.id ?? 0, name: child?.name ?? "Oskar", at: Date() + 5) }
                    }
                } footer: {
                    // Background runs write it too, so this also shows whether iOS has run one.
                    Text("Last background refresh: \(refreshStatus ?? "never")")
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Log out of Aula?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log out", role: .destructive) {
                    Task {
                        await store.logout()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Settings → AI: where translations and summaries run, or off.
struct AISettingsView: View {
    @Environment(Store.self) private var store
    @State private var provider = AI.provider
    @State private var endpoint = AI.endpoint
    @State private var openAIModel = AI.openAIModel
    @State private var openAIKey = AI.openAIKey
    @State private var anthropicModel = AI.anthropicModel
    @State private var anthropicKey = AI.anthropicKey
    @State private var translatePrompt = AI.customPrompt(.translate)
    @State private var summarizePrompt = AI.customPrompt(.summarize)
    /// The provider's models, loaded on a tap (never while the endpoint is typed: the key goes with the request); nil until loaded.
    @State private var models: [String]?
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var advanced = AI.provider == .openAI || AI.provider == .anthropic

    var body: some View {
        Form {
            Section {
                ForEach([AI.Provider.off, .device]) { option($0) }
            } footer: {
                if provider == .off || provider == .device { Text(footer) }
            }

            // Providers that send the text off the phone, folded away so they're a deliberate choice.
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    ForEach([AI.Provider.openAI, .anthropic]) { option($0) }
                }
            } footer: {
                if provider == .openAI || provider == .anthropic { Text(footer) }
            }

            if provider == .openAI {
                Section("Endpoint") {
                    TextField("https://api.openai.com/v1", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional)", text: $openAIKey)
                }
                modelSection($openAIModel, placeholder: "Model")
            }
            if provider == .anthropic {
                Section("Anthropic") {
                    SecureField("API key", text: $anthropicKey)
                }
                modelSection($anthropicModel, placeholder: "Default: \(AI.defaultAnthropicModel)")
            }

            if provider != .off {
                if let reason = AI.unavailableReason(provider) {
                    Section { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(Color.sickText) }
                }
                Section {
                    promptEditor($translatePrompt, .translate)
                } header: {
                    Text("Translate prompt")
                } footer: {
                    Text("Leave empty for the default. {lang} becomes your iPhone's language.")
                }
                Section("Summarize prompt") { promptEditor($summarizePrompt, .summarize) }
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .onChange(of: provider) { save() }
        .onChange(of: [endpoint, openAIModel, openAIKey, anthropicModel, anthropicKey, translatePrompt, summarizePrompt]) { save() }
        // A list loaded for another provider, endpoint or key is not this one's.
        .onChange(of: [provider.rawValue, endpoint, openAIKey, anthropicKey]) {
            models = nil
            modelsError = nil
        }
    }

    private var footer: String {
        switch provider {
        case .off: "No AI buttons anywhere. Nothing is sent."
        case .device: "Apple's model on this iPhone. Nothing leaves your phone. Needs Apple Intelligence."
        case .openAI, .anthropic: "The text of the message or post you tap is sent to this provider, and its terms and data policies apply. It may store it. Only use one you trust with your children's school messages."
        }
    }

    /// A row that picks `p`, with a checkmark when it's the choice.
    private func option(_ p: AI.Provider) -> some View {
        Button { provider = p } label: {
            HStack {
                Text(p.title).foregroundStyle(Color.primary)
                Spacer()
                if provider == p { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            }
        }
        .accessibilityAddTraits(provider == p ? .isSelected : [])
    }

    private func modelSection(_ model: Binding<String>, placeholder: String) -> some View {
        Section {
            if let models, !models.isEmpty {
                Picker("Model", selection: model) {
                    if !models.contains(model.wrappedValue) { Text(model.wrappedValue.isEmpty ? placeholder : model.wrappedValue).tag(model.wrappedValue) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
            }
            TextField(placeholder, text: model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if models == nil {
                Button {
                    loadingModels = true
                    modelsError = nil
                    Task {
                        defer { loadingModels = false }
                        do { models = try await AI.models(provider) } catch { modelsError = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Text("Load models")
                        if loadingModels { Spacer(); ProgressView() }
                    }
                }
                .disabled(loadingModels)
            }
        } header: {
            Text("Model")
        } footer: {
            if let modelsError { Text("Couldn't load the models: \(modelsError) You can still type a model's name.") }
            else if models == nil { Text("Type a model's name, or load the provider's list.") }
        }
    }

    private func promptEditor(_ text: Binding<String>, _ action: AI.Action) -> some View {
        TextField(AI.defaultPrompt(action), text: text, axis: .vertical)
            .font(.callout)
            .lineLimit(3...12)
    }

    private func save() {
        AI.provider = provider
        AI.endpoint = endpoint
        AI.openAIModel = openAIModel
        AI.openAIKey = openAIKey
        AI.anthropicModel = anthropicModel
        AI.anthropicKey = anthropicKey
        AI.setCustomPrompt(.translate, translatePrompt)
        AI.setCustomPrompt(.summarize, summarizePrompt)
        store.aiSettingsChanged()
    }
}
