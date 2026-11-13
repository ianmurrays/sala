import Foundation

// The old server's routes (server/sala/app.py) as one entry point: the method, path (with query)
// and JSON body `APIClient` sends, answered with API.md's JSON. Errors come out as the `APIError`
// the server's status codes used to map to. `/auth/*` and `/debug/*` are gone (the login runs on the
// phone). Translation and summaries aren't routes: they run in AI.swift.

extension Aula {
    /// `verb` + `path` (+ query) + JSON body -> the answer's JSON.
    func handle(_ verb: String, _ path: String, body: Data?) async throws -> Data {
        do {
            let answer = try await route(verb.uppercased(), path, body)
            saveAttachments()
            return try J.data(answer)
        } catch {
            saveAttachments()
            throw Self.apiError(error)
        }
    }

    /// `GET /attachments/{id}`: the file's bytes, its name and content type.
    func attachment(_ id: String) async throws -> (Data, name: String, contentType: String) {
        do {
            // A URL Aula gave us, never one from the app.
            guard let ref = attachmentRef(id), Self.fileURLAllowed(ref.url), let url = URL(string: ref.url) else {
                throw APIError.notFound
            }
            let data: Data
            do {
                data = try await download(url).0
            } catch let Failure.rejected(status, _, _, _) {
                throw MapError.upstream("Could not download attachment: HTTP \(status)")
            }
            return (data, ref.name, Self.mimeType(ref.name) ?? "application/octet-stream")
        } catch {
            throw Self.apiError(error)
        }
    }

    static func apiError(_ error: Error) -> Error {
        switch error {
        case let e as APIError: return e
        case is CancellationError: return error
        case let MapError.badRequest(m): return APIError.http(400, m)
        case MapError.notFound: return APIError.notFound
        case let MapError.conflict(m): return APIError.conflict(m)
        case let MapError.upstream(m): return APIError.upstream(m)
        case Failure.authRequired: return APIError.authRequired
        case let Failure.transport(m): return APIError.transport(m)
        case Failure.rejected: return APIError.upstream(describe(error))
        case let e as LibraryError: return APIError.upstream(e.description)
        default: return APIError.upstream("\(type(of: error)): \(error)")
        }
    }

    // MARK: routing

    private enum Route {
        case today, pickup(String), sick(String), holiday(String), holidays, absences, absence(String), posts, save(String)
        case albums, photos(String), search, calendar, contactGroups, contactGroup(String)
        case attachment(String), threads, thread(String), reply(String), folders, folder(String)
    }

    private static func match(_ s: [String]) -> (Route, Set<String>)? {
        switch s.count {
        case 1:
            switch s[0] {
            case "today": return (.today, ["GET"])
            case "absences": return (.absences, ["GET", "POST"])
            case "holiday-requests": return (.holidays, ["GET"])
            case "posts": return (.posts, ["GET"])
            case "albums": return (.albums, ["GET"])
            case "search": return (.search, ["GET"])
            case "calendar": return (.calendar, ["GET"])
            case "threads": return (.threads, ["GET"])
            case "folders": return (.folders, ["GET", "POST"])
            default: return nil
            }
        case 2:
            switch s[0] {
            case "holiday-requests": return (.holiday(s[1]), ["GET", "POST"])
            case "absences": return (.absence(s[1]), ["PUT", "DELETE"])
            case "attachments": return (.attachment(s[1]), ["GET"])
            case "threads": return (.thread(s[1]), ["GET", "PATCH"])
            case "folders": return (.folder(s[1]), ["PATCH", "DELETE"])
            case "contacts" where s[1] == "groups": return (.contactGroups, ["GET"])
            default: return nil
            }
        case 3:
            switch (s[0], s[2]) {
            case ("children", "pickup"): return (.pickup(s[1]), ["GET", "PUT"])
            case ("children", "sick"): return (.sick(s[1]), ["POST", "DELETE"])
            case ("posts", "save"): return (.save(s[1]), ["POST", "DELETE"])
            case ("albums", "photos"): return (.photos(s[1]), ["GET"])
            case ("contacts", _) where s[1] == "groups": return (.contactGroup(s[2]), ["GET"])
            case ("threads", "reply"): return (.reply(s[1]), ["POST"])
            default: return nil
            }
        default: return nil
        }
    }

