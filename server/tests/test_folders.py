"""Thread mute/star/move and message folders (API.md "Messages", "Folders").
Payloads are asserted as the fake Aula recorded them."""

import pytest

from conftest import AUTH

SUB = 500000  # fake subscription id = thread id + SUB


def _row(api, tid: str, folder: int | None = None) -> dict | None:
    q = f"?folder={folder}" if folder else ""
    return next((t for t in api.get(f"/threads{q}", headers=AUTH).json() if t["id"] == tid), None)


def test_summary_has_folder_id(api):
    row = _row(api, "9101")
    assert row["folderId"] is None and row["muted"] is False and row["starred"] is False
    assert _row(api, "9103")["muted"] is True and _row(api, "9104")["starred"] is True


def test_mute_and_star(api, fake):
    api.get("/threads", headers=AUTH)
    r = api.patch("/threads/9101", headers=AUTH, json={"muted": True, "starred": True})
    assert r.status_code == 200, r.text
    assert r.json() == {**_row(api, "9101"), "muted": True, "starred": True}
    assert fake.writes_for("messaging.setThreadsMuted") == [
        {"muted": True, "subscriptionIds": [9101 + SUB], "commonInboxId": None, "otpInboxId": None}
    ]
    assert fake.writes_for("messaging.setThreadsMarked") == [
        {"threadIds": [], "subscriptionIds": [9101 + SUB], "marked": True, "commonInboxId": None, "otpInboxId": None}
    ]
    assert fake.writes_for("messaging.moveThreadsToFolder") == []
    api.patch("/threads/9101", headers=AUTH, json={"starred": False})
    assert _row(api, "9101")["starred"] is False and _row(api, "9101")["muted"] is True


def test_move_to_folder_and_back(api, fake):
    api.get("/threads", headers=AUTH)
    r = api.patch("/threads/9102", headers=AUTH, json={"folderId": 72})
    assert r.status_code == 200 and r.json()["folderId"] == 72
    assert _row(api, "9102") is None
    assert _row(api, "9102", folder=72)["folderId"] == 72
    r = api.patch("/threads/9102", headers=AUTH, json={"folderId": None})
    assert r.json()["folderId"] is None
    assert _row(api, "9102")["folderId"] is None and _row(api, "9102", folder=72) is None
    assert fake.writes_for("messaging.moveThreadsToFolder") == [
        {"folderId": 72, "threadIds": [], "subscriptionIds": [9102 + SUB], "commonInboxId": None},
        {"folderId": None, "threadIds": [], "subscriptionIds": [9102 + SUB], "commonInboxId": None},
    ]


def test_folder_listing_pages(api):
    skole = api.get("/threads?folder=71", headers=AUTH).json()
    assert [t["id"] for t in skole] == ["9106"] and skole[0]["folderId"] == 71
    assert api.get("/threads?folder=71&page=1", headers=AUTH).json() == []
    assert api.get("/threads?folder=72", headers=AUTH).json() == []
    assert "9106" not in {t["id"] for t in api.get("/threads", headers=AUTH).json()}
    assert api.get("/threads?folder=0", headers=AUTH).status_code == 400


def test_thread_in_folder_can_be_changed_after_listing_it(api, fake):
    api.get("/threads?folder=71", headers=AUTH)
    r = api.patch("/threads/9106", headers=AUTH, json={"muted": True})
    assert r.status_code == 200 and r.json()["folderId"] == 71 and r.json()["muted"] is True
    assert fake.writes_for("messaging.setThreadsMuted")[0]["subscriptionIds"] == [9106 + SUB]


def test_unlisted_thread_falls_back_to_inbox_first_page(api, fake):
    # Nothing listed yet: the server reads the inbox's first page itself.
    assert api.patch("/threads/9105", headers=AUTH, json={"starred": True}).status_code == 200
    # Not on that page and never listed: 409, nothing written.
    r = api.patch("/threads/9106", headers=AUTH, json={"starred": True})
    assert (r.status_code, r.json()["error"]) == (409, "conflict")
    assert len(fake.writes_for("messaging.setThreadsMarked")) == 1


