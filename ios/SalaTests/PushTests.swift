import Foundation
import XCTest

/// The background refresh's notification rules (AulaPush.swift), ported from the old server's push.py.
final class PushTests: XCTestCase {
    private func person(_ id: Int, _ name: String) -> JSONObject {
        ["fullName": name, "mailBoxOwner": ["id": id], "leaveTime": NSNull()]
    }

    private func thread(recipients: [JSONObject], extra: Int = 0, read: Bool = false, muted: Bool = false) -> JSONObject {
        ["id": 7, "mailBoxOwner": ["id": 1], "read": read, "muted": muted, "extraRecipientsCount": extra,
         "creator": person(2, "Mette Lund"), "recipients": recipients,
         "subject": "Tur i skoven",
         "latestMessage": ["id": "m9", "sendDateTime": "2026-11-12T10:00:00+01:00", "text": ["html": "<p>Husk gummistøvler</p><p>på fredag.</p>"]]]
    }

    func testMessages() {
        let mine: Set<Int> = [1]
        let direct = Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "Mette Lund")]), mine: mine)
        XCTAssertEqual(direct?.key, "message:7:m9")
        XCTAssertEqual(direct?.title, "Mette Lund")
        XCTAssertEqual(direct?.subtitle, "Tur i skoven")
        XCTAssertEqual(direct?.body, "Husk gummistøvler på fredag.")
        XCTAssertEqual(direct?.link, "sala://thread/7")
        XCTAssertEqual(direct?.notify, true)

        XCTAssertEqual(Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "Mette Lund")], read: true), mine: mine)?.notify, false, "read: mine or already seen")
        XCTAssertEqual(Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "Mette Lund")], muted: true), mine: mine)?.notify, false)
        XCTAssertEqual(Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "A"), person(3, "B")]), mine: mine)?.notify, true, "group")
        XCTAssertEqual(Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "A")], extra: 1), mine: mine)?.notify, true, "one listed + one extra")

        // Several others: no single name to show, so the subject.
        let group = Push.messageEvent(thread(recipients: [person(1, "Me"), person(2, "A"), person(3, "B")]), mine: mine)
        XCTAssertEqual(group?.title, "Tur i skoven")
        XCTAssertNil(group?.subtitle)

        // Sensitive: no excerpt.
        var sensitive = thread(recipients: [person(1, "Me"), person(2, "Mette Lund")])
        sensitive["sensitive"] = true
        XCTAssertNil(Push.messageEvent(sensitive, mine: mine)?.body)

        // Only the extra one: who it is isn't listed.
        var unknown = thread(recipients: [person(1, "Me")], extra: 1)
        unknown["creator"] = person(1, "Me")
        unknown["subject"] = ""
        XCTAssertEqual(Push.messageEvent(unknown, mine: mine)?.title, "New message")
        XCTAssertEqual(Push.messageEvent(unknown, mine: mine)?.notify, true)
    }

    func testHolidayReminders() {
        let reg = VacationRegistration(["vacationRegistrationId": 5, "isMissingAnswer": true, "startDate": "2026-12-21",
                                        "endDate": "2026-12-23", "responseDeadline": "2026-11-13"], child: ["id": 3])
        let dayBefore = Push.holidayEvents(reg, today: Day(2026, 11, 12)!)
        XCTAssertEqual(dayBefore.map(\.key), ["holiday:5", "holiday-due:5:2026-11-13:1"])
        XCTAssertEqual(dayBefore.map(\.title), ["Holiday request 21–23 Dec · answer by 13 Nov", "Holiday request 21–23 Dec · answer by tomorrow"])
        XCTAssertEqual(dayBefore[0].covers, ["holiday-due:5:2026-11-13:1"])
        XCTAssertEqual(dayBefore[1].notBefore, ISO8601DateFormatter().date(from: "2026-11-12T06:00:00Z"), "07:00 Copenhagen")
        XCTAssertEqual(dayBefore[0].notBefore, dayBefore[1].notBefore)

        XCTAssertEqual(Push.holidayEvents(reg, today: Day(2026, 11, 13)!).last?.title, "Holiday request 21–23 Dec · answer today")
        let early = Push.holidayEvents(reg, today: Day(2026, 11, 1)!)
        XCTAssertEqual(early.map(\.key), ["holiday:5"])
        XCTAssertNil(early[0].notBefore)
        XCTAssertEqual(Push.holidayEvents(reg, today: Day(2026, 11, 14)!).map(\.key), ["holiday:5"], "no reminder after the deadline")

        // One row per child: an answered sibling's row first must not hide the request.
        let answered = VacationRegistration(["vacationRegistrationId": 5, "isMissingAnswer": false], child: ["id": 4])
        XCTAssertEqual(Push.holidayEvents([answered, reg, reg], today: Day(2026, 11, 1)!).map(\.key), ["holiday:5"])

        // Aula locked it (the portal won't take an answer): nothing to ask for.
        let locked = VacationRegistration(["vacationRegistrationId": 6, "isMissingAnswer": true, "isEditable": false,
                                           "responseDeadline": "2026-11-13"], child: ["id": 3])
        XCTAssertEqual(Push.holidayEvents([locked], today: Day(2026, 11, 12)!).map(\.key), [])
    }
}
