"""Record golden scenarios for the iOS port of the routes (ios/SalaTests/Goldens/).

Each scenario drives the real server code (app.py routes, mapping.py, the aula library) on a
fresh fake Aula (``SALA_FAKE=1``) and records, per route call:

- the Aula requests the fake served: verb, query pairs (as httpx would send them, minus
  ``access_token``), JSON body, HTTP status and answer;
- the route's answer (status + JSON);
- the writes the fake saw (``FakeAula.writes``).

The iOS tests (SalaTests/GoldenTests.swift) answer the Swift port from these recordings and
check it gives the same answers and sends the same writes. "Now" is frozen at 13:07 today in
Copenhagen (``mapping.now``); the fake's own dates stay relative to the real today, and the
recording carries both, so re-export whenever the fake changes:

    cd server && uv run python tests/export_goldens.py

Never touches real Aula or ``server/data``: the server runs in fake mode on a temp data dir.
"""

import base64
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timedelta
from datetime import time as dtime
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit

SERVER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER))
OUT = SERVER.parent / "ios" / "SalaTests" / "Goldens"

TOKEN = "golden-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

_tmp = tempfile.mkdtemp(prefix="sala-goldens-")
os.environ.update(SALA_FAKE="1", SALA_TOKEN=TOKEN, SALA_DATA_DIR=_tmp, SALA_FAKE_LOGIN_SECONDS="0.02")
for _var in (
    "NTFY_TOPIC", "NTFY_URL", "NTFY_TOKEN", "POLL_SECONDS", "ANTHROPIC_API_KEY", "SALA_FAKE_TRANSLATE",
    "SALA_TRANSLATE_MODEL", "SALA_TRANSLATE_LANG", "SALA_READ_ONLY", "SALA_EXTRA_FILE_HOSTS", "SALA_DEBUG_SHAPES",
):
    os.environ.pop(_var, None)

from aula.utils.dates import aula_today, parse_api_datetime  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from sala import mapping  # noqa: E402
from sala.app import app  # noqa: E402
from sala.fake import CHILD_ID  # noqa: E402

TODAY = aula_today()
NOW = datetime.combine(TODAY, dtime(13, 7), mapping.TZ)
mapping.now = lambda: NOW
PROFILE_METHODS = ("profiles.getProfilesByLogin", "profiles.getProfileContext")


def _copy(value):
    """A JSON round trip: the fake hands out live dicts it mutates later."""
    return None if value is None else json.loads(json.dumps(value))


def _param(value) -> str:
    # httpx's primitive_value_to_str
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


def _pairs(url: str, params: dict | None) -> list[list[str]]:
    pairs = [[k, v] for k, v in parse_qsl(urlsplit(url).query, keep_blank_values=True)]
    for k, v in (params or {}).items():
        for item in v if isinstance(v, (list, tuple)) else [v]:
            pairs.append([k, _param(item)])
    return [p for p in pairs if p[0] != "access_token"]


