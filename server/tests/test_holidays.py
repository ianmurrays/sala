"""Holiday requests (answer) and absences (register) against fake mode."""

from datetime import date, timedelta

import pytest
from aula.utils.dates import aula_today

from conftest import AUTH
from sala.fake import CHILD_ID


def _vac(fake, reg_id: int) -> dict:
    return next(v for v in fake.vacations if v["vacationRegistrationId"] == reg_id)


def _weekdays(fake, reg_id: int) -> list[str]:
    v = _vac(fake, reg_id)
    start, end = date.fromisoformat(v["startDate"]), date.fromisoformat(v["endDate"])
    days = [start + timedelta(days=i) for i in range((end - start).days + 1)]
    return [d.isoformat() for d in days if d.isoweekday() <= 5]


def _answer(days, coming=True, **times):
    return {"children": [{"id": CHILD_ID, "days": [{"date": d, "coming": coming, **times} for d in days], "comment": "Vi holder fri"}]}


def test_get_holiday_request(api, fake):
    r = api.get("/holiday-requests/vacation-55", headers=AUTH)
    assert r.status_code == 200
    body = r.json()
    v = _vac(fake, 55)
    assert {k: body[k] for k in ("id", "title", "note", "deadline", "startDate", "endDate", "timesRequired", "answered", "editable")} == {
        "id": "vacation-55",
        "title": "Juleferie",
        "note": "Giv besked om Oskar holder fri.",
        "deadline": v["responseDeadline"],
        "startDate": v["startDate"],
        "endDate": v["endDate"],
        "timesRequired": False,
        "answered": False,
        "editable": True,
    }
    [child] = body["children"]
    assert (child["id"], child["name"], child["answered"], child["comment"]) == (CHILD_ID, "Oskar", False, "")
    assert child["days"] == [
        {"date": d, "coming": None, "entryTime": None, "exitTime": None, "editable": True} for d in _weekdays(fake, 55)
    ]
    assert api.get("/holiday-requests/vacation-56", headers=AUTH).json()["timesRequired"] is True


def test_answered_past_request_is_not_editable(api):
    body = api.get("/holiday-requests/vacation-54", headers=AUTH).json()
    assert (body["answered"], body["editable"]) == (True, False)
    assert all(d["coming"] is False and not d["editable"] for d in body["children"][0]["days"])


@pytest.mark.parametrize("rid", ["vacation-999", "55", "vacation-x"])
def test_unknown_holiday_request_is_404(api, rid):
    assert api.get(f"/holiday-requests/{rid}", headers=AUTH).status_code == 404


def test_answer_sends_portal_payload_and_clears_the_card(api, fake):
    days = _weekdays(fake, 55)
    # Times are ignored when the request doesn't ask for them, like Aula's form.
    r = api.post("/holiday-requests/vacation-55", headers=AUTH, json=_answer(days, coming=False, entryTime="08:00", exitTime="15:00"))
    assert r.status_code == 200, r.text
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest") == [
        {
            "vacationRegistrationResponseId": 5501,
            "childId": CHILD_ID,
            "days": [{"date": d, "isComing": False, "entryTime": "", "exitTime": ""} for d in days],
            "comment": "Vi holder fri",
        }
    ]
    body = r.json()
    assert body["answered"] is True
    assert body["children"][0]["comment"] == "Vi holder fri"
    assert [d["coming"] for d in body["children"][0]["days"]] == [False] * len(days)
    attention = api.get("/today", headers=AUTH).json()["attention"]
    assert "vacation-55" not in [a["id"] for a in attention]


def test_answer_with_required_times(api, fake):
    days = _weekdays(fake, 56)
    payload = {"children": [{"id": CHILD_ID, "days": [
        {"date": days[0], "coming": True, "entryTime": "08:00", "exitTime": "15:30"},
        *({"date": d, "coming": False, "entryTime": "08:00", "exitTime": "15:30"} for d in days[1:]),
    ]}]}
    r = api.post("/holiday-requests/vacation-56", headers=AUTH, json=payload)
    assert r.status_code == 200, r.text
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest") == [
        {
            "vacationRegistrationResponseId": 5601,
            "childId": CHILD_ID,
            "days": [{"date": days[0], "isComing": True, "entryTime": "08:00", "exitTime": "15:30"}]
            + [{"date": d, "isComing": False, "entryTime": "", "exitTime": ""} for d in days[1:]],
            "comment": "",
        }
    ]
    first = r.json()["children"][0]["days"][0]
    assert (first["coming"], first["entryTime"], first["exitTime"]) == (True, "08:00", "15:30")


