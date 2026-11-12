"""ntfy push poller against fake mode, with ntfy mocked (no network)."""

import asyncio
import json
import logging
import time
from datetime import timedelta
from types import SimpleNamespace

import httpx
import pytest
from aula.http import AulaSessionExpiredError, HttpRequestError
from aula.utils.dates import aula_today

from conftest import AUTH
from sala import mapping
from sala.fake import ANNE, GUARDIAN_IP, KASPER, ME, METTE
from sala.mapping import UpstreamFailure, _short_date, date_range_label, download_attachment
from sala.push import Pusher, is_direct, message_event


class Ntfy:
    def __init__(self) -> None:
        self.posts: list[dict] = []
        self.fail = False
        self.boom = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self.boom:
            raise RuntimeError("not an httpx error")
        if self.fail:
            return httpx.Response(500)
        assert str(request.url) == "http://ntfy.test"
        assert request.headers["authorization"] == "Bearer tk"
        self.posts.append(json.loads(request.content))
        return httpx.Response(200, json={"id": "x"})


@pytest.fixture
def push(api):
    ntfy = Ntfy()
    pusher = Pusher(
        api.app.state.session,
        api.app.state.store,
        topic="sala-test",
        url="http://ntfy.test/",
        token="tk",
        transport=httpx.MockTransport(ntfy.handler),
    )
    session = api.app.state.session
    session.login_needed_hooks.append(pusher.on_login_needed)
    session.logged_in_hooks.append(pusher.on_logged_in)

    def poll() -> int:
        return api.portal.call(pusher.poll_once)

    assert poll() == 0  # first run: seeds every kind silently
    return ntfy, poll, pusher


def test_seeding_sends_nothing(push):
    ntfy, poll, _ = push
    assert poll() == 0
    assert ntfy.posts == []


def test_direct_message(push, fake):
    ntfy, poll, _ = push
    fake.add_direct_message()
    assert poll() == 1
    assert ntfy.posts == [
        {
            "topic": "sala-test",
            "title": "New message from Mette Lund",
            "message": "New message from Mette Lund",
            "priority": 3,
            "tags": ["speech_balloon"],
            "click": "sala://thread/9105",
        }
    ]
    assert poll() == 0 and len(ntfy.posts) == 1


def test_group_and_own_messages_send_nothing(push, fake):
    ntfy, poll, _ = push
    fake.add_message(9101, ANNE, "<p>Alle</p>")  # 57 participants
    fake.add_message(9102, METTE, "<p>Hue</p>")  # me, the other parent and Mette
    fake.add_message(9105, ME, "<p>Tak</p>")  # direct thread, but from me
    assert poll() == 0
    assert ntfy.posts == []


def test_important_post(push, fake):
    ntfy, poll, _ = push
    fake.add_important_post()
    assert poll() == 1
    [sent] = ntfy.posts
    assert sent["title"] == "Important post: Børnehuset lukker tidligt på fredag"
    assert (sent["click"], sent["priority"], sent["message"]) == ("sala://today", 3, sent["title"])


@pytest.mark.parametrize("deadline_days,priority", [(2, 4), (3, 3)])
def test_holiday_request(push, fake, deadline_days, priority):
    ntfy, poll, _ = push
    fake.add_holiday_request(deadline_days=deadline_days)
    assert poll() == 1
    start = aula_today() + timedelta(days=30)
    label = date_range_label(start, start + timedelta(days=2))
    deadline = _short_date(aula_today() + timedelta(days=deadline_days))
    [sent] = ntfy.posts
    assert sent["title"] == f"Holiday request {label} · answer by {deadline}"
    assert (sent["priority"], sent["click"]) == (priority, "sala://today")


def test_failed_publish_is_retried_next_poll(push, fake):
    ntfy, poll, _ = push
    ntfy.fail = True
    fake.add_important_post()
    assert poll() == 0
    ntfy.fail = False
    assert poll() == 1 and len(ntfy.posts) == 1
    assert poll() == 0