    private func route(_ verb: String, _ fullPath: String, _ body: Data?) async throws -> Any {
        let (path, query) = Self.splitQuery(fullPath)
        guard path.hasPrefix("/") else { throw APIError.notFound }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard !segments.contains(where: \.isEmpty), let (route, verbs) = Self.match(segments) else { throw APIError.notFound }
        guard verbs.contains(verb) else { throw APIError.http(405, "method_not_allowed") }
        let input = Input(query: query, body: body)

        switch (route, verb) {
        case (.today, _):
            return try await today()

        case let (.pickup(id), "GET"):
            let childId = try Input.pathInt(id, "child_id")
            let child = try findChild(try await profile(), childId)
            return try pickupOut(try await loadChildDay(child, withPeople: true))

        case let (.pickup(id), _):
            let childId = try Input.pathInt(id, "child_id")
            let b = try input.object()
            let time = try Input.str(b, "time")
            let by = try Input.str(b, "by")
            let note = try Input.optStr(b, "note")
            if !Self.validHHmm(time) { throw APIError.http(400, "time must be HH:mm") }
            let child = try findChild(try await profile(), childId)
            try await setPickup(child, when: time, by: by, note: note)
            return childOut(try await loadChildDay(child))

        case let (.sick(id), _):
            let childId = try Input.pathInt(id, "child_id")
            let child = try findChild(try await profile(), childId)
            try await setSick(child, verb == "POST")
            return childOut(try await loadChildDay(child))

        case let (.holiday(id), "GET"):
            return try await holidayRequest(try await profile(), id)

        case let (.holiday(id), _):
            let b = try input.object()
            var answers: [(Int, ChildAnswer)] = []
            let children = try Input.list(Input.required(b, "children"), "children")
            var parsed: [(Int, ChildAnswer)] = []
            for (i, c) in children.enumerated() {
                let loc = "children.\(i)"
                let c = try Input.object(c, loc)
                let cid = try Input.int(Input.required(c, "id", loc), "\(loc).id")
                var days: [DayAnswer] = []
                for (k, d) in try Input.list(Input.required(c, "days", loc), "\(loc).days").enumerated() {
                    let dl = "\(loc).days.\(k)"
                    let d = try Input.object(d, dl)
                    days.append(DayAnswer(
                        date: try Input.str(d, "date", dl), coming: try Input.bool(Input.required(d, "coming", dl), "\(dl).coming"),
                        entryTime: try Input.optStr(d, "entryTime", dl), exitTime: try Input.optStr(d, "exitTime", dl)))
                }
                let comment = c["comment"] == nil ? "" : try Input.str(c, "comment", loc)
                parsed.append((cid, ChildAnswer(days: days, comment: comment)))
            }
            for (cid, answer) in parsed {
                if answers.contains(where: { $0.0 == cid }) { throw APIError.http(400, "child \(cid) is listed twice") }
                answers.append((cid, answer))
            }
            let profile = try await profile()
            try await answerHolidayRequest(profile, id, answers)
            return try await holidayRequest(profile, id)

        case (.holidays, _):
            return try await openHolidayRequests(try await profile())

        case (.absences, "GET"):
            return try await absences(try await profile()).map(\.json)

        case let (.absence(id), "PUT"):
            let b = try input.object()
            let start = try Input.date(Input.required(b, "startDate"), "startDate")
            let end = try Input.date(Input.required(b, "endDate"), "endDate")
            let comment = b["comment"] == nil ? "" : try Input.str(b, "comment")
            try await updateAbsence(try await profile(), id, start, end, comment)
            return ["ok": true]

        case let (.absence(id), _):
            try await deleteAbsence(try await profile(), id)
            return ["ok": true]

        case (.absences, _):
            let b = try input.object()
            let ids = try Input.list(Input.required(b, "childIds"), "childIds").enumerated().map { try Input.int($1, "childIds.\($0)") }
            let start = try Input.date(Input.required(b, "startDate"), "startDate")
            let end = try Input.date(Input.required(b, "endDate"), "endDate")
            let comment = b["comment"] == nil ? "" : try Input.str(b, "comment")
            try await addAbsence(try await profile(), ids, start, end, comment)
            return ["ok": true]

        case (.posts, _):
            let page = try input.queryInt("page", default: 1, min: 1, max: 100)
            return try await posts(try await profile(), page: page)

        case (.calendar, _):
            let today = AulaTime.today()
            var (year, month) = (today.year, today.month)
            if let raw = input.query.last(where: { $0.0 == "month" })?.1 {
                let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
                // Digits only ("2026-+1" parses as Int), and a year whose next January `Day` can still hold.
                guard raw.count == 7, parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                      let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m), y <= 9998 else {
                    throw APIError.http(400, "month must be YYYY-MM")
                }
                (year, month) = (y, m)
            }
            return try await calendar(try await profile(), year: year, month: month)

        case (.albums, _):
            let page = try input.queryInt("page", default: 1, min: 1, max: 100)
            return try await albums(try await profile(), page: page)

        case let (.photos(id), _):
            let albumId = try Input.pathInt(id, "album_id")
            let page = try input.queryInt("page", default: 1, min: 1, max: 100)
            return try await albumPhotos(try await profile(), albumId, page: page)

        case (.search, _):
            let text = Py.strip(input.query.last(where: { $0.0 == "q" })?.1 ?? "")
            if text.isEmpty { throw APIError.http(400, "q is empty") }
            let type = input.query.last(where: { $0.0 == "type" })?.1 ?? "messages"
            let page = try input.queryInt("page", default: 1, min: 1, max: 100)
            return try await search(try await profile(), text, type: type, page: page)

        case (.contactGroups, _):
            return try await contactGroups(try await profile())

        case let (.contactGroup(id), _):
            return try await groupContacts(try Input.pathInt(id, "group_id"))

        case let (.save(id), _):
            let postId = try Input.pathInt(id, "post_id")
            let saved = verb == "POST"
            try await setBookmark(postId, saved)
            return ["saved": saved]

        case (.attachment, _):
            // Bytes, not JSON: `attachment(_:)`.
            throw APIError.notFound

        case (.threads, _):
            let page = try input.queryInt("page", default: 0, min: 0, max: 100)
            let folder = try input.queryOptInt("folder", min: 1)
            return try await threads(page: page, folder: folder, collect: true, register: true)

        case let (.thread(id), "PATCH"):
            let b = try input.object()
            var changes = ThreadChanges()
            if let v = b["muted"] { changes.muted = try Input.strictBool(v, "muted") }
            if let v = b["starred"] { changes.starred = try Input.strictBool(v, "starred") }
            if let v = b["folderId"] { changes.folderId = .some(J.isNone(v) ? nil : try Input.int(v, "folderId")) }
            if !Py.isDigits(id) { throw APIError.notFound }
            if changes.isEmpty { throw APIError.http(400, "nothing to change") }
            return try await updateThread(id, changes)

        case let (.thread(id), _):
            if !Py.isDigits(id) { throw APIError.notFound }
            return try await threadDetail(try await profile(), id)

        case let (.reply(id), _):
            let b = try input.object()
            let text = try Input.str(b, "text")
            let audience = try Input.required(b, "audience")
            guard let audience = audience as? String, audience == "everyone" || audience == "sender" else {
                throw APIError.http(400, "audience: Input should be 'everyone' or 'sender'")
            }
            let messageId = try Input.optStr(b, "messageId")
            if !Py.isDigits(id) { throw APIError.notFound }
            if Py.strip(text).isEmpty { throw APIError.http(400, "text is empty") }
            if audience == "sender" && (messageId ?? "").isEmpty { throw APIError.http(400, "messageId is required for audience sender") }
            let newId: String?
            if audience == "everyone" {
                newId = try await replyAll(id, text)
            } else {
                newId = try await replySender(try await profile(), id, messageId!, text)
            }
            return ["ok": true, "threadId": J.out(newId)]

        case (.folders, "GET"):
            return try await folders()

        case (.folders, _):
            let name = try Input.str(try input.object(), "name")
            _ = try Self.folderName(name)  // 400 before touching Aula
            return try await createFolder(name)

        case let (.folder(id), "PATCH"):
            let folderId = try Input.pathInt(id, "folder_id")
            let name = try Input.str(try input.object(), "name")
            _ = try Self.folderName(name)
            return try await renameFolder(folderId, name)

        case let (.folder(id), _):
            let folderId = try Input.pathInt(id, "folder_id")
            try await deleteFolder(folderId)
            return ["ok": true]

        default:
            throw APIError.http(405, "method_not_allowed")
        }
    }

    /// `GET /today`. A part failing is logged and left out; a dead session propagates.
    private func today() async throws -> JSONObject {
        let profile = try await profile()
        var days: [ChildDay] = []
        for child in profile.children { days.append(try await loadChildDay(child)) }
        let children = days.map(childOut)
        let childIds = profile.children.map(\.id)
        var attention = try await opt("holiday requests") { try await holidayRequests(childIds) } ?? []
        let threadRows = try await opt("threads") { try await threads() } ?? []
        attention += Self.unreadThreadsAttention(threadRows)
        let upcoming = try await opt("upcoming") { try await self.upcoming(profile.children) } ?? []
        let posts = try await opt("posts") { try await self.posts(profile) } ?? []
        return [
            "date": AulaTime.today().iso,
            "children": children,
            "attention": attention,
            "upcoming": upcoming,
            "posts": posts,
        ]
    }

    private static func splitQuery(_ s: String) -> (String, [(String, String)]) {
        guard let q = s.firstIndex(of: "?") else { return (s, []) }
        let pairs = s[s.index(after: q)...].split(separator: "&").map { part -> (String, String) in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let dec = { (x: Substring) in x.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
            return (dec(kv[0]), kv.count > 1 ? dec(kv[1]) : "")
        }
        return (String(s[..<q]), pairs)
    }
}