@pytest.mark.parametrize(
    "rid,change",
    [
        ("vacation-55", lambda p: p["children"][0]["days"][0].update(entryTime="8:00")),  # bad time
        ("vacation-55", lambda p: p["children"][0]["days"][0].update(exitTime="24:00")),
        ("vacation-56", lambda p: p["children"][0]["days"][0].pop("exitTime")),  # times required
        ("vacation-56", lambda p: p["children"][0]["days"][0].update(entryTime="16:00")),  # entry after exit
        ("vacation-55", lambda p: p["children"][0]["days"].append({"date": "2020-01-06", "coming": True})),  # unknown day
        ("vacation-55", lambda p: p["children"][0]["days"].pop()),  # a day left unanswered
        ("vacation-55", lambda p: p["children"][0]["days"].append(dict(p["children"][0]["days"][0]))),  # twice
        ("vacation-55", lambda p: p["children"][0].update(id=9999)),  # unknown child
        ("vacation-55", lambda p: p["children"].append(dict(p["children"][0]))),  # child twice
        ("vacation-55", lambda p: p.update(children=[])),
        ("vacation-55", lambda p: p["children"][0]["days"][0].update(date="21-12-2026")),
    ],
)
def test_answer_validation_is_400_and_writes_nothing(api, fake, rid, change):
    payload = _answer(_weekdays(fake, int(rid.split("-")[1])), entryTime="08:00", exitTime="15:00")
    change(payload)
    r = api.post(f"/holiday-requests/{rid}", headers=AUTH, json=payload)
    assert r.status_code == 400, r.text
    assert r.json()["error"] == "bad_request"
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest") == []


def test_locked_day_is_400(api, fake):
    v = _vac(fake, 55)
    v["startDate"] = (aula_today() - timedelta(days=7)).isoformat()  # now starts with past weekdays
    days = api.get("/holiday-requests/vacation-55", headers=AUTH).json()["children"][0]["days"]
    assert not days[0]["editable"] and days[-1]["editable"]
    r = api.post("/holiday-requests/vacation-55", headers=AUTH, json=_answer([d["date"] for d in days]))
    assert r.status_code == 400 and "can no longer be answered" in r.json()["message"]


def test_answer_after_deadline_is_409(api, fake):
    days = _weekdays(fake, 55)
    _vac(fake, 55)["responseDeadline"] = (aula_today() - timedelta(days=1)).isoformat()
    assert api.get("/holiday-requests/vacation-55", headers=AUTH).json()["editable"] is False
    r = api.post("/holiday-requests/vacation-55", headers=AUTH, json=_answer(days))
    assert r.status_code == 409 and r.json()["error"] == "conflict"
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest") == []


def test_answer_without_response_id_writes_nothing(api, fake):
    days = _weekdays(fake, 55)
    _vac(fake, 55)["responseId"] = 0
    r = api.post("/holiday-requests/vacation-55", headers=AUTH, json=_answer(days))
    assert r.status_code == 502
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest") == []


def test_absence(api, fake):
    start = aula_today() + timedelta(days=3)
    body = {"childIds": [CHILD_ID], "startDate": start.isoformat(), "endDate": (start + timedelta(days=2)).isoformat(), "comment": "Bedsteforældre"}
    r = api.post("/absences", headers=AUTH, json=body)
    assert (r.status_code, r.json()) == (200, {"ok": True})
    assert fake.writes_for("calendar.addVacation") == [
        {"childIds": [CHILD_ID], "intervals": [{"startDate": body["startDate"], "endDate": body["endDate"]}], "comment": "Bedsteforældre"}
    ]


@pytest.mark.parametrize(
    "change,message",
    [
        ({"startDate": (aula_today() - timedelta(days=1)).isoformat()}, "in the past"),
        ({"endDate": aula_today().isoformat(), "startDate": (aula_today() + timedelta(days=2)).isoformat()}, "before start date"),
        ({"endDate": (aula_today() + timedelta(days=400)).isoformat()}, "more than a year"),
        ({"comment": "x" * 251}, "at most 250"),
        ({"childIds": []}, "childIds is empty"),
        ({"childIds": [9999]}, "unknown child"),
        ({"startDate": "tomorrow"}, "startDate"),
    ],
)
def test_absence_validation_is_400(api, fake, change, message):
    body = {"childIds": [CHILD_ID], "startDate": aula_today().isoformat(), "endDate": aula_today().isoformat(), "comment": "", **change}
    r = api.post("/absences", headers=AUTH, json=body)
    assert r.status_code == 400, r.text
    assert message in r.json()["message"]
    assert fake.writes_for("calendar.addVacation") == []


