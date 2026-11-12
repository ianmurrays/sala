"""API.md contract against fake mode. Writes are asserted on the payloads the
fake Aula recorded, i.e. what the real library would have sent."""

import time

from aula.utils.dates import aula_today

from conftest import AUTH
from sala.fake import CHILD_ID, FAKE_OTP, GUARDIAN_IP, METTE

CHILD_KEYS = {
    "id", "name", "institution", "group", "status", "statusLabel", "arrivedAt",
    "leftAt", "pickup", "closesAt", "canReportSick",
}


def test_auth_401_before_503(client):
    assert client.get("/today").status_code == 401
    assert client.get("/today").json() == {"error": "unauthorized"}
    assert client.get("/today", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/auth/status").status_code == 401
    assert client.post("/devices", json={"token": "ab"}).status_code == 401

    r = client.get("/today", headers=AUTH)
    assert (r.status_code, r.json()) == (503, {"error": "auth_required"})


def test_fake_mitid_login_flow(client):
    assert client.get("/auth/status", headers=AUTH).json()["state"] == "needs_login"
    first = client.post("/auth/login", headers=AUTH).json()
    assert first["state"] == "logging_in"
    again = client.post("/auth/login", headers=AUTH).json()  # single-flight no-op
    assert again["state"] == "logging_in" and again["since"] == first["since"]
    seen_otp = None
    for _ in range(50):
        status = client.get("/auth/status", headers=AUTH).json()
        seen_otp = seen_otp or status["otpCode"]
        if status["state"] == "ok":
            break
        time.sleep(0.02)
    assert status == {**status, "state": "ok", "otpCode": None, "qr": None}
    assert seen_otp == FAKE_OTP
    assert client.get("/today", headers=AUTH).status_code == 200


def test_today_shape(api):
    body = api.get("/today", headers=AUTH).json()
    assert body["date"] == aula_today().isoformat()
    [child] = body["children"]
    assert set(child) == CHILD_KEYS
    assert child | {"pickup": None} == {
        "id": CHILD_ID, "name": "Oskar", "institution": "Børnehuset", "group": "Stue",
        "status": "present", "statusLabel": "Present", "arrivedAt": "07:40", "leftAt": None,
        "pickup": None, "closesAt": "16:45", "canReportSick": True,
    }
    assert child["pickup"] == {"time": "16:00", "by": "Jonas Hansen (Far)"}

    holiday = [a for a in body["attention"] if a["kind"] == "holiday_request"]
    assert [a["id"] for a in holiday] == ["vacation-55", "vacation-56"]  # answered one dropped
    assert holiday[0]["urgent"] is True and holiday[1]["urgent"] is False
    assert holiday[0]["title"].startswith("Holiday request: 21–23 Dec")
    messages = [a for a in body["attention"] if a["kind"] == "message"]
    assert {a["threadId"] for a in messages} == {"9101", "9102"}

    assert body["upcoming"] and all(set(u) == {"date", "title", "subtitle"} for u in body["upcoming"])
    assert [p["id"] for p in body["posts"]] == [401, 402, 403]
    important = body["posts"][0]
    assert important["important"] is True and "<" not in important["body"]
    assert important["attachments"][0]["kind"] == "file"
    assert body["posts"][1]["attachments"][0]["kind"] == "image"


def test_pickup_get(api):
    body = api.get(f"/children/{CHILD_ID}/pickup", headers=AUTH).json()
    assert body["people"] == ["Jonas Hansen (Far)", "Maria Hansen (Mor)", "Mormor Lis"]
    assert body["current"] == {"time": "16:00", "by": "Jonas Hansen (Far)"}
    assert (body["opensAt"], body["closesAt"], body["note"]) == ("06:30", "16:45", "Har madpakke med")
    assert "16:00" in body["times"] and body["times"] == sorted(body["times"])
    assert api.get("/children/999/pickup", headers=AUTH).status_code == 404


def test_pickup_put_writes_single_day_override(api, fake):
    r = api.put(
        f"/children/{CHILD_ID}/pickup",
        headers=AUTH,
        json={"time": "15:30", "by": "Maria Hansen (Mor)", "note": "Mor henter"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["pickup"] == {"time": "15:30", "by": "Maria Hansen (Mor)"}

    [payload] = fake.writes_for("presence.updatePresenceTemplate")
    assert payload["institutionProfileId"] == CHILD_ID
    assert payload["byDate"] == aula_today().isoformat()
    assert payload["presenceActivity"] == {
        "activityType": 0,
        "pickup": {"entryTime": "07:45", "exitTime": "15:30", "exitWith": "Maria Hansen (Mor)"},
    }
    assert payload["comment"] == "Mor henter"
    # Today's template repeats weekly, so it must not be touched: no id, one day only.
    assert "id" not in payload
    assert payload["repeatPattern"] == "never"

    today = api.get("/today", headers=AUTH).json()["children"][0]
    assert today["pickup"] == {"time": "15:30", "by": "Maria Hansen (Mor)"}

    # A second change edits the one-off template by id and keeps its comment.
    api.put(f"/children/{CHILD_ID}/pickup", headers=AUTH, json={"time": "16:15", "by": "Jonas Hansen (Far)"})
    second = fake.writes_for("presence.updatePresenceTemplate")[1]
    assert second["id"] > 7001 and second["comment"] == "Mor henter"


def test_pickup_put_rejects_unknown_person(api, fake):
    r = api.put(f"/children/{CHILD_ID}/pickup", headers=AUTH, json={"time": "15:30", "by": "Bob"})
    assert r.status_code == 400 and r.json()["error"] == "bad_request"
    assert api.put(f"/children/{CHILD_ID}/pickup", headers=AUTH, json={"time": "3pm", "by": "x"}).status_code == 400
    assert api.put(f"/children/{CHILD_ID}/pickup", headers=AUTH, json={}).status_code == 400
    assert fake.writes_for("presence.updatePresenceTemplate") == []


def test_sick_and_back(api, fake):
    r = api.post(f"/children/{CHILD_ID}/sick", headers=AUTH)
    assert r.status_code == 200 and r.json()["status"] == "sick"
    r = api.delete(f"/children/{CHILD_ID}/sick", headers=AUTH)
    assert r.status_code == 200 and r.json()["status"] == "not_arrived"
    assert fake.writes_for("presence.updateStatusByInstitutionProfileIds") == [
        {"institutionProfileIds": [CHILD_ID], "status": 1},
        {"institutionProfileIds": [CHILD_ID], "status": 0},
    ]


def test_reply_everyone(api, fake):
    r = api.post("/threads/9101/reply", headers=AUTH, json={"text": "Vi ses <3\nHilsen Jonas", "audience": "everyone"})
    assert r.json() == {"ok": True, "threadId": "9101"}
    assert fake.writes_for("messaging.reply") == [
        {
            "threadId": 9101,
            "message": {"text": "<p>Vi ses &lt;3<br>Hilsen Jonas</p>", "attachmentIds": []},
            "commonInboxId": None,
            "otpInboxId": None,
        }
    ]
    last = api.get("/threads/9101", headers=AUTH).json()["messages"][-1]
    assert last["fromMe"] is True and last["text"] == "Vi ses <3\nHilsen Jonas"


def test_reply_sender_starts_new_thread_to_sender_only(api, fake):
    r = api.post(
        "/threads/9102/reply",
        headers=AUTH,
        json={"text": "Tak, vi tager den i morgen.", "audience": "sender", "messageId": "m9102-1"},
    )
    assert r.status_code == 200, r.text
    new_id = r.json()["threadId"]
    assert new_id not in (None, "9102")
    assert fake.writes_for("messaging.reply") == []
    [payload] = fake.writes_for("messaging.startNewThread")
    assert payload["subject"] == "Vs. Oskar har glemt sin hue"
    assert [rcpt["id"] for rcpt in payload["recipients"]] == [METTE["mailBoxOwner"]["id"]]
    assert payload["recipients"][0]["mailBoxOwnerType"] == "institutionProfile"
    assert payload["bccRecipients"] == []
    assert payload["creator"] == {"id": GUARDIAN_IP, "mailBoxOwnerType": "institutionProfile"}
    assert payload["message"] == {"text": "<p>Tak, vi tager den i morgen.</p>", "attachmentIds": []}
    assert payload["forwardInfo"] == {"forwardedThreadId": 9102, "forwardedMessageIds": ["m9102-1"], "directReply": True}
    assert any(t["id"] == new_id for t in api.get("/threads", headers=AUTH).json())


def test_reply_sender_validation(api, fake):
    own = {"text": "x", "audience": "sender", "messageId": "m9101-2"}  # Jonas's own message
    assert api.post("/threads/9101/reply", headers=AUTH, json=own).status_code == 400
    missing = {"text": "x", "audience": "sender"}
    assert api.post("/threads/9101/reply", headers=AUTH, json=missing).status_code == 400
    assert api.post("/threads/9101/reply", headers=AUTH, json={"text": "x", "audience": "all"}).status_code == 400
    assert fake.writes_for("messaging.startNewThread") == []


def test_thread_detail_marks_read(api, fake):
    body = api.get("/threads/9101", headers=AUTH).json()
    assert body["canReply"] is True and len(body["messages"]) == 4
    assert [m["fromMe"] for m in body["messages"]] == [False, True, False, False]
    assert fake.writes_for("messaging.setLastReadMessage") == [
        {"threadId": "9101", "messageId": "m9101-4", "commonInboxId": None, "otpInboxId": None}
    ]
    row = next(t for t in api.get("/threads", headers=AUTH).json() if t["id"] == "9101")
    assert row["unread"] is False and row["participants"] == 57


def test_bookmark(api, fake):
    assert api.post("/posts/401/save", headers=AUTH).json() == {"saved": True}
    assert api.get("/today", headers=AUTH).json()["posts"][0]["saved"] is True
    assert api.delete("/posts/401/save", headers=AUTH).json() == {"saved": False}
    assert api.get("/today", headers=AUTH).json()["posts"][0]["saved"] is False
    assert [w["method"] for w in fake.writes if w["method"].startswith("posts.")] == ["posts.bookmark", "posts.unbookmark"]
    assert fake.writes_for("posts.bookmark") == [{"postId": 401}]


def test_attachments_are_opaque_ids(api):
    posts = api.get("/today", headers=AUTH).json()["posts"]
    pdf = posts[0]["attachments"][0]
    assert "/" not in pdf["id"] and ":" not in pdf["id"] and "aula" not in pdf["id"]
    r = api.get(f"/attachments/{pdf['id']}", headers=AUTH)
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
    assert r.headers["content-type"] == "application/pdf"
    assert r.headers["content-disposition"].startswith("inline; filename=")
    png = api.get(f"/attachments/{posts[1]['attachments'][0]['id']}", headers=AUTH)
    assert png.content.startswith(b"\x89PNG") and png.headers["content-type"] == "image/png"

    msg_att = api.get("/threads/9104", headers=AUTH).json()["messages"][0]["attachments"][0]
    assert api.get(f"/attachments/{msg_att['id']}", headers=AUTH).status_code == 200

    assert api.get("/attachments/https%3A%2F%2Fevil.example%2Fx", headers=AUTH).status_code == 404
    assert api.get("/attachments/deadbeef", headers=AUTH).status_code == 404


def test_devices(api):
    assert api.post("/devices", headers=AUTH, json={"token": "AbCd0123"}).json() == {"ok": True}
    assert api.post("/devices", headers=AUTH, json={"token": "not hex"}).status_code == 400
    assert api.app.state.store.devices() == ["abcd0123"]


def test_session_expiry_needs_login_and_fires_hook(api, fake):
    calls = []
    api.app.state.session.login_needed_hooks.append(lambda: calls.append(1))
    fake.session_expired = True
    r = api.get("/threads", headers=AUTH)
    assert (r.status_code, r.json()) == (503, {"error": "auth_required"})
    assert api.get("/auth/status", headers=AUTH).json()["state"] == "needs_login"
    assert calls == [1]


def test_403_on_one_source_keeps_today(api, fake):
    fake.forbidden = {"presence.getOpeningHoursByInstitutionCodes", "calendar.getBirthdayEventsForInstitutions"}
    r = api.get("/today", headers=AUTH)
    assert r.status_code == 200 and r.json()["children"][0]["closesAt"] is None
    assert api.get("/auth/status", headers=AUTH).json()["state"] == "ok"


def test_403_everywhere_means_session_gone(api, fake):
    fake.forbidden = {"*"}
    assert api.get("/threads", headers=AUTH).status_code == 503
    assert api.get("/auth/status", headers=AUTH).json()["state"] == "needs_login"


def test_pickup_put_refuses_blind_write(api, fake):
    fake.forbidden = {"presence.getPresenceTemplates"}
    r = api.put(f"/children/{CHILD_ID}/pickup", headers=AUTH, json={"time": "15:30", "by": "Jonas Hansen (Far)"})
    assert r.status_code == 502 and r.json()["error"] == "upstream"
    assert fake.writes_for("presence.updatePresenceTemplate") == []
