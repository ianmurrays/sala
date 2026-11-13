import Foundation

// The AulaApiClient methods (aula/api_client.py) that Sala's mapping calls, on top of the session
// layer (`get` / `post` check Aula's envelope; non-2xx and non-zero status codes throw
// `Aula.Failure.rejected`, like the library's raise_for_status + AulaRejectedError).

/// Aula answered, but not in a way the library accepts (its HttpRequestError / ValueError).
struct LibraryError: Error, CustomStringConvertible {
    var description: String
}

extension Aula {
    static func ids(_ key: String, _ values: [Int]) -> [(String, String)] { values.map { (key, String($0)) } }

    // MARK: profile

    /// get_profile, built from the two answers that open the session instead of new calls,
    /// and kept for the session (`generation`).
    func profile() async throws -> AulaProfile {
        try await ensureOpen()
        if let cached = local.profile, cached.generation == generation { return cached.value }
        let profiles = J.list(J.getIn(profilesByLogin, "data.profiles")) ?? []
        guard let profileDict = profiles.first as? JSONObject else {
            throw LibraryError(description: "No profile data found in API response")
        }
        var children: [AulaChild] = []
        if let raw = J.get(profileDict, "children", default: [Any]()) as? [Any] {
            for case let childDict as JSONObject in raw {
                children.append(try AulaChild(childDict))
            }
        }
        children += extendedAccessChildren(Set(children.map(\.id)))
        let ips = (J.get(profileDict, "institutionProfiles", default: [Any]()) as? [Any] ?? []).compactMap { $0 as? JSONObject }
        let ownIds = ips.filter { J.has($0, "id") }.compactMap { J.int($0["id"]) }
        let profileId = J.get(profileDict, "profileId")
        guard J.int(profileId) != nil || (J.str(profileId).flatMap { Int(Py.strip($0)) }) != nil else {
            throw LibraryError(description: "Failed to parse main profile data")
        }
        let profile = AulaProfile(children: children, institutionProfileIds: ownIds + children.map(\.id), guardianIds: Set(ownIds))
        local.profile = (generation, profile)
        return profile
    }

    /// Children the guardian has extended access to ("udvidet adgang", e.g. a bonus parent).
    /// Aula only lists them in `getProfileContext`, not in `getProfilesByLogin`.
    private func extendedAccessChildren(_ known: Set<Int>) -> [AulaChild] {
        var known = known
        var out: [AulaChild] = []
        for case let institution as JSONObject in J.list(J.getIn(profileContext, "data.institutions")) ?? [] {
            for case var childDict as JSONObject in J.list(J.get(institution, "children")) ?? [] {
                if let id = J.int(J.get(childDict, "id")), known.contains(id) { continue }
                childDict["institutionProfile"] = [
                    "institutionName": J.get(institution, "name", default: "") ?? NSNull(),
                    "institutionCode": J.get(childDict, "institutionCode") ?? NSNull(),
                ] as JSONObject
                guard let child = try? AulaChild(childDict) else { continue }
                known.insert(child.id)
                out.append(child)
            }
        }
        return out
    }

    // MARK: presence

    func getDailyOverview(_ childId: Int) async throws -> DailyOverview? {
        let r = try await get("presence.getDailyOverview", [("childIds[]", String(childId))])
        guard J.truthy(r["data"]), let first = J.list(r["data"])?.first as? JSONObject else { return nil }
        return DailyOverview(first)
    }

    func getPresenceTemplates(_ ids: [Int], from: Day, to: Day) async throws -> [PresenceWeekTemplate] {
        let r = try await get(
            "presence.getPresenceTemplates",
            Self.ids("filterInstitutionProfileIds[]", ids) + [("fromDate", from.iso), ("toDate", to.iso)])
        guard let data = J.dict(J.get(r, "data")), let templates = J.get(data, "presenceWeekTemplates", default: [Any]()) as? [Any] else {
            return []
        }
        return templates.compactMap { t in (t as? JSONObject).flatMap { try? PresenceWeekTemplate($0) } }
    }

