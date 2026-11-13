import Foundation
import XCTest

// The Shortcuts and Siri intents' child query and no-session path, on demo mode's fake Aula.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "DemoAula")

final class IntentTests: XCTestCase {
    private func query(tokens: Aula.Tokens?) -> (ChildQuery, DemoTransport) {
        let transport = DemoTransport(dir: fixtures)
        return (ChildQuery(client: APIClient(aula: Aula(transport: transport, tokens: tokens))), transport)
    }

    func testChildQueryListsTodaysChildren() async throws {
        let (q, transport) = query(tokens: DemoTransport.tokens)
        let today = try await q.client.today()
        let all = try await q.allEntities()
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(all.map(\.id), today.children.map(\.id))
        XCTAssertEqual(all.map(\.name), today.children.map(\.name))

        let first = all[0]
        let byID = try await q.entities(for: [first.id])
        XCTAssertEqual(byID.map(\.id), [first.id])
        let byName = try await q.entities(matching: String(first.name.prefix(3)).lowercased())
        XCTAssertTrue(byName.contains { $0.id == first.id })
        let none = try await q.entities(matching: "zzz-no-such-child")
        XCTAssertEqual(none.map(\.id), [])
        XCTAssertEqual(transport.missing, [])
    }

    func testNoSessionSaysOpenSala() async {
        let (q, transport) = query(tokens: nil)
        do {
            _ = try await q.allEntities()
            XCTFail("answered with no session")
        } catch {
            XCTAssertEqual(error as? IntentFailure, .loginNeeded)
        }
        XCTAssertEqual(transport.missing, [])
    }

    func testTexts() {
        let c = Child(id: 1, name: "Oskar", institution: "", group: "", status: "present", statusLabel: "Present",
                      pickup: Pickup(time: "16:00", by: "Far"), closesAt: "17:00", canReportSick: true)
        XCTAssertEqual(IntentText.status(c), "Oskar: Present. Pickup 16:00 by Far. Closes 17:00.")
        XCTAssertEqual(IntentText.unread([]), "No unread messages.")
    }
}