/// Request validation with the messages FastAPI/pydantic gave ("<where>: <what>"). Exact for what
/// `APIClient` can send wrong (page bounds); close for the rest.
private struct Input {
    var query: [(String, String)]
    var body: Data?

    static func bad(_ loc: String, _ msg: String) -> APIError { .http(400, loc.isEmpty ? msg : "\(loc): \(msg)") }
    static func join(_ base: String, _ key: String) -> String { base.isEmpty ? key : "\(base).\(key)" }

    func object() throws -> JSONObject {
        guard let body, !body.isEmpty else { throw Self.bad("", "Field required") }
        guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw Self.bad("", "JSON decode error")
        }
        return try Self.object(json, "")
    }

    static func object(_ v: Any, _ loc: String) throws -> JSONObject {
        guard let o = v as? JSONObject else { throw bad(loc, "Input should be a valid dictionary or object to extract fields from") }
        return o
    }

    static func required(_ o: JSONObject, _ key: String, _ base: String = "") throws -> Any {
        guard let v = o[key] else { throw bad(join(base, key), "Field required") }
        return v
    }

    static func str(_ o: JSONObject, _ key: String, _ base: String = "") throws -> String {
        guard let s = try required(o, key, base) as? String else { throw bad(join(base, key), "Input should be a valid string") }
        return s
    }

    static func optStr(_ o: JSONObject, _ key: String, _ base: String = "") throws -> String? {
        guard let v = o[key], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw bad(join(base, key), "Input should be a valid string") }
        return s
    }

    static func list(_ v: Any, _ loc: String) throws -> [Any] {
        guard let l = v as? [Any] else { throw bad(loc, "Input should be a valid list") }
        return l
    }

    /// pydantic's lax int: an int, a float with no fraction, or a numeric string.
    static func int(_ v: Any, _ loc: String) throws -> Int {
        if let i = J.int(v) { return i }
        if let b = J.bool(v) { return b ? 1 : 0 }
        if let n = v as? NSNumber {
            guard n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 9e18 else {
                throw bad(loc, "Input should be a valid integer, got a number with a fractional part")
            }
            return n.intValue
        }
        if let s = v as? String {
            guard let i = Int(Py.strip(s)) else { throw bad(loc, "Input should be a valid integer, unable to parse string as an integer") }
            return i
        }
        throw bad(loc, "Input should be a valid integer")
    }

    static func pathInt(_ s: String, _ name: String) throws -> Int { try int(s, "path.\(name)") }

    /// pydantic's lax bool.
    static func bool(_ v: Any, _ loc: String) throws -> Bool {
        if let b = J.bool(v) { return b }
        if let i = J.int(v), i == 0 || i == 1 { return i == 1 }
        if let s = (v as? String)?.lowercased() {
            if ["1", "on", "t", "true", "y", "yes"].contains(s) { return true }
            if ["0", "off", "f", "false", "n", "no"].contains(s) { return false }
            throw bad(loc, "Input should be a valid boolean, unable to interpret input")
        }
        throw bad(loc, "Input should be a valid boolean")
    }

    static func strictBool(_ v: Any, _ loc: String) throws -> Bool {
        guard let b = J.bool(v) else { throw bad(loc, "Input should be a valid boolean") }
        return b
    }

    static func date(_ v: Any, _ loc: String) throws -> Day {
        guard let s = v as? String, let d = Day.parse(s) else { throw bad(loc, "Input should be a valid date") }
        return d
    }

    func queryInt(_ name: String, default def: Int, min: Int, max: Int) throws -> Int {
        guard let raw = query.last(where: { $0.0 == name })?.1 else { return def }
        return try Self.bounded(Self.int(raw, "query.\(name)"), name, min: min, max: max)
    }

    func queryOptInt(_ name: String, min: Int) throws -> Int? {
        guard let raw = query.last(where: { $0.0 == name })?.1 else { return nil }
        return try Self.bounded(Self.int(raw, "query.\(name)"), name, min: min, max: nil)
    }

    static func bounded(_ v: Int, _ name: String, min: Int, max: Int?) throws -> Int {
        if v < min { throw bad("query.\(name)", "Input should be greater than or equal to \(min)") }
        if let max, v > max { throw bad("query.\(name)", "Input should be less than or equal to \(max)") }
        return v
    }
}