    func getPresenceConfiguration(_ childIds: [Int]) async throws -> [PresenceConfiguration] {
        let r = try await get("presence.getPresenceConfigurationByChildIds", Self.ids("childIds[]", childIds))
        guard let data = J.get(r, "data", default: [Any]()) as? [Any] else { return [] }
        return data.compactMap { ($0 as? JSONObject).map(PresenceConfiguration.init) }
    }

    func getPickupResponsibles(_ childIds: [Int]) async throws -> [ChildPickupResponsibles] {
        let r = try await get("presence.getPickupResponsibles", Self.ids("uniStudentIds[]", childIds))
        guard let data = J.get(r, "data") as? [Any] else { return [] }
        return data.compactMap { ($0 as? JSONObject).flatMap { try? ChildPickupResponsibles($0) } }
    }

    /// update_presence_template with ActivityType.PICKED_UP_BY. `entryTime` nil is sent as JSON null,
    /// like the portal. The backend wants camelCase keys, the activity type as an int and the repeat
    /// pattern in lower case.
    func updatePresenceTemplate(
        _ institutionProfileId: Int, byDate: Day, entryTime: String?, exitTime: String?, exitWith: String?,
        comment: String?, templateId: Int?, repeatPattern: String = "Never"
    ) async throws {
        let repeatValue = ["never": "never", "weekly": "weekly", "every2weeks": "every_2_weeks"][repeatPattern.lowercased()] ?? "never"
        // Default expiresAt: end of the school year (June 30).
        let endYear = byDate.month > 6 ? byDate.year + 1 : byDate.year
        var payload: JSONObject = [
            "institutionProfileId": institutionProfileId,
            "byDate": byDate.iso,
            "presenceActivity": [
                "activityType": 0,
                "pickup": ["entryTime": J.out(entryTime), "exitTime": J.out(exitTime), "exitWith": exitWith ?? ""] as JSONObject,
            ] as JSONObject,
            "comment": comment ?? "",
            "repeatPattern": repeatValue,
            "expiresAt": "\(endYear)-06-30T00:00:00+00:00",
        ]
        if let templateId { payload["id"] = templateId }
        _ = try await post("presence.updatePresenceTemplate", payload)
    }

    /// update_presence_status: the portal's sick button (report and take back are the same call).
    func updatePresenceStatus(_ ids: [Int], _ status: PresenceState) async throws -> Bool {
        guard !ids.isEmpty else { throw LibraryError(description: "update_presence_status requires at least one profile ID") }
        let r = try await post("presence.updateStatusByInstitutionProfileIds", ["institutionProfileIds": ids, "status": status.rawValue] as JSONObject)
        // A bare boolean in "data"; older/proxied answers omit it, which is not a failure.
        return J.bool(J.get(r, "data")) ?? true
    }

    /// add_vacation (`calendar.addVacation`).
    func addVacation(_ childIds: [Int], start: Day, end: Day, comment: String) async throws {
        guard !childIds.isEmpty else { throw LibraryError(description: "add_vacation requires at least one child ID") }
        if let err = Self.validateVacation(start: start, end: end, comment: comment, today: AulaTime.today()) {
            throw LibraryError(description: err)
        }
        _ = try await post("calendar.addVacation", [
            "childIds": childIds,
            "intervals": [["startDate": start.iso, "endDate": end.iso]],
            "comment": comment,
        ] as JSONObject)
    }

    /// validate_vacation: the guardian portal's own form rules (the server's limits are untested).
    /// The error message, or nil.
    static func validateVacation(start: Day, end: Day, comment: String, today: Day) -> String? {
        if start < today { return "the absence cannot start in the past (\(start.iso) is before \(today.iso))" }
        if end < start { return "end date \(end.iso) is before start date \(start.iso)" }
        let latest = start.month == 2 && start.day == 29 ? Day(start.year + 1, 2, 28)! : start.replacing(year: start.year + 1)!
        if end > latest { return "end date \(end.iso) is more than a year after start date \(start.iso) (latest \(latest.iso))" }
        let n = Py.len(comment)
        if n > 250 { return "comment is \(n) characters; Aula allows at most 250" }
        return nil
    }