class Scenario:
    def __init__(self, name: str) -> None:
        self.name = name
        self.steps: list[dict] = []
        self.forbidden: list[str] = []
        self.exchanges: list[dict] = []
        self.files: dict[str, str] = {}

    def __enter__(self):
        self._ctx = TestClient(app)
        self.http = self._ctx.__enter__()
        self.http.post("/auth/login", headers=AUTH)
        for _ in range(200):
            if self.http.get("/auth/status", headers=AUTH).json()["state"] == "ok":
                break
            time.sleep(0.01)
        else:
            raise AssertionError("fake login did not finish")
        self.fake = self.http.app.state.session.fake_aula
        orig_request, orig_download = self.fake.request, self.fake.download_bytes

        async def request(method, url, *, headers=None, params=None, json=None):
            resp = await orig_request(method, url, headers=headers, params=params, json=json)
            self.exchanges.append(
                {
                    "verb": method.upper(),
                    "query": _pairs(url, params),
                    "body": _copy(json),
                    "status": resp.status_code,
                    "answer": _copy(resp.data),
                }
            )
            return resp

        async def download_bytes(url):
            data = await orig_download(url)
            self.files[url.split("?")[0]] = base64.b64encode(data).decode()
            return data

        self.fake.request = request
        self.fake.download_bytes = download_bytes
        return self

    def forbid(self, *methods: str) -> None:
        self.forbidden = list(methods)
        self.fake.forbidden = set(methods)

    def call(self, verb: str, path: str, body=None, *, note: str = "") -> dict:
        start, writes = len(self.exchanges), len(self.fake.writes)
        r = self.http.request(verb, path, headers=AUTH, json=body)
        step = {"note": note, "verb": verb, "path": path, "body": body, "status": r.status_code}
        if path.startswith("/attachments/"):
            disposition = r.headers.get("content-disposition", "")
            step["attachment"] = {
                "contentType": r.headers.get("content-type", "").split(";")[0],
                "name": unquote(disposition.split("filename*=UTF-8''")[-1]) if "filename*=" in disposition else None,
                "bytes": base64.b64encode(r.content).decode() if r.status_code == 200 else None,
            }
            step["response"] = None if r.status_code == 200 else r.json()
        else:
            step["response"] = r.json()
        step["aula"] = self.exchanges[start:]
        step["writes"] = _copy(self.fake.writes[writes:])
        self.steps.append(step)
        return step["response"]

    def __exit__(self, *exc):
        if exc[0] is None:
            profile = {}
            for m in PROFILE_METHODS:
                found = next(
                    (e["answer"] for e in self.exchanges if ["method", m] in e["query"] and e["status"] == 200), None
                )
                if found is None:  # the scenario never read the profile; the Swift session opens with it anyway
                    found = _copy(getattr(self.fake, "_" + m.replace(".", "_"))({}, None).data)
                profile[m] = found
            out = {
                "name": self.name,
                "today": TODAY.isoformat(),
                "now": NOW.isoformat(timespec="seconds"),
                "forbidden": self.forbidden,
                "profile": profile,
                "files": self.files,
                "steps": self.steps,
            }
            (OUT / f"{self.name}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
        self._ctx.__exit__(*exc)


def _days(start: str, end: str) -> list[str]:
    a, b = datetime.fromisoformat(start).date(), datetime.fromisoformat(end).date()
    return [(a + timedelta(days=i)).isoformat() for i in range((b - a).days + 1) if (a + timedelta(days=i)).isoweekday() <= 5]


def scenarios() -> None:
    child = f"/children/{CHILD_ID}"

    with Scenario("today") as s:
        s.call("GET", "/today")
        s.call("GET", "/features")
        s.call("POST", "/translate", {"texts": ["Hej"]}, note="translation is off on the phone")
        s.call("GET", "/nope", note="unknown route")

    with Scenario("today_partial") as s:
        s.forbid("messaging.getThreads", "presence.getPresenceConfigurationByChildIds", "calendar.getImportantDates")
        s.call("GET", "/today", note="a 403 on one part leaves it out")

    with Scenario("session_gone") as s:
        s.forbid("*")
        s.call("GET", "/today", note="everything refused, the probe too: login needed")

    with Scenario("pickup") as s:
        s.call("GET", f"{child}/pickup")
        s.call("PUT", f"{child}/pickup", {"time": "16:30", "by": "Maria Hansen (Mor)", "note": ""}, note="new one-off")
        s.call("PUT", f"{child}/pickup", {"time": "15:30", "by": "Mormor Lis"}, note="one-off updated by id, note kept")
        s.call("GET", f"{child}/pickup")
        s.call("PUT", f"{child}/pickup", {"time": "16:00", "by": "Ukendt (Onkel)", "note": ""}, note="unknown person")
        s.call("PUT", f"{child}/pickup", {"time": "25:00", "by": "Jonas Hansen (Far)", "note": ""}, note="bad time")
        s.call("PUT", f"{child}/pickup", {"by": "Jonas Hansen (Far)"}, note="no time")
        s.call("GET", "/children/9999/pickup", note="unknown child")
        s.call("GET", "/children/abc/pickup", note="not an int")

    with Scenario("pickup_absent") as s:
        today = TODAY.isoformat()
        s.call("POST", "/absences", {"childIds": [CHILD_ID], "startDate": today, "endDate": today, "comment": "Fri"})
        s.call("PUT", f"{child}/pickup", {"time": "16:30", "by": "Jonas Hansen (Far)", "note": ""}, note="absent today: 409")
        s.call("GET", "/today")

    with Scenario("sick") as s:
        s.call("POST", f"{child}/sick")
        s.call("DELETE", f"{child}/sick", note="checked in, not out: back to present")
        s.fake.check_in = None
        s.call("POST", f"{child}/sick")
        s.call("DELETE", f"{child}/sick", note="not checked in: not arrived")
        s.call("POST", "/children/9999/sick", note="unknown child")

    with Scenario("holiday") as s:
        req = s.call("GET", "/holiday-requests/vacation-55")
        days = [d["date"] for d in req["children"][0]["days"] if d["editable"]]
        s.call("POST", "/holiday-requests/vacation-55", {"children": [{"id": CHILD_ID, "days": [{"date": days[0], "coming": True}]}]},
               note="a day left out")
        s.call("POST", "/holiday-requests/vacation-55", {"children": [
            {"id": CHILD_ID, "comment": "Vi er i Jylland", "days": [{"date": d, "coming": i == 0, "entryTime": "08:00", "exitTime": "15:00"} for i, d in enumerate(days)]},
        ]}, note="times ignored when not required")
        s.call("GET", "/holiday-requests/vacation-55")
        req = s.call("GET", "/holiday-requests/vacation-56")
        days = [d["date"] for d in req["children"][0]["days"] if d["editable"]]
        s.call("POST", "/holiday-requests/vacation-56", {"children": [
            {"id": CHILD_ID, "days": [{"date": d, "coming": True, "entryTime": "15:00", "exitTime": "08:00"} for d in days]},
        ]}, note="entry after exit")
        s.call("POST", "/holiday-requests/vacation-56", {"children": [
            {"id": CHILD_ID, "days": [{"date": d, "coming": True} for d in days]},
        ]}, note="times required")
        s.call("POST", "/holiday-requests/vacation-56", {"children": [
            {"id": CHILD_ID, "days": [{"date": d, "coming": i % 2 == 0, "entryTime": "08:00", "exitTime": "15:30"} for i, d in enumerate(days)]},
        ]})
        s.call("POST", "/holiday-requests/vacation-56", {"children": [{"id": 9999, "days": []}]}, note="unknown child")
        s.call("POST", "/holiday-requests/vacation-56", {"children": [{"id": CHILD_ID, "days": []}, {"id": CHILD_ID, "days": []}]},
               note="child twice")
        s.call("POST", "/holiday-requests/vacation-56", {"children": []}, note="no children")
        s.call("POST", "/holiday-requests/vacation-56", {"children": [{"id": CHILD_ID, "days": [{"date": "2001-01-01", "coming": True}]}]},
               note="not a day of the request")
        s.call("POST", "/holiday-requests/vacation-56", {"children": [{"id": CHILD_ID, "days": [{"date": days[0], "coming": True, "entryTime": "8", "exitTime": "15:00"}]}]},
               note="bad time")
        s.call("GET", "/holiday-requests/vacation-54", note="past: nothing editable")
        s.call("POST", "/holiday-requests/vacation-54", {"children": [{"id": CHILD_ID, "days": []}]}, note="deadline passed: 409")
        s.call("GET", "/holiday-requests/vacation-999", note="unknown")
        s.call("GET", "/holiday-requests/55", note="not a holiday id")
        s.call("GET", "/today")

    with Scenario("absences") as s:
        start = TODAY + timedelta(days=3)
        s.call("POST", "/absences", {"childIds": [CHILD_ID, CHILD_ID], "startDate": start.isoformat(),
                                     "endDate": (start + timedelta(days=4)).isoformat(), "comment": "Skiferie"})
        s.call("GET", f"{child}/pickup")
        bad = [
            ("in the past", {"startDate": (TODAY - timedelta(days=1)).isoformat()}),
            ("end before start", {"endDate": TODAY.isoformat(), "startDate": (TODAY + timedelta(days=2)).isoformat()}),
            ("over a year", {"endDate": (TODAY + timedelta(days=400)).isoformat()}),
            ("long comment", {"comment": "x" * 251}),
            ("no children", {"childIds": []}),
            ("unknown child", {"childIds": [CHILD_ID, 9999]}),
        ]
        for note, change in bad:
            s.call("POST", "/absences", {"childIds": [CHILD_ID], "startDate": TODAY.isoformat(), "endDate": TODAY.isoformat(),
                                         "comment": "", **change}, note=note)
        s.fake.forbidden = set()

    with Scenario("absence_denied") as s:
        s.fake._presence_getPresenceConfigurationByChildIds = lambda q, body: mapping_config("readable")
        s.call("POST", "/absences", {"childIds": [CHILD_ID], "startDate": TODAY.isoformat(), "endDate": TODAY.isoformat(), "comment": ""},
               note="vacation module read-only")

    with Scenario("posts") as s:
        for page in (1, 2, 3, 4):
            s.call("GET", f"/posts?page={page}")
        s.call("GET", "/posts", note="default page 1")
        s.call("GET", "/posts?page=0", note="below 1")
        s.call("GET", "/posts?page=101", note="above 100")

    with Scenario("gallery") as s:
        for page in (1, 2):
            s.call("GET", f"/albums?page={page}")
        for album, page in ((6001, 1), (6001, 2), (6001, 3), (6002, 1), (0, 1)):
            s.call("GET", f"/albums/{album}/photos?page={page}")
        s.call("GET", "/albums?page=0", note="below 1")
        s.call("GET", "/albums/x/photos", note="not an int")

    with Scenario("save") as s:
        s.call("POST", "/posts/401/save")
        s.call("DELETE", "/posts/403/save")
        s.call("GET", "/posts?page=1")

    with Scenario("threads") as s:
        s.call("GET", "/threads")
        s.call("GET", "/threads?page=1")
        s.call("GET", "/threads?page=2", note="past the end")
        s.call("GET", "/threads?folder=71&page=0")
        s.call("GET", "/threads?folder=71")
        s.call("GET", "/threads?page=101", note="above 100")
        s.call("GET", "/threads?folder=0", note="folder below 1")

    with Scenario("patch_thread") as s:
        s.call("GET", "/threads?page=1")
        s.call("PATCH", "/threads/9101", {"muted": True, "starred": True, "folderId": 71}, note="not listed yet: inbox page 0 is read")
        s.call("PATCH", "/threads/9101", {"folderId": None}, note="back to the inbox")
        s.call("PATCH", "/threads/9055", {"starred": True}, note="listed on page 1")
        s.call("PATCH", "/threads/9102", {}, note="nothing to change")
        s.call("PATCH", "/threads/9102", {"folderId": 999}, note="unknown folder")
        s.call("PATCH", "/threads/9102", {"muted": "yes"}, note="not a bool")
        s.call("PATCH", "/threads/1234", {"muted": True}, note="never listed: 409")
        s.call("PATCH", "/threads/abc", {"muted": True}, note="not a thread id")
        s.call("GET", "/threads")
        s.call("GET", "/threads?folder=71")

    with Scenario("thread_detail") as s:
        s.call("GET", "/threads/9101", note="unread: marks read")
        s.call("GET", "/threads/9104", note="attachment")
        s.call("GET", "/threads/9105", note="read already")
        s.call("GET", "/threads/9103", note="a message over 78 characters")
        s.call("GET", "/threads/77777", note="unknown thread")
        s.call("GET", "/threads")

    with Scenario("reply") as s:
        s.call("POST", "/threads/9101/reply", {"text": "Tak!\n\nVi ses <torsdag> & fredag", "audience": "everyone"})
        s.call("POST", "/threads/9101/reply", {"text": "Hej Anne\nKan Oskar komme?", "audience": "sender", "messageId": "m9101-4"})
        s.call("POST", "/threads/9101/reply", {"text": "x", "audience": "sender", "messageId": "m9101-2"}, note="own message")
        s.call("POST", "/threads/9101/reply", {"text": "x", "audience": "sender"}, note="no messageId")
        s.call("POST", "/threads/9101/reply", {"text": "x", "audience": "sender", "messageId": "nope"}, note="unknown message")
        s.call("POST", "/threads/9101/reply", {"text": "  \n ", "audience": "everyone"}, note="empty text")
        s.call("POST", "/threads/9101/reply", {"text": "x", "audience": "nobody"}, note="bad audience")
        s.call("GET", "/threads")

    with Scenario("folders") as s:
        s.call("GET", "/folders")
        s.call("POST", "/folders", {"name": "  Ny mappe "})
        s.call("PATCH", "/folders/71", {"name": "Skole 2"})
        s.call("PATCH", "/folders/999", {"name": "x"}, note="unknown folder")
        s.call("PATCH", "/folders/70", {"name": "x"}, note="Aula's deleted folder")
        s.call("POST", "/folders", {"name": "   "}, note="empty name")
        s.call("POST", "/folders", {"name": "x" * 101}, note="long name")
        s.call("DELETE", "/folders/72")
        s.call("DELETE", "/folders/71", note="its threads go too")
        s.call("GET", "/folders")
        s.call("GET", "/threads?folder=71")

    with Scenario("guards") as s:
        # A read that decides what gets written fails: nothing is written (502).
        pickup = {"time": "16:30", "by": "Jonas Hansen (Far)", "note": ""}
        s.forbid("presence.getPresenceTemplates")
        s.call("PUT", f"{child}/pickup", pickup, note="template unreadable: no write")
        s.forbid("presence.getDailyOverview")
        s.call("DELETE", f"{child}/sick", note="overview unreadable: no undo")
        s.forbid("presence.getVacationRegistrationResponse")
        req_days = _days(*[v for v in (s.fake.vacations[0]["startDate"], s.fake.vacations[0]["endDate"])])
        s.call("POST", "/holiday-requests/vacation-55", {"children": [{"id": CHILD_ID, "days": [{"date": d, "coming": False} for d in req_days]}]},
               note="answer unreadable: no write")
        s.forbid("messaging.getFolders")
        s.call("PATCH", "/threads/9102", {"folderId": 71}, note="folders unreadable: no move")
        # Optional reads fail: the write still goes.
        s.forbid("presence.getPresenceConfigurationByChildIds")
        start = (TODAY + timedelta(days=3)).isoformat()
        s.call("POST", "/absences", {"childIds": [CHILD_ID], "startDate": start, "endDate": start, "comment": ""},
               note="configuration unreadable: Aula decides")
        s.forbid("presence.getDailyOverview")
        s.call("PUT", f"{child}/pickup", pickup, note="overview unreadable: template is enough")
        # No drop-off time anywhere: entryTime goes as JSON null.
        s.forbid()
        s.fake.weekly_template["entryTime"] = None
        s.fake.overrides.clear()
        s.call("PUT", f"{child}/pickup", pickup, note="entryTime null")

    with Scenario("attachments") as s:
        today = s.call("GET", "/today")
        s.call("GET", f"/attachments/{today['posts'][0]['attachments'][0]['id']}", note="pdf")
        s.call("GET", f"/attachments/{today['children'][0]['picture']}", note="profile picture")
        s.call("GET", "/attachments/doesnotexist", note="unknown id")


def mapping_config(permission: str):
    from sala.fake import CHILD_ID as cid, INSTITUTION_CODE, INSTITUTION_NAME, _ok

    modules = [{"moduleType": "vacation", "permission": permission}, {"moduleType": "report_sick", "permission": "editable"}]
    return _ok([{
        "uniStudentId": cid,
        "presenceConfiguration": {
            "institution": {"institutionCode": INSTITUTION_CODE, "name": INSTITUTION_NAME},
            "dashboardModuleSettings": [{"presenceDashboardContext": "guardian_dashboard", "presenceModules": modules}],
        },
    }])


# --- helper corpora: pure functions the routes lean on ------------------------------------------

HTML = [
    "<p>Kære forældre,</p><p>Vinteren er på vej. Husk <b>flyverdragt</b> og ekstra vanter.</p><p>Se præsentationen.</p>",
    "<p>Vi holder julefrokost for børnene d. 18. december. Børnene må gerne komme i nissetøj, og vi glæder os til at se jer alle sammen til en hyggelig dag.</p>",
    "<p>18. december er sidste dag før ferien.</p><p>- husk madpakke</p><p>+ og drikkedunk</p>",
    "<p>a<br>b</p><p>c</p>",
    "a<br/>b<br />c",
    "<div>one</div><div>two</div>",
    "plain   text\nwith newline",
    "<p>Hej &amp; farvel &lt;3 &nbsp;x &copy; &hellip; &#39; &#x41; &#150; &unknown; a & b</p>",
    "<ul><li>one</li><li>two</li></ul><p>after</p>",
    "<ol start=\"3\"><li>one</li><li>two</li></ol>",
    "<ul><li>outer<ul><li>inner</li></ul></li></ul>",
    "<ol><li>first<ul><li>sub</li></ul></li></ol>",
    "<ul><li>Et meget langt punkt i en liste der fortsætter og fortsætter langt ud over de otteoghalvfjerds tegn</li></ul>",
    "<h2>Title</h2><p>body</p><h1>Big</h1>",
    "<a href='http://x'>link text</a> after <a href='https://www.aula.dk/portal/#/meget/lang/sti/der/aldrig/slutter/og/bliver/ved/og/ved'>https://www.aula.dk/portal/#/meget/lang/sti/der/aldrig/slutter/og/bliver/ved/og/ved</a>",
    "<p>Se https://www.aula.dk/portal/#/meget/lang/sti/der/aldrig/slutter/og/bliver/ved/og/ved/endnu/længere for mere</p>",
    "<img src='x' alt='pic'> after",
    "<blockquote>quoted</blockquote>",
    "<blockquote>Et langt citat som er længere end otteoghalvfjerds tegn, så det bliver brudt over flere linjer her.</blockquote>",
    "<blockquote>a<br>b</blockquote>",
    "<p>  spaced   out  </p>",
    "<p>line1</p>\n\n<p>line2</p>",
    "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>",
    "<p><strong>Bold</strong> and <em>it</em> and <u>under</u></p>",
    "<p>x</p><br><p>y</p>",
    "<span>a</span> <span>b</span>",
    "1. not a list",
    "<p>* star</p><p>** stars</p>",
    "<p>Hello&#39;s &quot;q&quot; and \\back\\slash \\* \\.</p>",
    "<p>Et ord-med-bindestreger og et meget-langt-sammensat-ord-som-kan-brydes-ved-bindestregerne-hvis-det-er-nødvendigt</p>",
    "<p>Tankestreg -- her og der --- og en ultralangtordudenmellemrumoverhovedetsomslettesikkeerbrydeligtpånogenmådeoverhovedet ja</p>",
    "<p><s>gammel</s> ny pris</p>",
    "<p>Brug <code>kode_her</code> og <kbd>Ctrl</kbd></p>",
    "<pre>linje 1\n  linje 2</pre><p>efter</p>",
    "<p>Hun sagde <q>hej</q></p>",
    "<hr><p>under</p>",
    "<dl><dt>Term</dt><dd>Def</dd></dl>",
    "<style>p{color:red}</style><script>var x = 1;</script><p>synlig</p>",
    "<!-- kommentar --><p>efter kommentar</p>",
    "<p>Tab\there and\u00a0nbsp\u00a0char</p>",
    "<P>UPPER <B>case</B></P>",
    "<p>a</p>   <p>b</p>",
    "<div><p>nested</p></div>",
    "",
    "   ",
    "<p></p>",
    "Kort nyt fra Stue, opslag 1.",
    "<p>Ét afsnit med en sætning der er præcis lang nok til at ramme grænsen på 78 tegn!</p>",
    "<p>" + " ".join(["ord"] * 60) + "</p>",
    "x&amp", "a &amp b", "&#65", "AT&T rocks", "a&b", "x &#x41;y", "&#65;&#66", "<p>a</p><hr><p>b</p>", "a < b > c",
    "<p>1.5 is not</p>", "<p>2.\tTab</p>", "x<br>", "<br>y", "<p>a<br><br>b</p>", "<li>loose</li>",
    "<p>12. maj</p><p>  3. juni</p>", "<b>bold</b>text", "<s>a</s>b", "<p>Line one</p><ul><li>a</li></ul>text after",
    "text<p>para</p>more", "<h3>H</h3>text", "</p>stray", "<p unclosed", "x <!-- c --> y", "<br/><br/>", "&lt;b&gt;",
    "<div>a<div>b</div>c</div>", "<p>Pris: 100 | 200 | 300 kr og mere tekst så linjen bliver længere end otteoghalvfjerds tegn</p>",
    "<p>-- tankestreg først i en lang linje der bliver ved og ved og ved til den er over grænsen for ombrydning</p>",
    "<abbr title=\"Skolefritidsordning\">SFO</abbr> åbner", "<p>Ét&nbsp;ord&nbsp;med&nbsp;hårde&nbsp;mellemrum</p>",
]

TIMESTAMPS = [
    "2026-11-12T16:15:00+01:00", "2026-11-12T15:15:00Z", "2026-11-12T16:15:00", "2026-07-01T12:00:00",
    "2026-11-12T16:15:00.123456+01:00", "2026-11-12T16:15:00.5Z", "2026-11-12", "2026-11-12T16:15",
    "2026-11-12T16:15:00+0100", "2026-03-29T01:30:00Z", "2026-10-25T00:30:00Z", "2026-12-31T23:30:00Z",
    "2026-11-12 16:15:00", "garbage", "", None, 5, "2026-13-01T00:00:00",
]


def corpora() -> None:
    from aula.api_client import validate_vacation

    out = {
        "plain": [[h, mapping.plain(h)] for h in HTML],
        "textToHtml": [[t, mapping.text_to_html(t)] for t in [
            "Tak!", "a\nb", "a\n\nb", "a\r\n\r\nb\n\n\n\nc", "<b> & \"q\" 'a'", "  \n\n  ", "x\n \ny",
        ]],
        "iso": [[t, mapping.iso(t)] for t in TIMESTAMPS],
        "localDate": [[t, (lambda d: d.isoformat() if d else None)(mapping.local_date(t))] for t in TIMESTAMPS],
        "hhmm": [[v, mapping.hhmm(v)] for v in ["16:15", "16:15:00", "2026-11-12T16:15:00+01:00", "7:40", "", None, 1615, "abcde"]],
        "validHHmm": [[v, mapping.valid_hhmm(v)] for v in ["16:15", "24:00", "23:59", "7:40", "07:4", "16:15:00", "ab:cd", "-1:00", "16-15"]],
        "dateRange": [[a, b, mapping.date_range_label(datetime.fromisoformat(a).date(), datetime.fromisoformat(b).date() if b else None)]
                      for a, b in [("2026-12-21", "2026-12-23"), ("2026-12-30", "2027-01-02"), ("2026-12-21", None),
                                   ("2026-12-21", "2026-12-21"), ("2026-11-28", "2026-12-02")]],
        "pickupTimes": [],
        "validateVacation": [],
    }
    for current, opens, closes, at in [
        ("16:00", "06:30", "16:45", "13:07"), (None, None, None, "13:07"), ("16:00", "06:30", "16:45", "16:50"),
        (None, "06:30", "16:45", "06:00"), ("17:10", "06:30", "16:45", "15:59"), (None, "15:00", "16:30", "08:00"),
        ("12:00", None, "16:45", "16:45"), (None, "06:30", "16:40", "14:31"),
    ]:
        h, m = map(int, at.split(":"))
        out["pickupTimes"].append([current, opens, closes, at,
                                   mapping.pickup_times(current, opens, closes, datetime.combine(TODAY, dtime(h, m), mapping.TZ))])
    for start, end, comment, today in [
        ("2026-12-01", "2026-12-05", "", "2026-11-13"), ("2026-11-12", "2026-11-12", "", "2026-11-13"),
        ("2026-12-05", "2026-12-01", "", "2026-11-13"), ("2026-12-01", "2027-12-02", "", "2026-11-13"),
        ("2028-02-29", "2029-02-28", "", "2026-11-13"), ("2028-02-29", "2029-03-01", "", "2026-11-13"),
        ("2026-12-01", "2026-12-01", "é" * 251, "2026-11-13"), ("2026-12-01", "2026-12-01", "é" * 250, "2026-11-13"),
    ]:
        try:
            d = lambda s: datetime.fromisoformat(s).date()  # noqa: E731
            validate_vacation(d(start), d(end), comment, today=d(today))
            err = None
        except ValueError as e:
            err = str(e)
        out["validateVacation"].append([start, end, comment, today, err])
    assert parse_api_datetime("2026-11-12") is not None
    (OUT / "_helpers.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    scenarios()
    corpora()
    print(f"wrote {len(list(OUT.glob('*.json')))} files to {OUT} (today {TODAY}, now {NOW.isoformat(timespec='seconds')})")
