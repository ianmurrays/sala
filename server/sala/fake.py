"""Fake Aula at the HTTP layer (``SALA_FAKE=1``).

``FakeAula`` implements the library's ``HttpClient`` protocol, so the real
``AulaApiClient`` and all of Sala's mapping code run on top of it unchanged.
Requests are routed by the ``method=`` query parameter and answered with
fixture JSON in Aula's envelope. Every write is recorded in ``writes`` and
reads reflect writes.

The fixture field names follow what the library models parse and what the
portal bundle reads; they are not captured live responses.
"""

import itertools
import struct
import zlib
from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import parse_qs, urlsplit

from aula.const import CSRF_TOKEN_COOKIE
from aula.http import HttpResponse
from aula.utils.dates import aula_today

from .mapping import TZ

GUARDIAN_IP = 1001  # Jonas's institution profile (his mailbox)
OTHER_GUARDIAN_IP = 1002
CHILD_ID = 2001  # Oskar's institution profile id (Child.id)
INSTITUTION_CODE = "999001"
INSTITUTION_NAME = "Børnehuset"
GROUP = {"id": 3001, "name": "Stue", "shortName": "Stue"}
FAKE_OTP = "482915"


def fake_qr_codes():
    """Two QR halves shaped like MitID's (see aula/auth/browser_client.py)."""
    import qrcode

    codes = []
    for part, h in ((1, "a1b2c3d4e5f6a7b8"), (2, "c9d0e1f2a3b4c5d6")):
        q = qrcode.QRCode(border=1)
        q.add_data(f'{{"v":1,"p":{part},"t":2,"h":"{h}","uc":1}}')
        q.make()
        codes.append(q)
    return codes

# On an aula.dk subdomain so the attachment host allowlist applies unchanged.
FILES_BASE = "https://fake-files.aula.dk/files/"
PDF_URL = FILES_BASE + "praesentation.pdf"
PNG_URL = FILES_BASE + "skovtur.png"

# What a fake MitID login hands to create_client().
FAKE_TOKEN_DATA = {"tokens": {"access_token": "fake-access-token"}, "cookies": {}}


def _ok(data: Any) -> HttpResponse:
    return HttpResponse(status_code=200, data={"status": {"code": 0, "message": "OK"}, "data": data})


def _now() -> datetime:
    return datetime.now(TZ).replace(microsecond=0)


