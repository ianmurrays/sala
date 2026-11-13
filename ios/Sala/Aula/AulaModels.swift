import Foundation

// The aula library's models (aula/models/*.py), only the fields Sala's mapping reads, parsed the
// way the library's `from_dict`s parse them. Sendable values, so they can come back from
// concurrent reads; raw JSON stays inside the actor.

struct ParseError: Error { var what: String }

/// PresenceState (models/presence.py): Aula uses one enum for reading and writing a status.
enum PresenceState: Int, Sendable {
    case notPresent = 0, sick, reportedAbsent, present, fieldtrip, sleeping, spareTimeActivity, physicalPlacement, checkedOut, notArrived

    var displayName: String {
        switch self {
        case .notPresent: "Not Present"
        case .sick: "Sick"
        case .reportedAbsent: "Reported Absent"
        case .present: "Present"
        case .fieldtrip: "Field Trip"
        case .sleeping: "Sleeping"
        case .spareTimeActivity: "Spare Time Activity"
        case .physicalPlacement: "Physical Placement"
        case .checkedOut: "Checked Out"
        case .notArrived: "Not Arrived"
        }
    }

    /// `PresenceState(value)`; nil for a value the enum doesn't have.
    static func from(_ v: Any?) -> PresenceState? {
        guard let n = v as? NSNumber, n.doubleValue == n.doubleValue.rounded() else { return nil }
        return PresenceState(rawValue: n.intValue)
    }
}

/// Child (models/child.py). `id` is the institution profile id, the one every call takes.
struct AulaChild: Sendable {
    var id: Int
    var name: String?
    var institutionName: String
    var profilePicture: String
    var institutionCode: String?
    /// `has_custody_or_extended_access`: nil when Aula didn't say.
    var hasCustodyOrExtendedAccess: Bool?
    /// `institutionProfile.metadata` from the raw row (the group name).
    var metadata: String?

    /// `Child.from_dict`; throws where it raises KeyError (no id, profileId or name).
    init(_ data: JSONObject) throws {
        guard J.has(data, "id"), J.has(data, "profileId"), J.has(data, "name"), let id = J.int(data["id"]) else {
            throw ParseError(what: "child")
        }
        self.id = id
        name = J.str(J.get(data, "name"))
        institutionName = J.str(J.getIn(data, "institutionProfile.institutionName")) ?? ""
        profilePicture = J.str(J.getIn(data, "profilePicture.url")) ?? ""
        let code = J.getIn(data, "institutionProfile.institutionCode")
        institutionCode = code.map(J.pyStr)
        hasCustodyOrExtendedAccess = J.bool(J.get(data, "hasCustodyOrExtendedAccess"))
        metadata = J.str(J.getIn(data, "institutionProfile.metadata"))
    }
}

/// Profile (api_client.get_profile).
struct AulaProfile: Sendable {
    var children: [AulaChild]
    var institutionProfileIds: [Int]
    /// mapping.guardian_profile_ids: the user's own institution profile ids.
    var guardianIds: Set<Int>
}

/// DailyOverview (models/daily_overview.py).
struct DailyOverview: Sendable {
    var status: PresenceState?
    var institutionName: String?
    var pictureURL: String?
    var hasInstitutionProfile: Bool
    var mainGroupName: String?
    var checkInTime: String?
    var checkOutTime: String?
    var entryTime: String?
    var exitTime: String?
    var exitWith: String?
    var comment: String?

    init(_ d: JSONObject) {
        status = PresenceState.from(J.get(d, "status"))
        let inst = J.dict(J.get(d, "institutionProfile"))
        hasInstitutionProfile = inst != nil
        institutionName = J.str(J.get(inst, "institutionName"))
        // InstitutionProfile: `profilePicture or {}`, a ProfilePicture only when that is non-empty.
        pictureURL = J.str(J.get(J.dict(J.get(inst, "profilePicture")), "url"))
        mainGroupName = J.str(J.get(J.dict(J.get(d, "mainGroup")), "name"))
        checkInTime = J.str(J.get(d, "checkInTime"))
        checkOutTime = J.str(J.get(d, "checkOutTime"))
        entryTime = J.str(J.get(d, "entryTime"))
        exitTime = J.str(J.get(d, "exitTime"))
        exitWith = J.str(J.get(d, "exitWith"))
        comment = J.str(J.get(d, "comment"))
    }
}

/// DayTemplate (models/presence_template.py).
struct DayTemplate: Sendable {
    var id: Int?
    var byDate: String?
    var repeatPattern: String?
    var isOnVacation: Bool
    var entryTime: String?
    var exitTime: String?
    var exitWith: String?
    var comment: String?

    init(_ d: JSONObject) {
        id = J.int(J.get(d, "id"))
        byDate = J.str(J.get(d, "byDate"))
        repeatPattern = J.str(J.get(d, "repeatPattern"))
        isOnVacation = J.truthy(J.get(d, "isOnVacation", default: false))
        entryTime = J.str(J.get(d, "entryTime"))
        exitTime = J.str(J.get(d, "exitTime"))
        exitWith = J.str(J.get(d, "exitWith"))
        comment = J.str(J.get(d, "comment"))
    }
}

