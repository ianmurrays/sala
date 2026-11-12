import SwiftUI

/// "Move…": the inbox, each folder, and a new folder.
struct MoveToFolderSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let thread: ThreadSummary

    @State private var naming = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.sickText)
                }
                Section {
                    destination("Inbox", systemImage: "tray", id: nil)
                    ForEach(store.folders) { f in
                        destination(f.name, systemImage: "folder", id: f.id)
                    }
                }
                Section {
                    Button("New Folder…", systemImage: "folder.badge.plus") { naming = true }
                }
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .folderNameAlert("New Folder", isPresented: $naming) { name in
                do {
                    let f = try await store.createFolder(name: name)
                    move(to: f.id)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ name: String, systemImage: String, id: Int?) -> some View {
        Button {
            move(to: id)
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer()
                if thread.folderId == id {
                    Image(systemName: "checkmark").foregroundStyle(Color.salaAccent)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(thread.folderId == id)
    }

    private func move(to id: Int?) {
        dismiss()
        Task { await store.move(thread.id, to: id) }
    }
}

/// Create, rename and delete folders.
struct ManageFoldersSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var renaming: Folder?
    @State private var deleting: Folder?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.sickText)
                }
                Section {
                    ForEach(store.folders) { f in
                        Button { renaming = f } label: {
                            Label(f.name, systemImage: "folder")
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = f }
                        }
                    }
                } footer: {
                    Text(store.folders.isEmpty ? "You have no folders." : "Tap a folder to rename it, swipe to delete it.")
                }
                Section {
                    Button("New Folder…", systemImage: "folder.badge.plus") { creating = true }
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .folderNameAlert("New Folder", isPresented: $creating) { name in
                await run { _ = try await store.createFolder(name: name) }
            }
            .folderNameAlert(
                "Rename Folder",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                initial: renaming?.name ?? ""
            ) { [renaming] name in
                guard let renaming else { return }
                await run { try await store.renameFolder(renaming.id, name: name) }
            }
            .alert(
                "Delete “\(deleting?.name ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                presenting: deleting
            ) { f in
                Button("Delete", role: .destructive) {
                    Task { await run { try await store.deleteFolder(f.id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Aula deletes the messages in the folder too. They are not moved back to the inbox.")
            }
        }
        .task { await store.loadFolders() }
    }

    private func run(_ op: () async throws -> Void) async {
        do {
            try await op()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// An alert with a name field (1–100 characters, like Aula's) and Save.
    func folderNameAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        initial: String = "",
        onSave: @escaping @MainActor (String) async -> Void
    ) -> some View {
        modifier(FolderNameAlert(title: title, isPresented: isPresented, initial: initial, onSave: onSave))
    }
}

private struct FolderNameAlert: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let initial: String
    let onSave: @MainActor (String) async -> Void
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in if shown { name = initial } }
            .alert(title, isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Save") {
                    let value = trimmed
                    Task { await onSave(value) }
                }
                .disabled(trimmed.isEmpty || trimmed.count > 100)
                Button("Cancel", role: .cancel) {}
            }
    }
}