def test_failed_source_is_not_seeded(api, fake):
    ntfy = Ntfy()
    pusher = Pusher(api.app.state.session, api.app.state.store, topic="sala-test", url="http://ntfy.test",
                    token="tk", transport=httpx.MockTransport(ntfy.handler))
    fake.forbidden = {"posts.getAllPosts"}
    api.portal.call(pusher.poll_once)
    assert not api.app.state.store.seeded("post") and api.app.state.store.seeded("message")
    fake.forbidden = set()
    assert api.portal.call(pusher.poll_once) == 0  # existing posts seed now, silently
    assert ntfy.posts == []


def _settle(pusher: Pusher) -> None:
    """Wait for the login-needed side tasks to finish."""
    for _ in range(100):
        if not pusher._side_tasks:
            return
        time.sleep(0.02)
    raise AssertionError("side task did not finish")


def _login(api) -> None:
    api.post("/auth/login", headers=AUTH)
    for _ in range(50):
        if api.get("/auth/status", headers=AUTH).json()["state"] == "ok":
            return
        time.sleep(0.05)
    raise AssertionError("fake login did not finish")


LOGIN = ("Aula login needed", 4, "sala://today")


def _titles(ntfy):
    return [(p["title"], p["priority"], p["click"]) for p in ntfy.posts]


def test_login_needed_once_and_no_polling_while_logged_out(push, fake, api):
    ntfy, poll, pusher = push
    fake.session_expired = True
    assert api.get("/threads", headers=AUTH).status_code == 503
    assert api.get("/threads", headers=AUTH).status_code == 503
    _settle(pusher)
    assert _titles(ntfy) == [LOGIN]
    fake.add_important_post()
    assert poll() == 0 and len(ntfy.posts) == 1


def test_login_needed_is_retried_until_ntfy_accepts(push, fake, api):
    ntfy, poll, pusher = push
    ntfy.fail = True
    fake.session_expired = True
    assert api.get("/threads", headers=AUTH).status_code == 503
    _settle(pusher)
    assert poll() == 0 and ntfy.posts == []
    ntfy.fail, ntfy.boom = False, True  # a non-httpx failure is caught, not left in a task
    assert poll() == 0 and api.portal.call(pusher.notify_login_needed) is False
    ntfy.boom = False
    assert poll() == 1 and _titles(ntfy) == [LOGIN]
    assert poll() == 0 and len(ntfy.posts) == 1


def test_login_needed_once_per_loss_across_restarts(push, fake, api):
    ntfy, poll, pusher = push
    session, store = api.app.state.session, api.app.state.store
    fake.session_expired = True
    assert api.get("/threads", headers=AUTH).status_code == 503
    _settle(pusher)
    assert _titles(ntfy) == [LOGIN]
    for _ in range(3):  # each "restart": fresh pusher, fresh in-memory loss flag, same sqlite
        restarted = Pusher(session, store, topic="sala-test", url="http://ntfy.test", token="tk",
                           transport=httpx.MockTransport(ntfy.handler))
        session.login_needed_hooks[:] = [restarted.on_login_needed]
        session.logged_in_hooks[:] = [restarted.on_logged_in]
        session._loss_notified = False
        api.portal.call(session._lost, "No stored Aula session")
        _settle(restarted)
        assert api.portal.call(restarted.poll_once) == 0
    assert len(ntfy.posts) == 1
    fake.session_expired = False
    _login(api)  # clears the marker: the next loss notifies again
    fake.session_expired = True
    assert api.get("/threads", headers=AUTH).status_code == 503
    _settle(restarted)
    assert api.portal.call(restarted.poll_once) == 0
    assert _titles(ntfy) == [LOGIN, LOGIN]


def test_working_session_without_login_ends_the_loss(push, fake, api):
    ntfy, poll, pusher = push
    session, store = api.app.state.session, api.app.state.store
    client = session.client
    client.close = lambda: asyncio.sleep(0)  # keep it usable after the loss drops it
    fake.session_expired = True
    assert api.get("/threads", headers=AUTH).status_code == 503
    _settle(pusher)
    assert store.state("login_loss") is not None
    fake.session_expired = False
    session.client = client  # e.g. a restart whose stored tokens work again: no login ran
    session._set("ok")
    assert poll() == 0 and store.state("login_loss") is None


