import Contacts
import ContactsUI
import SwiftUI

/// Aula's contact book (API.md "Contacts"): a child's groups → the children and their guardians → one
/// person, with call, text, e-mail and Add to Contacts. Other families' data lives only in the open
/// screen's state: no cache, no logging.
struct ContactsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ContactGroup]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    BannerView(text: error) { self.error = nil }.listRowBackground(Color.clear)
                }
                if let groups {
                    if groups.isEmpty {
                        ContentUnavailableView("No groups", systemImage: "person.2", description: Text("Your children's groups in Aula show up here."))
                    }
                    // A section per child when there's more than one.
                    let children = groups.map(\.child).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    ForEach(children, id: \.self) { child in
                        Section(children.count > 1 ? child : "") {
                            ForEach(groups.filter { $0.child == child }) { group in
                                NavigationLink(group.name, value: group)
                            }
                        }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Contacts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { if groups == nil { await load() } }
            .navigationDestination(for: ContactGroup.self) { GroupContactsView(group: $0) }
            .navigationDestination(for: Contact.self) { ContactDetailView(contact: $0) }
        }
    }

    private func load() async {
        do {
            groups = try await store.client.contactGroups()
            error = nil
        } catch {
            self.error = store.handle(error)
        }
    }
}

private struct GroupContactsView: View {
    let group: ContactGroup
    @Environment(Store.self) private var store
    @State private var contacts: GroupContacts?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        List {
            if let error {
                BannerView(text: error) { self.error = nil }.listRowBackground(Color.clear)
            }
            if let contacts {
                let children = contacts.children.filter { matches($0.name) || $0.guardians.contains { matches($0.name) } }
                let staff = contacts.staff.filter { matches($0.name) }
                if children.isEmpty && staff.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No one here", systemImage: "person.2")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                ForEach(Array(children.enumerated()), id: \.element.id) { i, child in
                    Section(child.name) {
                        if child.guardians.isEmpty {
                            Text("No guardians listed").foregroundStyle(.secondary)
                        }
                        ForEach(Array(child.guardians.enumerated()), id: \.offset) { ContactRow(contact: $1) }
                    }
                    // The A–Z index: a letter on the first child with that initial.
                    .sectionIndexLabel(i > 0 && Self.initial(children[i - 1].name) == Self.initial(child.name) ? nil : Self.initial(child.name))
                }
                if !staff.isEmpty {
                    Section("Staff") {
                        ForEach(Array(staff.enumerated()), id: \.offset) { ContactRow(contact: $1) }
                    }
                    .sectionIndexLabel("#")
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listSectionIndexVisibility(.visible)
        .navigationTitle(group.name)
        .searchable(text: $query, prompt: "Child or parent")
        .refreshable { await load() }
        .task { if contacts == nil { await load() } }
    }

    static func initial(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "#" }

    private func matches(_ name: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedStandardContains(q)
    }

    private func load() async {
        do {
            contacts = try await store.client.groupContacts(group.id)
            error = nil
        } catch {
            self.error = store.handle(error)
        }
    }
}

private struct ContactRow: View {
    let contact: Contact

    var body: some View {
        NavigationLink(value: contact) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                if let relation = contact.relation {
                    Text(relation).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ContactDetailView: View {
    let contact: Contact
    @State private var adding = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.title2.bold())
                    if let relation = contact.relation {
                        Text(relation).foregroundStyle(.secondary)
                    }
                }
            }
            if !contact.shared {
                Text("\(contact.name) doesn't share contact details in Aula.").foregroundStyle(.secondary)
            } else if contact.phones.isEmpty && contact.email == nil && contact.address == nil {
                Text("No contact details in Aula.").foregroundStyle(.secondary)
            }
            if !contact.phones.isEmpty {
                Section("Phone") {
                    ForEach(contact.phones, id: \.self) { phone in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phone.label).font(.subheadline).foregroundStyle(.secondary)
                                Text(phone.number).textSelection(.enabled)
                            }
                            Spacer()
                            if let tel = Self.url("tel", phone.number) {
                                Button("Call", systemImage: "phone.fill") { openURL(tel) }
                            }
                            if let sms = Self.url("sms", phone.number) {
                                Button("Message", systemImage: "message.fill") { openURL(sms) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let email = contact.email {
                Section("E-mail") {
                    if let mail = URL(string: "mailto:\(email)") {
                        Link(email, destination: mail)
                    } else {
                        Text(email).textSelection(.enabled)
                    }
                }
            }
            if let address = contact.address {
                Section("Address") {
                    Text(address).textSelection(.enabled)
                }
            }
            if contact.shared && !(contact.phones.isEmpty && contact.email == nil && contact.address == nil) {
                Section {
                    Button("Add to Contacts", systemImage: "person.crop.circle.badge.plus") { adding = true }
                }
            }
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { NewContact(contact: contact) { adding = false }.ignoresSafeArea() }
    }

    /// `tel:` / `sms:` with only the digits and a leading +.
    static func url(_ scheme: String, _ number: String) -> URL? {
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        let only = String(number.filter { $0.isASCII && $0.isNumber })
        return only.isEmpty ? nil : URL(string: "\(scheme):\(plus)\(only)")
    }
}

/// Apple's new-contact form, filled in. Saving goes through the form, so Sala needs no Contacts permission.
private struct NewContact: UIViewControllerRepresentable {
    let contact: Contact
    let done: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let c = CNMutableContact()
        let parts = contact.name.split(separator: " ", maxSplits: 1).map(String.init)
        c.givenName = parts.first ?? contact.name
        c.familyName = parts.count > 1 ? parts[1] : ""
        c.phoneNumbers = contact.phones.map { phone in
            let label = switch phone.label {
            case "Home": CNLabelHome
            case "Work": CNLabelWork
            default: CNLabelPhoneNumberMobile
            }
            return CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: phone.number))
        }
        if let email = contact.email { c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)] }
        if let address = contact.address {
            let postal = CNMutablePostalAddress()
            postal.street = address  // ponytail: Aula's one-line address in the street field; split it if anyone minds
            c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]
        }
        let vc = CNContactViewController(forNewContact: c)
        vc.delegate = context.coordinator
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) { done() }
    }
}
