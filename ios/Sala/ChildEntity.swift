import AppIntents
import Foundation

// The parts of the Shortcuts and Siri intents (SalaIntents.swift) that only need Aula, so the tests compile them.

/// A child from `/today`, for the Shortcuts picker and Siri ("Ella").
struct ChildEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Child"
    static let defaultQuery = ChildQuery()

    let id: Int
    let name: String

    init(_ child: Child) {
        id = child.id
        name = child.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ChildQuery: EnumerableEntityQuery, EntityStringQuery {
    var client = APIClient()

    func allEntities() async throws -> [ChildEntity] {
        try await IntentFailure.mapping { try await client.today() }.children.map(ChildEntity.init)
    }

    func entities(for ids: [Int]) async throws -> [ChildEntity] {
        try await allEntities().filter { ids.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ChildEntity] {
        try await allEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

/// What an intent shows when it can't finish. Never starts MitID: with no session it says to open Sala.
enum IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case loginNeeded
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .loginNeeded: "Open Sala to log in."
        case .message(let m): "\(m)"
        }
    }

    /// Runs an `APIClient` call, its errors as ones Siri and Shortcuts can say.
    static func mapping<T>(isolation: isolated (any Actor)? = #isolation, _ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch APIError.authRequired { throw loginNeeded }
        catch let e as APIError { throw message(e.localizedDescription) }
    }
}

enum IntentText {
    /// "Oskar: Present. Pickup 16:00 by Jonas Hansen (Far). Closes 17:00."
    static func status(_ c: Child) -> String {
        var s = "\(c.name): \(c.statusLabel)."
        switch (c.pickup?.time, c.pickup?.by) {
        case let (t?, b?): s += " Pickup \(t) by \(b)."
        case let (t?, nil): s += " Pickup \(t)."
        case let (nil, b?): s += " Picked up by \(b)."
        default: break
        }
        if let close = c.closesAt { s += " Closes \(close)." }
        return s
    }

    /// The count and the newest three subjects. Titles only, never message bodies.
    static func unread(_ threads: [ThreadSummary]) -> String {
        let unread = threads.filter(\.unread)
        guard !unread.isEmpty else { return "No unread messages." }
        return "\(unread.count) unread: " + unread.prefix(3).map(\.subject).joined(separator: "; ")
    }
}