    func getVacationRegistrations(_ childIds: [Int]) async throws -> [VacationRegistration] {
        let r = try await get("presence.getVacationRegistrationsByChildren", Self.ids("childIds[]", childIds))
        guard let data = J.get(r, "data", default: [Any]()) as? [Any] else { return [] }
        var out: [VacationRegistration] = []
        for case let group as JSONObject in data {
            let child = J.dict(J.get(group, "child")) ?? [:]
            guard let regs = J.get(group, "vacationRegistrations") as? [Any] else { continue }
            for case let item as JSONObject in regs {
                out.append(VacationRegistration(item, child: child))
            }
        }
        return out
    }

    // MARK: calendar

    func getImportantDates(limit: Int = 10, includeToday: Bool = true) async throws -> [Any] {
        let r = try await get("calendar.getImportantDates", [("limit", String(limit)), ("includeToday", includeToday ? "true" : "false")])
        return J.get(r, "data", default: [Any]()) as? [Any] ?? []
    }

    func getBirthdayEvents(_ codes: [String], start: String, end: String) async throws -> [Any] {
        let r = try await get(
            "calendar.getBirthdayEventsForInstitutions", codes.map { ("InstCodes[]", $0) } + [("Start", start), ("End", end)])
        return J.get(r, "data", default: [Any]()) as? [Any] ?? []
    }

    /// The portal's calendar (0.*.js LOAD_EVENTS_BY_PROFILEID: POST `{instProfileIds, resourceIds, start, end}`,
    /// dates as moment "YYYY-MM-DD HH:mm:ss.SSSSZ"). Live, Aula refuses a 60-day range (403, subCode 0) and
    /// answers 31 days, so callers ask for one month at a time.
    func getEvents(_ ids: [Int], from: Day, to: Day) async throws -> [JSONObject] {
        // "2026-11-01T00:00:00+01:00" -> "2026-11-01 00:00:00.0000+01:00"
        func moment(_ d: Day) -> String {
            let s = AulaTime.combine(d, endOfDay: false)
            return s.prefix(10) + " " + s.dropFirst(11).prefix(8) + ".0000" + s.dropFirst(19)
        }
        let r = try await post("calendar.getEventsByProfileIdsAndResourceIds", [
            "instProfileIds": ids, "resourceIds": [Int](), "start": moment(from), "end": moment(to),
        ] as JSONObject)
        return (J.list(r["data"]) ?? []).compactMap { $0 as? JSONObject }
    }

    // MARK: posts

    func getPosts(_ institutionProfileIds: [Int], page: Int = 1, limit: Int = 10) async throws -> [AulaPost] {
        let r = try await get("posts.getAllPosts", [
            ("parent", "profile"), ("index", String((page - 1) * limit)), ("limit", String(limit)),
        ] + Self.ids("institutionProfileIds[]", institutionProfileIds))
        var posts: [AulaPost] = []
        for case let p as JSONObject in J.list(J.getIn(r, "data.posts")) ?? [] {
            guard J.has(p, "id"), J.has(p, "title"), let post = try? AulaPost(p) else { continue }
            posts.append(post)
        }
        return posts
    }

    // MARK: messaging

    /// get_message_threads: page 0 of the inbox, newest first (raw rows).
    func getMessageThreads() async throws -> [JSONObject] {
        let r = try await get("messaging.getThreads", [("sortOn", "date"), ("orderDirection", "desc"), ("page", "0")])
        return (J.list(J.getIn(r, "data.threads")) ?? []).compactMap { $0 as? JSONObject }
    }