def _ts(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def _person(ip_id: int, name: str, metadata: str, role: str = "employee") -> dict:
    return {
        "mailBoxOwner": {"id": ip_id, "mailBoxOwnerType": "institutionProfile", "isDeactivated": False},
        "fullName": name,
        "metadata": metadata,
        "profileId": ip_id + 10000,
        "role": role,
        "shortName": "".join(p[0] for p in name.split()),
        "answerDirectlyName": name,
        "institutionCode": INSTITUTION_CODE,
    }


ME = _person(GUARDIAN_IP, "Jonas Hansen", "Oskar (Far)", "guardian")
MARIA = _person(OTHER_GUARDIAN_IP, "Maria Hansen", "Oskar (Mor)", "guardian")
ANNE = _person(1501, "Anne Holm", "Leder")
METTE = _person(1502, "Mette Lund", "Pædagog, Stue")
KASPER = _person(1503, "Kasper Berg", "Pædagogmedhjælper, Stue")


def _png() -> bytes:
    w = h = 32
    rows = b"".join(
        b"\x00" + b"".join(bytes((40 + x * 6, 120 + y * 3, 90)) for x in range(w)) for y in range(h)
    )

    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def _pdf() -> bytes:
    text = b"BT /F1 18 Tf 24 70 Td (Velkommen til vinteren i Boernehuset) Tj ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 144] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (i, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


FILES = {PDF_URL: _pdf(), PNG_URL: _png(), FILES_BASE + "madordning.pdf": _pdf()}


class FakeAula:
    """An in-memory Aula that speaks the library's HttpClient protocol."""

    def __init__(self) -> None:
        self.writes: list[dict[str, Any]] = []
        self.session_expired = False  # tests: answer everything with sub-code 23
        self.forbidden: set[str] = set()  # tests: methods (or "*") answered with HTTP 403
        self._ids = itertools.count(1)
        now = _now()
        today = aula_today()
        self.status = 3  # PresenceState.PRESENT
        self.check_in: str | None = "07:40"  # kept when a sick report is made
        self.check_out: str | None = None
        # A repeating weekly template covers every weekday; a single-day
        # override (written by updatePresenceTemplate without an id) wins.
        self.weekly_template = {
            "id": 7001,
            "repeatPattern": "weekly",
            "repeatFromDate": (today - timedelta(days=60)).isoformat(),
            "repeatToDate": None,
            "isOnVacation": False,
            "activityType": 0,
            "entryTime": "07:45",
            "exitTime": "16:00",
            "exitWith": "Jonas Hansen (Far)",
            "comment": "Har madpakke med",
            "spareTimeActivity": None,
        }
        self.overrides: dict[str, dict] = {}  # byDate -> day template
        self.posts = self._posts(now)
        self.threads, self.messages = self._threads(now)
        self.vacations = self._vacations(today)

    # --- HttpClient protocol -------------------------------------------------

    async def request(
        self,
        method: str,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        params: dict[str, Any] | None = None,
        json: Any | None = None,
    ) -> HttpResponse:
        query: dict[str, Any] = {k: v if len(v) > 1 else v[0] for k, v in parse_qs(urlsplit(url).query).items()}
        query.update(params or {})
        query.pop("access_token", None)
        api_method = str(query.get("method", ""))
        if api_method in self.forbidden or "*" in self.forbidden:
            return HttpResponse(status_code=403, data={"status": {"code": 403, "message": "Forbidden"}, "data": None})
        if self.session_expired:
            return HttpResponse(status_code=200, data={"status": {"code": 448, "subCode": 23}, "data": None})
        handler = getattr(self, "_" + api_method.replace(".", "_"), None)
        if handler is None:
            return HttpResponse(status_code=404, data={"status": {"code": 404}, "data": None})
        if method.lower() == "post" and api_method not in _POST_READS:
            self.writes.append({"method": api_method, "payload": json})
        return handler(query, json)

    async def download_bytes(self, url: str) -> bytes:
        return FILES[url]

    def get_cookie(self, name: str) -> str | None:
        return "fake-csrf" if name == CSRF_TOKEN_COOKIE else None

    async def close(self) -> None:
        return None

    def writes_for(self, api_method: str) -> list[Any]:
        return [w["payload"] for w in self.writes if w["method"] == api_method]

    # --- profiles ------------------------------------------------------------

    def _profiles_getProfilesByLogin(self, q, body):
        return _ok(
            {
                "profiles": [
                    {
                        "profileId": 501,
                        "displayName": "Jonas Hansen",
                        "institutionProfiles": [
                            {
                                "id": GUARDIAN_IP,
                                "institutionCode": INSTITUTION_CODE,
                                "institutionName": INSTITUTION_NAME,
                                "role": "guardian",
                            }
                        ],
                        "children": [
                            {
                                "id": CHILD_ID,
                                "profileId": 601,
                                "name": "Oskar",
                                "userId": "oskar01",
                                "hasCustodyOrExtendedAccess": True,
                                "institutionProfile": {
                                    "institutionName": INSTITUTION_NAME,
                                    "institutionCode": INSTITUTION_CODE,
                                    "metadata": "Stue",
                                },
                                "profilePicture": None,
                            }
                        ],
                    }
                ]
            }
        )

    def _profiles_getProfileContext(self, q, body):
        return _ok({"institutionProfile": {"id": GUARDIAN_IP}, "institutions": []})

    def _profiles_keepAlive(self, q, body):
        return _ok(True)

    # --- presence ------------------------------------------------------------

    def _template_for(self, day: str) -> dict:
        return self.overrides.get(day) or {**self.weekly_template, "byDate": day, "dayOfWeek": date.fromisoformat(day).isoweekday()}

    def _presence_getDailyOverview(self, q, body):
        tmpl = self._template_for(aula_today().isoformat())
        return _ok(
            [
                {
                    "id": 88001,
                    "institutionProfile": {
                        "id": CHILD_ID,
                        "profileId": 601,
                        "name": "Oskar",
                        "institutionCode": INSTITUTION_CODE,
                        "institutionName": INSTITUTION_NAME,
                        "role": "child",
                    },
                    "mainGroup": {**GROUP, "institutionCode": INSTITUTION_CODE},
                    "status": self.status,
                    "location": None,
                    "sleepIntervals": [],
                    "checkInTime": self.check_in,
                    "checkOutTime": self.check_out,
                    "entryTime": tmpl["entryTime"],
                    "exitTime": tmpl["exitTime"],
                    "exitWith": tmpl["exitWith"],
                    "comment": tmpl["comment"],
                }
            ]
        )

    def _presence_getPresenceTemplates(self, q, body):
        start = date.fromisoformat(q["fromDate"])
        end = date.fromisoformat(q["toDate"])
        days = [(start + timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]
        return _ok(
            {
                "presenceWeekTemplates": [
                    {
                        "institutionProfile": {"id": CHILD_ID, "name": "Oskar", "institutionCode": INSTITUTION_CODE},
                        "dayTemplates": [self._template_for(d) for d in days],
                    }
                ]
            }
        )

    def _presence_updatePresenceTemplate(self, q, body):
        activity = body["presenceActivity"]
        pickup = activity.get("pickup") or {}
        day = body["byDate"]
        existing = self.overrides.get(day)
        if body.get("id") not in (None, self.weekly_template["id"]) or existing:
            template_id = existing["id"] if existing else body["id"]
        else:
            template_id = 7100 + next(self._ids)
        repeat = body.get("repeatPattern", "never")
        if repeat != "never":
            raise AssertionError("the fake only models single-day writes")
        self.overrides[day] = {
            "id": template_id,
            "byDate": day,
            "dayOfWeek": date.fromisoformat(day).isoweekday(),
            "repeatPattern": "never",
            "isOnVacation": False,
            "activityType": activity.get("activityType"),
            "entryTime": pickup.get("entryTime"),
            "exitTime": pickup.get("exitTime"),
            "exitWith": pickup.get("exitWith"),
            "comment": body.get("comment", ""),
            "spareTimeActivity": None,
        }
        return _ok(None)

    def _presence_updateStatusByInstitutionProfileIds(self, q, body):
        self.status = body["status"]
        return _ok(True)

    def _presence_getPickupResponsibles(self, q, body):
        return _ok(
            [
                {
                    "uniStudentId": CHILD_ID,
                    "relatedPersons": [
                        {"name": "Jonas Hansen", "relation": "Far", "institutionProfileId": GUARDIAN_IP},
                        {"name": "Maria Hansen", "relation": "Mor", "institutionProfileId": OTHER_GUARDIAN_IP},
                    ],
                    "pickupSuggestions": [{"id": 81, "pickUpName": "Mormor Lis"}],
                }
            ]
        )

    def _presence_getPresenceConfigurationByChildIds(self, q, body):
        modules = [
            {"moduleType": m, "permission": "editable"}
            for m in ("pickup_times", "drop_off_time", "report_sick", "vacation", "pickup_type")
        ]
        return _ok(
            [
                {
                    "uniStudentId": CHILD_ID,
                    "presenceConfiguration": {
                        "institution": {"institutionCode": INSTITUTION_CODE, "name": INSTITUTION_NAME},
                        "pickup": True,
                        "goHomeWith": False,
                        "selfDecider": False,
                        "dashboardModuleSettings": [
                            {"presenceDashboardContext": "guardian_dashboard", "presenceModules": modules}
                        ],
                    },
                }
            ]
        )

    def _presence_getOpeningHoursByInstitutionCodes(self, q, body):
        start = date.fromisoformat(q["startDate"])
        end = date.fromisoformat(q["endDate"])
        days = [start + timedelta(days=i) for i in range((end - start).days + 1)]
        return _ok(
            {
                "openingHoursOverviewDto": [
                    {
                        "institutionCode": INSTITUTION_CODE,
                        "openingHoursDto": [
                            {"date": d.isoformat(), "type": "general_opening_hours", "openTime": "06:30", "closeTime": "16:45"}
                            if d.isoweekday() < 6
                            else {"date": d.isoformat(), "type": "closed_day", "openTime": None, "closeTime": None}
                            for d in days
                        ],
                    }
                ]
            }
        )

    @staticmethod
    def _vacations(today: date) -> list[dict]:
        dec = date(today.year if today.month < 12 or today.day < 21 else today.year + 1, 12, 21)
        feb = date(dec.year + 1, 2, 16)
        return [
            {
                "vacationRegistrationId": 55,
                "title": "Juleferie",
                "startDate": dec.isoformat(),
                "endDate": (dec + timedelta(days=2)).isoformat(),
                "responseId": 0,
                "responseDeadline": (today + timedelta(days=1)).isoformat(),
                "noteToGuardian": "Giv besked om Oskar holder fri.",
                "isEditable": True,
                "isMissingAnswer": True,
            },
            {
                "vacationRegistrationId": 56,
                "title": "Vinterferie",
                "startDate": feb.isoformat(),
                "endDate": (feb + timedelta(days=4)).isoformat(),
                "responseId": 0,
                "responseDeadline": (today + timedelta(days=12)).isoformat(),
                "noteToGuardian": "",
                "isEditable": True,
                "isMissingAnswer": True,
            },
            {
                "vacationRegistrationId": 54,
                "title": "Efterårsferie",
                "startDate": (today - timedelta(days=20)).isoformat(),
                "endDate": (today - timedelta(days=16)).isoformat(),
                "responseId": 9,
                "responseDeadline": (today - timedelta(days=30)).isoformat(),
                "isEditable": False,
                "isMissingAnswer": False,
            },
        ]

    def _presence_getVacationRegistrationsByChildren(self, q, body):
        return _ok([{"child": {"id": CHILD_ID, "name": "Oskar"}, "vacationRegistrations": self.vacations}])

    # --- debug: new items for push testing -----------------------------------

    def add_message(self, tid: int, sender: dict, html: str) -> str:
        """A new incoming message in an existing thread (unread)."""
        msg = self._msg(f"m{tid}-n{next(self._ids)}", sender, html, _now())
        self.messages[tid].insert(0, msg)
        self.threads[tid]["read"] = False
        self._refresh_latest(tid)
        return msg["id"]

    def add_direct_message(self) -> int:
        """Mette writes in 9105, a thread between Jonas and Mette only."""
        self.add_message(9105, METTE, "<p>Oskar spurgte efter dig i dag.</p>")
        return 9105

    def add_important_post(self) -> int:
        pid = 500 + next(self._ids)
        base = self.posts[401]
        self.posts[pid] = {
            **base,
            "id": pid,
            "title": "Børnehuset lukker tidligt på fredag",
            "content": {"html": "<p>Vi lukker kl. 14 på grund af personalemøde.</p>"},
            "timestamp": _ts(_now()),
            "isImportant": True,
            "isBookmarked": False,
            "attachments": [],
        }
        return pid

    def add_holiday_request(self, deadline_days: int = 1) -> int:
        rid = 60 + next(self._ids)
        start = aula_today() + timedelta(days=30)
        self.vacations.append(
            {
                "vacationRegistrationId": rid,
                "title": "Sommerferie",
                "startDate": start.isoformat(),
                "endDate": (start + timedelta(days=2)).isoformat(),
                "responseId": 0,
                "responseDeadline": (aula_today() + timedelta(days=deadline_days)).isoformat(),
                "noteToGuardian": "",
                "isEditable": True,
                "isMissingAnswer": True,
            }
        )
        return rid

    # --- calendar ------------------------------------------------------------

    def _calendar_getImportantDates(self, q, body):
        start = datetime.combine(aula_today() + timedelta(days=5), datetime.min.time(), TZ).replace(hour=9)
        return _ok(
            [
                {
                    "id": 5001,
                    "title": "Juleklip i Stue",
                    "type": "event",
                    "startDateTime": _ts(start),
                    "endDateTime": _ts(start + timedelta(hours=2)),
                    "allDay": False,
                },
                {
                    "id": 5002,
                    "title": "Personaledag – Børnehuset lukket",
                    "type": "event",
                    "startDateTime": _ts(start + timedelta(days=9)),
                    "endDateTime": _ts(start + timedelta(days=9, hours=8)),
                    "allDay": True,
                },
            ]
        )

    def _calendar_getBirthdayEventsForInstitutions(self, q, body):
        bday = aula_today() + timedelta(days=8)
        return _ok(
            [
                {
                    "institutionProfileId": 2002,
                    "name": "Ida Jensen",
                    "birthday": bday.replace(year=bday.year - 5).isoformat(),
                    "mainGroupName": "Stue",
                    "institutionCode": INSTITUTION_CODE,
                }
            ]
        )

    # --- posts ---------------------------------------------------------------

    @staticmethod
    def _posts(now: datetime) -> dict[int, dict]:
        def owner(p: dict, pid: int) -> dict:
            first, _, last = p["fullName"].partition(" ")
            return {
                "id": pid,
                "profileId": pid + 10000,
                "firstName": first,
                "lastName": last,
                "fullName": p["fullName"],
                "shortName": p["shortName"],
                "role": "employee",
                "institution": {"institutionName": INSTITUTION_NAME, "institutionCode": INSTITUTION_CODE},
            }

        def file_att(att_id: int, name: str, url: str) -> dict:
            return {"id": att_id, "status": "available", "file": {"id": att_id, "name": name, "url": url, "scanningStatus": "Clean"}}

        posts = [
            {
                "id": 401,
                "title": "Velkommen til vinteren",
                "content": {"html": "<p>Kære forældre,</p><p>Vinteren er på vej. Husk <b>flyverdragt</b> og ekstra vanter.</p><p>Se præsentationen fra forældremødet.</p>"},
                "timestamp": _ts(now - timedelta(hours=3)),
                "ownerProfile": owner(ANNE, 1501),
                "isImportant": True,
                "importantFrom": _ts(now - timedelta(days=1)),
                "importantTo": _ts(now + timedelta(days=7)),
                "isBookmarked": False,
                "attachments": [file_att(9901, "Præsentation.pdf", PDF_URL)],
            },
            {
                "id": 402,
                "title": "Billeder fra skovturen",
                "content": {"html": "<p>Vi havde en dejlig tur i skoven i går. Her er et af billederne.</p>"},
                "timestamp": _ts(now - timedelta(days=1, hours=2)),
                "ownerProfile": owner(METTE, 1502),
                "isImportant": False,
                "isBookmarked": False,
                "attachments": [
                    {
                        "id": 9902,
                        "status": "available",
                        "media": {
                            "title": "Skovtur",
                            "mediaType": "image",
                            "thumbnailUrl": PNG_URL,
                            "file": {"id": 9902, "name": "skovtur.png", "url": PNG_URL},
                        },
                    }
                ],
            },
            {
                "id": 403,
                "title": "Husk navn i tøjet",
                "content": {"html": "<p>Vi har en stor bunke glemt tøj. Skriv venligst navn i alt tøj.</p>"},
                "timestamp": _ts(now - timedelta(days=3)),
                "ownerProfile": owner(KASPER, 1503),
                "isImportant": False,
                "isBookmarked": True,
                # A cloud-drive link: shown as kind "link", never fetched by the server.
                "attachments": [
                    {"id": 9904, "status": "available", "link": {"service": "onedrive", "name": "Tøjliste", "url": "https://onedrive.live.com/view?id=fake"}}
                ],
            },
        ]
        for p in posts:
            p.update(allowComments=True, isPublished=True, commentCount=0, sharedWithGroups=[GROUP])
        return {p["id"]: p for p in posts}

    def _posts_getAllPosts(self, q, body):
        posts = sorted(self.posts.values(), key=lambda p: p["timestamp"] or "", reverse=True)
        return _ok({"posts": posts})

    def _posts_getById(self, q, body):
        return _ok(self.posts.get(int(q["id"])))

    def _posts_bookmark(self, q, body):
        self.posts[int(body["postId"])]["isBookmarked"] = True
        return _ok(None)

    def _posts_unbookmark(self, q, body):
        self.posts[int(body["postId"])]["isBookmarked"] = False
        return _ok(None)

    # --- messaging -----------------------------------------------------------

    @staticmethod
    def _msg(mid: str, sender: dict, html: str, at: datetime, attachments: list | None = None) -> dict:
        return {
            "id": mid,
            "messageType": "Message",
            "text": {"html": html},
            "sendDateTime": _ts(at),
            "sender": sender,
            "attachments": attachments or [],
            "canReplyToMessage": True,
        }

    def _threads(self, now: datetime) -> tuple[dict[int, dict], dict[int, list[dict]]]:
        others = [
            _person(1600 + i, f"Forælder {i}", f"Barn {i} (Mor)", "guardian") for i in range(1, 53)
        ]
        everyone = [ME, MARIA, ANNE, METTE, KASPER, *others]  # 57 participants
        h = lambda hours: now - timedelta(hours=hours)  # noqa: E731
        spec = [
            # id, subject, recipients, read, muted, marked, messages (oldest first)
            (9101, "Forældremøde i Stue", everyone, False, False, False, [
                ("m9101-1", ANNE, "<p>Kære alle,</p><p>Der er forældremøde torsdag kl. 17 i Stue. Vi byder på kaffe og kage.</p>", h(50)),
                ("m9101-2", ME, "<p>Tak, vi kommer begge to.</p>", h(30)),
                ("m9101-3", MARIA, "<p>Kan man tage søskende med?</p>", h(26)),
                ("m9101-4", ANNE, "<p>Ja, søskende er meget velkomne. Vi har legetøj i fællesrummet.</p>", h(2)),
            ]),
            (9102, "Oskar har glemt sin hue", [ME, MARIA, METTE], False, False, False, [
                ("m9102-1", METTE, "<p>Hej! Oskar har glemt sin blå hue her i dag. Den ligger i hans garderobe.</p>", h(1)),
            ]),
            (9103, "Julefrokost for børnene", everyone, True, True, False, [
                ("m9103-1", KASPER, "<p>Vi holder julefrokost for børnene d. 18. december. Børnene må gerne komme i nissetøj.</p>", h(28)),
            ]),
            (9104, "Ny madordning fra januar", [ME, MARIA, ANNE], True, False, True, [
                ("m9104-1", ANNE, "<p>Fra januar overgår vi til ny madordning. Se tilmelding i vedhæftede fil.</p>", h(75)),
            ]),
            (9105, "Tak for i dag", [ME, METTE], True, False, False, [
                ("m9105-1", METTE, "<p>Oskar har haft en god dag og sovet 1,5 time.</p>", h(23)),
                ("m9105-2", ME, "<p>Dejligt, tak for besked!</p>", h(22)),
            ]),
        ]
        threads: dict[int, dict] = {}
        messages: dict[int, list[dict]] = {}
        self.threads, self.messages = threads, messages
        for tid, subject, recipients, read, muted, marked, msgs in spec:
            built = [self._msg(mid, s, html, at) for mid, s, html, at in msgs]
            if tid == 9104:
                built[0]["attachments"] = [
                    {"id": 9903, "status": "available", "file": {"id": 9903, "name": "Madordning.pdf", "url": FILES_BASE + "madordning.pdf"}}
                ]
            messages[tid] = built[::-1]  # Aula returns newest first
            threads[tid] = {
                "id": tid,
                "subject": subject,
                "read": read,
                "muted": muted,
                "marked": marked,
                "sensitive": False,
                "isArchived": False,
                "leaveTime": None,
                "institutionCode": INSTITUTION_CODE,
                "mailBoxOwner": {"id": GUARDIAN_IP, "mailBoxOwnerType": "institutionProfile"},
                "creator": msgs[0][1],
                "recipients": [{**r, "leaveTime": None} for r in recipients],
                "lastReadMessageId": built[-1]["id"] if read else None,
            }
            self._refresh_latest(tid)
        return threads, messages

    def _refresh_latest(self, tid: int) -> None:
        latest = self.messages[tid][0]
        self.threads[tid]["latestMessage"] = {k: latest[k] for k in ("id", "text", "sendDateTime", "sender")}
        self.threads[tid]["lastUpdatedDate"] = latest["sendDateTime"]

    def _messaging_getThreads(self, q, body):
        threads = sorted(self.threads.values(), key=lambda t: t["lastUpdatedDate"], reverse=True)
        return _ok({"threads": threads, "moreMessagesExist": False})

    def _messaging_getMessagesForThread(self, q, body):
        tid = int(q["threadId"])
        thread = self.threads.get(tid)
        if thread is None:
            return HttpResponse(status_code=404, data={"status": {"code": 404}, "data": None})
        page = int(q.get("page", 0))
        limit = int(q.get("limit", 20))
        rows = self.messages[tid][page * limit : (page + 1) * limit]
        return _ok(
            {
                "id": tid,
                "subject": thread["subject"],
                "mailBoxOwner": thread["mailBoxOwner"],
                "sensitive": thread["sensitive"],
                "isArchived": thread["isArchived"],
                "leaveTime": thread["leaveTime"],
                "messages": rows,
                "moreMessagesExist": (page + 1) * limit < len(self.messages[tid]),
                "lastReadMessageId": thread["lastReadMessageId"],
            }
        )

    def _messaging_getMessageInfoLight(self, q, body):
        tid = int(q.get("ThreadId") or q.get("threadId"))
        mid = q.get("MessageId") or q.get("messageId")
        msg = next((m for m in self.messages.get(tid, []) if m["id"] == mid), None)
        thread = self.threads.get(tid)
        if msg is None or thread is None:
            return _ok(None)
        return _ok({"subject": thread["subject"], "isSensitive": thread["sensitive"], "message": msg})

    def _messaging_setLastReadMessage(self, q, body):
        thread = self.threads[int(body["threadId"])]
        thread["lastReadMessageId"] = body["messageId"]
        thread["read"] = True
        return _ok(None)

    def _messaging_reply(self, q, body):
        tid = int(body["threadId"])
        msg = self._msg(f"m{tid}-r{next(self._ids)}", ME, body["message"]["text"], _now())
        self.messages[tid].insert(0, msg)
        self.threads[tid]["read"] = True
        self.threads[tid]["lastReadMessageId"] = msg["id"]
        self._refresh_latest(tid)
        return _ok([msg])

    def _messaging_startNewThread(self, q, body):
        tid = 9200 + next(self._ids)
        msg = self._msg(f"m{tid}-1", ME, body["message"]["text"], _now())
        self.messages[tid] = [msg]
        by_id = {p["mailBoxOwner"]["id"]: p for p in (ME, MARIA, ANNE, METTE, KASPER)}
        self.threads[tid] = {
            "id": tid,
            "subject": body["subject"],
            "read": True,
            "muted": False,
            "marked": False,
            "sensitive": body.get("sensitive", False),
            "isArchived": False,
            "leaveTime": None,
            "institutionCode": INSTITUTION_CODE,
            "mailBoxOwner": {"id": GUARDIAN_IP, "mailBoxOwnerType": "institutionProfile"},
            "creator": ME,
            "recipients": [{**ME, "leaveTime": None}]
            + [{**by_id.get(r["id"], r), "leaveTime": None} for r in body["recipients"]],
            "lastReadMessageId": msg["id"],
        }
        self._refresh_latest(tid)
        # Best reading of the portal: handleSendMessageResponse opens
        # response.data.data.data as the new thread id.
        return _ok({"data": tid})


# POSTs that only read, so they are not recorded as writes.
_POST_READS = {"calendar.getEventsByProfileIdsAndResourceIds"}