def test_read_only_blocks_holiday_writes(api, fake, monkeypatch):
    monkeypatch.setenv("SALA_READ_ONLY", "1")
    days = _weekdays(fake, 55)
    today = aula_today().isoformat()
    for path, body in [
        ("/holiday-requests/vacation-55", _answer(days)),
        ("/absences", {"childIds": [CHILD_ID], "startDate": today, "endDate": today}),
    ]:
        r = api.post(path, headers=AUTH, json=body)
        assert (r.status_code, r.json()["error"]) == (403, "read_only")
    assert api.get("/holiday-requests/vacation-55", headers=AUTH).status_code == 200
    assert fake.writes == []


def test_comment_is_per_child(api, fake):
    days = _weekdays(fake, 55)
    payload = _answer(days)
    payload["children"][0]["comment"] = "Kun Oskar"
    payload["comment"] = "ignored: not a field any more"
    assert api.post("/holiday-requests/vacation-55", headers=AUTH, json=payload).status_code == 200
    [sent] = fake.writes_for("calendar.respondToVacationRegistrationRequest")
    assert sent["comment"] == "Kun Oskar"
    payload["children"][0].pop("comment")  # missing = empty for that child
    assert api.post("/holiday-requests/vacation-55", headers=AUTH, json=payload).status_code == 200
    assert fake.writes_for("calendar.respondToVacationRegistrationRequest")[-1]["comment"] == ""


def test_utc_timestamps_give_copenhagen_dates(api, fake):
    v = _vac(fake, 56)
    start, end, deadline = (date.fromisoformat(v[k]) for k in ("startDate", "endDate", "responseDeadline"))
    utc = lambda d: f"{(d - timedelta(days=1)).isoformat()}T23:00:00Z"  # midnight in Copenhagen (winter)  # noqa: E731
    v.update(startDate=utc(start), endDate=utc(end), responseDeadline=utc(deadline))
    body = api.get("/holiday-requests/vacation-56", headers=AUTH).json()
    assert (body["startDate"], body["endDate"], body["deadline"]) == (start.isoformat(), end.isoformat(), deadline.isoformat())
    assert body["children"][0]["days"][0]["date"] == start.isoformat()


def _absence_body():
    day = (aula_today() + timedelta(days=3)).isoformat()
    return {"childIds": [CHILD_ID], "startDate": day, "endDate": day}


def test_absence_refused_without_custody(api, fake, monkeypatch):
    original = fake._profiles_getProfilesByLogin

    def no_custody(q, body):
        resp = original(q, body)
        resp.data["data"]["profiles"][0]["children"][0]["hasCustodyOrExtendedAccess"] = False
        return resp

    monkeypatch.setattr(fake, "_profiles_getProfilesByLogin", no_custody)
    api.app.state.session._profile = None  # drop the cached profile
    r = api.post("/absences", headers=AUTH, json=_absence_body())
    assert r.status_code == 400 and "no custody" in r.json()["message"]
    assert fake.writes_for("calendar.addVacation") == []


@pytest.mark.parametrize("permission,reason", [("readable", "read-only for guardians"), ("deactivated", "has not enabled")])
def test_absence_refused_when_vacation_not_editable(api, fake, monkeypatch, permission, reason):
    original = fake._presence_getPresenceConfigurationByChildIds

    def config(q, body):
        resp = original(q, body)
        settings = resp.data["data"][0]["presenceConfiguration"]["dashboardModuleSettings"][0]
        for module in settings["presenceModules"]:
            if module["moduleType"] == "vacation":
                module["permission"] = permission
        return resp

    monkeypatch.setattr(fake, "_presence_getPresenceConfigurationByChildIds", config)
    r = api.post("/absences", headers=AUTH, json=_absence_body())
    assert r.status_code == 400 and reason in r.json()["message"]
    assert fake.writes_for("calendar.addVacation") == []


def test_absence_left_to_aula_when_configuration_unreadable(api, fake):
    fake.forbidden = {"presence.getPresenceConfigurationByChildIds"}
    assert api.post("/absences", headers=AUTH, json=_absence_body()).status_code == 200
    assert len(fake.writes_for("calendar.addVacation")) == 1