/// PresenceWeekTemplate.
struct PresenceWeekTemplate: Sendable {
    var institutionProfileId: Int?
    var dayTemplates: [DayTemplate]

    /// Throws where `from_dict` raises (dayTemplates null, or not all dicts): the week is skipped.
    init(_ d: JSONObject) throws {
        let ip = J.get(d, "institutionProfile")
        institutionProfileId = J.truthy(ip) ? J.int(J.get(ip, "id")) : nil
        let raw = J.get(d, "dayTemplates", default: [Any]())
        guard let list = raw as? [Any] else { throw ParseError(what: "dayTemplates") }
        dayTemplates = try list.map {
            guard let day = $0 as? JSONObject else { throw ParseError(what: "dayTemplate") }
            return DayTemplate(day)
        }
    }
}

/// PresenceModule / PresenceModulePermission (models/presence.py), wire values from the portal bundle.
enum PresenceModule: String { case reportSick = "report_sick", vacation }
enum PresenceModulePermission: String { case deactivated, readable, editable }

/// PresenceConfiguration (models/presence_registration.py).
struct PresenceConfiguration: Sendable {
    var childId: Int?
    /// dashboard -> module -> permission, as wire strings.
    var modulePermissions: [String: [String: String]]

    init(_ d: JSONObject) {
        childId = J.int(J.or(J.get(d, "uniStudentId"), J.get(d, "childId")))
        let config = J.dict(J.or(J.get(d, "presenceConfiguration"), nil)) ?? [:]
        var perms: [String: [String: String]] = [:]
        for setting in J.list(J.get(config, "dashboardModuleSettings")) ?? [] {
            guard let setting = setting as? JSONObject else { continue }
            let dashboard = J.get(setting, "presenceDashboardContext")
            guard J.truthy(dashboard), let modules = J.list(J.get(setting, "presenceModules")) else { continue }
            let key = J.pyStr(dashboard)
            var byModule = perms[key] ?? [:]
            for module in modules {
                guard let module = module as? JSONObject else { continue }
                let type = J.get(module, "moduleType")
                if J.truthy(type) {
                    let p = J.get(module, "permission")
                    byModule[J.pyStr(type)] = J.truthy(p) ? J.pyStr(p) : ""
                }
            }
            perms[key] = byModule
        }
        modulePermissions = perms
    }

    /// The guardian dashboard's permission for `module`, nil when Aula reported none or one we don't know.
    func permission(_ module: PresenceModule) -> PresenceModulePermission? {
        modulePermissions["guardian_dashboard"]?[module.rawValue].flatMap(PresenceModulePermission.init(rawValue:))
    }

    /// True only when Aula reports the module as editable: the portal gates its write buttons on this.
    func canEdit(_ module: PresenceModule) -> Bool { permission(module) == .editable }
}

/// ChildPickupResponsibles (models/pickup_responsible.py): related persons, then saved suggestions.
struct ChildPickupResponsibles: Sendable {
    struct Person: Sendable {
        /// nil = Python None (an explicit null name).
        var name: String?
        var relation: String?
    }

    /// nil = an explicit null `uniStudentId`.
    var uniStudentId: Int?
    var persons: [Person]

    init(_ d: JSONObject) throws {
        let uni = J.get(d, "uniStudentId", default: 0)
        uniStudentId = J.int(uni)
        var persons: [Person] = []
        guard let related = J.get(d, "relatedPersons", default: [Any]()) as? [Any],
              let suggestions = J.get(d, "pickupSuggestions", default: [Any]()) as? [Any] else { throw ParseError(what: "pickup") }
        for rp in related {
            guard let rp = rp as? JSONObject else { throw ParseError(what: "pickup person") }
            let name = J.get(rp, "name", default: "")
            persons.append(Person(name: name.map(J.pyStr), relation: J.get(rp, "relation").map(J.pyStr)))
        }
        for ps in suggestions {
            guard let ps = ps as? JSONObject else { throw ParseError(what: "pickup suggestion") }
            let name = J.get(ps, "pickUpName", default: "")
            persons.append(Person(name: name.map(J.pyStr), relation: nil))
        }
        self.persons = persons
    }
}

/// VacationRegistration (models/vacation_registration.py), one row per child.
struct VacationRegistration: Sendable {
    var id: Int?
    var childId: Int?
    var childName: String?
    var title: String?
    var startDate: String?
    var endDate: String?
    var responseId: Int?
    var responseDeadline: String?
    var noteToGuardian: String
    var isMissingAnswer: Bool
    var isPresenceTimesRequired: Bool