def test_item_older_than_seeding_sends_nothing(push, fake):
    ntfy, poll, _ = push
    pid = fake.add_important_post()
    fake.posts[pid]["timestamp"] = fake.posts[403]["timestamp"]  # e.g. slid back into the page
    assert poll() == 0 and ntfy.posts == []


def _strip_latest_sender(fake, tid: int) -> None:
    fake.threads[tid]["latestMessage"].pop("sender")


@pytest.mark.parametrize("error", [HttpRequestError("Forbidden", 403), AulaSessionExpiredError("expired", 401)])
def test_failing_thread_read_affects_only_that_thread(push, fake, monkeypatch, error):
    ntfy, poll, _ = push
    fake.add_direct_message()
    _strip_latest_sender(fake, 9105)
    group_mid = fake.add_message(9102, METTE, "<p>Hue</p>")
    fake.add_important_post()
    calls = []

    async def failing(client, thread_id):
        calls.append(thread_id)
        raise error

    monkeypatch.setattr(mapping, "_thread_meta", failing)
    assert poll() == 2  # the poll still runs and the post still goes out
    assert sorted(p["title"] for p in ntfy.posts) == ["Important post: Børnehuset lukker tidligt på fredag", "New message"]
    assert push[2].store.seen(f"message:9102:{group_mid}")  # the other thread was handled
    assert calls == ["9105"]
    assert poll() == 0 and calls == ["9105"]  # marked seen: not read again


def test_direct_message_with_unknown_sender_says_new_message(push, fake):
    ntfy, poll, _ = push
    fake.add_direct_message()
    _strip_latest_sender(fake, 9105)
    fake.messages[9105][0]["sender"] = None
    assert poll() == 1
    assert [(p["title"], p["click"]) for p in ntfy.posts] == [("New message", "sala://thread/9105")]


def _row(recipients, extra, creator, sender):
    return {
        "id": 1,
        "mailBoxOwner": {"id": GUARDIAN_IP},
        "recipients": [{**r, "leaveTime": None} for r in recipients],
        "extraRecipientsCount": extra,
        "creator": creator,
        "latestMessage": {"id": "m1", "sendDateTime": "2026-11-12T10:00:00+01:00", "sender": sender},
    }


def test_direct_detection_counts_extra_recipients_once():
    mine = {GUARDIAN_IP}
    # Creator/sender are not added on top of extraRecipientsCount (likely counted there).
    row = _row([ME], 1, KASPER, METTE)
    assert is_direct(row, mine)
    e = message_event(row, mine)
    assert (e.notify, e.title) == (True, "New message from Mette Lund")
    assert message_event(_row([ME], 1, METTE, ME), mine).notify is False  # from me
    assert not is_direct(_row([ME, METTE], 1, METTE, METTE), mine)
    # A 1:1 thread whose recipients omit the other person is still direct.
    row = _row([ME], 0, METTE, METTE)
    assert is_direct(row, mine)
    e = message_event(row, mine)
    assert (e.notify, e.title) == (True, "New message from Mette Lund")


def test_download_falls_back_to_library_only_in_fake_mode():
    async def download_file(url):
        return b"fake"

    client = SimpleNamespace(_client=SimpleNamespace(), download_file=download_file)
    url = "https://fake-files.aula.dk/files/x.pdf"
    assert asyncio.run(download_attachment(client, url, fake=True)) == b"fake"
    with pytest.raises(UpstreamFailure):
        asyncio.run(download_attachment(client, url))


def test_ntfy_url_path_is_stripped(caplog):
    with caplog.at_level(logging.ERROR, logger="sala.push"):
        pusher = Pusher(None, None, topic="t", url="https://ntfy.example/sala-topic?x=1")
    assert pusher.url == "https://ntfy.example"
    assert "server root" in caplog.text
    assert Pusher(None, None, topic="t", url="https://ntfy.example/").url == "https://ntfy.example"