    /// get_all_messages_for_thread: every page until an empty one or one seen before.
    func getAllMessagesForThread(_ threadId: String) async throws -> [JSONObject] {
        var items: [JSONObject] = []
        var seenIds = Set<String>()
        var seenPages = Set<Data>()
        for page in 0..<100 {
            let r = try await get("messaging.getMessagesForThread", [("threadId", threadId), ("page", String(page))])
            let data = J.dict(J.or(r["data"], nil)) ?? [:]
            let messages = J.get(data, "messages", default: [Any]()) as? [Any] ?? []
            if messages.isEmpty { break }
            let signature = (try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])) ?? Data()
            if seenPages.contains(signature) { break }
            seenPages.insert(signature)
            let before = items.count
            for row in messages {
                guard let row = row as? JSONObject else { continue }
                if let id = J.get(row, "id"), J.truthy(id) {
                    let key = J.pyStr(id)
                    if seenIds.contains(key) { continue }
                    seenIds.insert(key)
                }
                items.append(row)
            }
            if items.count == before { break }
        }
        return items
    }

    /// The `data` object of an answer, or an error unless its status code is 0 (`_api_data`).
    private static func apiData(_ r: JSONObject, _ method: String) throws -> JSONObject {
        guard let status = J.dict(r["status"]), J.eq(J.get(status, "code"), 0) else {
            throw LibraryError(description: "Aula rejected \(method)")
        }
        return J.dict(J.get(r, "data")) ?? [:]
    }

    /// Message types Aula's web client accepts as the target of a read marker.
    private static let markable: Set<String> = ["Message", "MessageEdited", "MessageDeleted", "AutoReply"]

    /// mark_thread_read: moves the thread's read marker to its newest message, as the web client does
    /// when a thread is opened, and checks Aula reports the new marker. Pages of 20 are read until a
    /// message turns up (a thread can begin with events). Only threads in the guardian's own mailbox:
    /// common and OTP inboxes need an inbox id this doesn't send.
    @discardableResult
    func markThreadRead(_ threadId: String) async throws -> Bool {
        var newest: JSONObject?
        var more = false
        for page in 0..<50 {
            let r = try await get("messaging.getMessagesForThread", [("threadId", threadId), ("page", String(page)), ("limit", "20")])
            let data = try Self.apiData(r, "messaging.getMessagesForThread")
            guard let owner = J.dict(J.get(data, "mailBoxOwner")), J.eq(J.get(owner, "mailBoxOwnerType"), "institutionProfile") else {
                throw LibraryError(description: "thread \(threadId) is not shown to be in your own mailbox, and mark-read only handles those")
            }
            newest = (J.list(J.get(data, "messages")) ?? []).lazy.compactMap { $0 as? JSONObject }
                .first { J.str(J.get($0, "messageType")).map(Self.markable.contains) ?? false }
            more = J.truthy(J.get(data, "moreMessagesExist"))
            if newest != nil || !more { break }
        }
        if newest == nil && more { throw LibraryError(description: "thread \(threadId) has no message in its first 50 pages") }
        guard let newest, let newestId = J.get(newest, "id"), J.truthy(newestId) else { return false }
        let r = try await post("messaging.setLastReadMessage", [
            "threadId": threadId, "messageId": newestId, "commonInboxId": NSNull(), "otpInboxId": NSNull(),
        ] as JSONObject)
        _ = try Self.apiData(r, "messaging.setLastReadMessage")
        let check = try await get("messaging.getMessagesForThread", [("threadId", threadId), ("page", "0"), ("limit", "1")])
        let marker = J.get(try Self.apiData(check, "messaging.getMessagesForThread"), "lastReadMessageId")
        guard J.eq(marker, newestId) else { throw LibraryError(description: "Aula did not confirm the read marker of thread \(threadId)") }
        return true
    }

    func getMessageInfo(_ threadId: String, _ messageId: String) async throws -> JSONObject? {
        let r = try await get("messaging.getMessageInfoLight", [("ThreadId", threadId), ("MessageId", messageId)])
        guard let data = J.dict(J.or(r["data"], nil)), !data.isEmpty else { return nil }
        return data
    }

    func getMessageFolders(includeDeleted: Bool = false) async throws -> [MessageFolder] {
        let r = try await get("messaging.getFolders", [("IncludeDeletedFolders", includeDeleted ? "true" : "false")])
        guard let data = J.get(r, "data", default: [Any]()) as? [Any] else { return [] }
        return data.compactMap { item in
            guard let item = item as? JSONObject, J.has(item, "id") else { return nil }
            return MessageFolder(item)
        }
    }
}