@pytest.mark.parametrize(
    "body",
    [{}, {"muted": None}, {"starred": "yes"}, {"folderId": 70}, {"folderId": 999}, {"folderId": "x"}],
)
def test_patch_thread_validation(api, fake, body):
    api.get("/threads", headers=AUTH)
    r = api.patch("/threads/9101", headers=AUTH, json=body)
    assert (r.status_code, r.json()["error"]) == (400, "bad_request"), r.text
    assert fake.writes == []


def test_patch_unknown_thread_id(api):
    assert api.patch("/threads/abc", headers=AUTH, json={"muted": True}).status_code == 404


def test_folders_exclude_deleted_folder(api):
    assert api.get("/folders", headers=AUTH).json() == [{"id": 71, "name": "Skole"}, {"id": 72, "name": "Gemt"}]


def test_create_rename_delete_folder(api, fake):
    r = api.post("/folders", headers=AUTH, json={"name": "  Fødselsdage  "})
    assert r.status_code == 200, r.text
    new = r.json()
    assert new["name"] == "Fødselsdage" and new["id"] not in (70, 71, 72)
    assert fake.writes_for("messaging.createFolder") == [{"folderName": "Fødselsdage"}]

    r = api.patch(f"/folders/{new['id']}", headers=AUTH, json={"name": "Fest"})
    assert r.json() == {"id": new["id"], "name": "Fest"}
    assert fake.writes_for("messaging.updateFolder") == [{"folderName": "Fest", "folderId": new["id"]}]
    assert {"id": new["id"], "name": "Fest"} in api.get("/folders", headers=AUTH).json()

    assert api.delete(f"/folders/{new['id']}", headers=AUTH).json() == {"ok": True}
    assert fake.writes_for("messaging.deleteFolder") == [{"folderId": new["id"]}]
    assert new["id"] not in {f["id"] for f in api.get("/folders", headers=AUTH).json()}


def test_deleting_a_folder_deletes_its_threads(api, fake):
    api.delete("/folders/71", headers=AUTH)
    assert api.get("/threads?folder=71", headers=AUTH).json() == []
    assert "9106" not in {t["id"] for t in api.get("/threads", headers=AUTH).json()}


@pytest.mark.parametrize("name", ["", "   ", "x" * 101])
def test_folder_name_validation(api, fake, name):
    assert api.post("/folders", headers=AUTH, json={"name": name}).status_code == 400
    assert api.patch("/folders/71", headers=AUTH, json={"name": name}).status_code == 400
    assert api.post("/folders", headers=AUTH, json={}).status_code == 400
    assert fake.writes == []


def test_folder_name_of_100_is_ok(api):
    assert api.post("/folders", headers=AUTH, json={"name": "x" * 100}).status_code == 200


@pytest.mark.parametrize("folder_id", [70, 999])
def test_unknown_or_system_folder_is_404(api, fake, folder_id):
    assert api.patch(f"/folders/{folder_id}", headers=AUTH, json={"name": "Ny"}).status_code == 404
    assert api.delete(f"/folders/{folder_id}", headers=AUTH).status_code == 404
    assert fake.writes == []


def test_read_only_blocks_thread_and_folder_writes(api, fake, monkeypatch):
    api.get("/threads", headers=AUTH)
    monkeypatch.setenv("SALA_READ_ONLY", "1")
    for method, path, body in [
        ("PATCH", "/threads/9101", {"muted": True}),
        ("POST", "/folders", {"name": "Ny"}),
        ("PATCH", "/folders/71", {"name": "Ny"}),
        ("DELETE", "/folders/71", None),
    ]:
        r = api.request(method, path, headers=AUTH, json=body)
        assert (r.status_code, r.json()["error"]) == (403, "read_only"), (method, path)
    assert api.get("/folders", headers=AUTH).status_code == 200
    assert fake.writes == []