    init(_ d: JSONObject, child: JSONObject) {
        id = J.int(J.get(d, "vacationRegistrationId", default: 0))
        childId = J.int(J.get(child, "id", default: 0))
        childName = J.str(J.get(child, "name", default: ""))
        title = J.str(J.get(d, "title", default: ""))
        startDate = J.str(J.get(d, "startDate"))
        endDate = J.str(J.get(d, "endDate"))
        responseId = J.int(J.get(d, "responseId", default: 0))
        responseDeadline = J.str(J.get(d, "responseDeadline"))
        noteToGuardian = J.str(J.or(J.get(d, "noteToGuardian", default: ""), "")) ?? ""
        isMissingAnswer = J.truthy(J.get(d, "isMissingAnswer", default: false))
        isPresenceTimesRequired = J.truthy(J.get(d, "isPresenceTimesRequired", default: false))
    }
}

/// Attachment (models/attachment.py): `file` is hoisted out of a media item.
struct AulaAttachment: Sendable {
    var name: String
    var fileURL: String?
    var fileName: String
    var hasFile: Bool
    var linkURL: String?
    var hasLink: Bool
    var mediaType: String?

    init(_ d: JSONObject) {
        let media = J.dict(J.or(J.get(d, "media"), nil)) ?? [:]
        mediaType = media.isEmpty ? nil : (J.str(J.or(J.get(media, "mediaType"), "")) ?? "")
        let file = J.dict(J.or(J.get(media, "file"), J.or(J.get(d, "file"), nil))) ?? [:]
        hasFile = !file.isEmpty
        fileName = J.str(J.or(J.get(file, "name"), "")) ?? ""
        fileURL = J.str(J.get(file, "url"))
        let link = J.dict(J.or(J.get(d, "link"), nil)) ?? [:]
        hasLink = !link.isEmpty
        linkURL = J.str(J.get(link, "url"))
        let linkName = J.str(J.or(J.get(link, "name"), "")) ?? ""
        let document = J.dict(J.or(J.get(d, "document"), nil)) ?? [:]
        var name = J.str(J.or(J.get(d, "name"), "")) ?? ""
        if name.isEmpty {
            if hasFile {
                name = fileName
            } else if hasLink {
                name = linkName
            } else if !document.isEmpty {
                name = J.str(J.or(J.get(document, "title"), "")) ?? ""
            }
        }
        self.name = name
    }

    /// `parse_attachments`: dicts only.
    static func parse(_ raw: Any?) -> [AulaAttachment] {
        (J.list(raw) ?? []).compactMap { ($0 as? JSONObject).map(AulaAttachment.init) }
    }
}

/// Post (models/post.py) with its owner (ProfileReference).
struct AulaPost: Sendable {
    var id: Int
    var title: String?
    var contentHTML: String
    var timestamp: String?
    var ownerFullName: String?
    var ownerRole: String?
    var ownerInstitutionName: String?
    /// mapping.picture_id's input: the profilePicture dict's url, or the value itself when it's a string.
    var ownerPicture: String?
    var isImportant: Bool
    /// posts.getAllPosts rows carry isBookmarked (bundle 10.*.js reads post.isBookmarked).
    var isBookmarked: Bool
    var attachments: [AulaAttachment]

    /// Throws where `from_dict` raises KeyError (no id, or an owner without id/profileId).
    init(_ d: JSONObject) throws {
        guard J.has(d, "id"), let id = J.int(d["id"]) else { throw ParseError(what: "post") }
        let owner = J.dict(J.or(J.get(d, "ownerProfile"), nil)) ?? [:]
        guard J.has(owner, "id"), J.has(owner, "profileId") else { throw ParseError(what: "post owner") }
        self.id = id
        title = J.str(J.get(d, "title", default: ""))
        contentHTML = J.str(J.getIn(d, "content.html")) ?? ""
        let stamp = J.get(d, "timestamp")
        timestamp = AulaTime.parse(stamp) == nil ? nil : J.str(stamp)
        ownerFullName = J.str(J.get(owner, "fullName", default: ""))
        ownerRole = J.str(J.get(owner, "role", default: ""))
        ownerInstitutionName = J.str(J.getIn(owner, "institution.institutionName")) ?? ""
        let picture = J.get(owner, "profilePicture")
        ownerPicture = picture is JSONObject ? J.str(J.getIn(picture, "url")) : J.str(picture)
        isImportant = J.truthy(J.get(d, "isImportant", default: false))
        isBookmarked = J.truthy(J.get(d, "isBookmarked"))
        attachments = AulaAttachment.parse(J.get(d, "attachments"))
    }
}

/// MessageFolder (models/message_folder.py), plus whether it's one of the user's own ("normal").
struct MessageFolder: Sendable {
    var id: Int?
    var name: String?
    var isNormal: Bool

    init(_ d: JSONObject) {
        id = J.int(d["id"])
        name = J.str(J.get(d, "name", default: ""))
        isNormal = J.eq(J.get(d, "type", default: "normal"), "normal")
    }
}
