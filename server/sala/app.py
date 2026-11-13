"""Sala server: FastAPI routes implementing ../API.md."""

import logging
import mimetypes
import os
import secrets
from contextlib import asynccontextmanager
from datetime import date
from pathlib import Path
from typing import Literal
from urllib.parse import quote

import httpx
from fastapi import Depends, FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, StrictBool
from starlette.exceptions import HTTPException as StarletteHTTPException

from aula.http import HttpRequestError

from . import mapping as m
from .aula_session import AuthRequired, SessionManager, Upstream
from .push import Pusher
from .store import Store
from .translate import DEFAULT_MODEL, Translator

_LOGGER = logging.getLogger(__name__)


class ApiError(Exception):
    def __init__(self, status: int, error: str, message: str | None = None) -> None:
        self.status, self.error, self.message = status, error, message


def _err(status: int, error: str, message: str | None = None) -> JSONResponse:
    body = {"error": error}
    if message is not None:
        body["message"] = message
    return JSONResponse(body, status_code=status)


def _setup_logging() -> None:
    """Show Sala's INFO logs (e.g. "push: seeded ...") under uvicorn, which
    only configures its own loggers."""
    log = logging.getLogger("sala")
    if log.level == logging.NOTSET:
        log.setLevel(logging.INFO)
    if not log.handlers and not logging.getLogger().handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(levelname)s:     %(name)s: %(message)s"))
        log.addHandler(handler)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _setup_logging()
    token = os.environ.get("SALA_TOKEN")
    if not token:
        raise RuntimeError("SALA_TOKEN must be set")
    data_dir = Path(os.environ.get("SALA_DATA_DIR", "./data"))
    data_dir.mkdir(parents=True, exist_ok=True)
    fake = os.environ.get("SALA_FAKE") == "1"
    app.state.token = token
    app.state.store = Store(data_dir / "sala.sqlite3")
    app.state.thread_rows = {}  # thread id -> last listed getThreads row (for PATCH /threads/{id})
    app.state.session = SessionManager(
        data_dir,
        os.environ.get("AULA_USERNAME"),
        fake=fake,
        fake_login_seconds=float(os.environ.get("SALA_FAKE_LOGIN_SECONDS", "3")),
    )
    app.state.translator = None
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip() or None
    if api_key or (fake and os.environ.get("SALA_FAKE_TRANSLATE") == "1"):
        app.state.translator = Translator(
            app.state.store,
            api_key,
            model=os.environ.get("SALA_TRANSLATE_MODEL") or DEFAULT_MODEL,
            lang=os.environ.get("SALA_TRANSLATE_LANG") or "English",
        )
    app.state.pusher = None
    topic = os.environ.get("NTFY_TOPIC")
    if topic:
        app.state.pusher = Pusher(
            app.state.session,
            app.state.store,
            topic=topic,
            url=os.environ.get("NTFY_URL") or "https://ntfy.sh",
            token=os.environ.get("NTFY_TOKEN") or None,
            poll_seconds=float(os.environ.get("POLL_SECONDS", "300")),
        )
        # Before start(): a start with no stored session should notify too.
        app.state.session.login_needed_hooks.append(app.state.pusher.on_login_needed)
        app.state.session.logged_in_hooks.append(app.state.pusher.on_logged_in)
    await app.state.session.start()
    if app.state.pusher:
        app.state.pusher.start()
    _LOGGER.info("Sala started (fake=%s, data=%s, push=%s)", fake, data_dir, bool(topic))
    try:
        yield
    finally:
        if app.state.pusher:
            await app.state.pusher.stop()
        await app.state.session.stop()
        app.state.store.close()


def require_token(request: Request) -> None:
    header = request.headers.get("authorization", "")
    scheme, _, given = header.partition(" ")
    if scheme.lower() != "bearer" or not secrets.compare_digest(given.strip().encode(), request.app.state.token.encode()):
        raise ApiError(401, "unauthorized")


app = FastAPI(
    title="Sala",
    lifespan=lifespan,
    dependencies=[Depends(require_token)],
    docs_url=None,  # the docs routes would bypass the bearer check
    redoc_url=None,
    openapi_url=None,
)


@app.middleware("http")
async def read_only(request: Request, call_next):
    """SALA_READ_ONLY=1 blocks every write to Aula (pickup, sick, save, reply, holidays, absences,
    thread and folder changes), for debugging live."""
    if (
        os.environ.get("SALA_READ_ONLY") == "1"
        and request.method in ("PUT", "POST", "PATCH", "DELETE")
        and not request.url.path.startswith(("/auth/", "/debug/", "/translate"))
    ):
        return JSONResponse(
            {"error": "read_only", "message": "Read-only mode: nothing was sent to Aula."}, status_code=403
        )
    return await call_next(request)


@app.exception_handler(ApiError)
async def _api_error(request: Request, exc: ApiError):
    return _err(exc.status, exc.error, exc.message)


@app.exception_handler(AuthRequired)
async def _auth_required(request: Request, exc: AuthRequired):
    return _err(503, "auth_required")


@app.exception_handler(Upstream)
async def _upstream(request: Request, exc: Upstream):
    return _err(502, "upstream", str(exc) or "Aula request failed")


@app.exception_handler(m.UpstreamFailure)
async def _upstream_failure(request: Request, exc: m.UpstreamFailure):
    return _err(502, "upstream", str(exc))


@app.exception_handler(m.BadRequest)
async def _bad_request(request: Request, exc: m.BadRequest):
    return _err(400, "bad_request", str(exc))


@app.exception_handler(m.Conflict)
async def _conflict(request: Request, exc: m.Conflict):
    return _err(409, "conflict", str(exc))


@app.exception_handler(m.NotFound)
async def _not_found(request: Request, exc: m.NotFound):
    return _err(404, "not_found", str(exc))


@app.exception_handler(RequestValidationError)
async def _validation(request: Request, exc: RequestValidationError):
    first = exc.errors()[0] if exc.errors() else {}
    where = ".".join(str(p) for p in first.get("loc", ()) if p != "body")
    return _err(400, "bad_request", f"{where}: {first.get('msg', 'invalid request')}".strip(": "))


@app.exception_handler(StarletteHTTPException)
async def _http(request: Request, exc: StarletteHTTPException):
    return _err(exc.status_code, {404: "not_found", 405: "method_not_allowed"}.get(exc.status_code, "error"))


@app.exception_handler(Exception)
async def _unexpected(request: Request, exc: Exception):
    _LOGGER.exception("unhandled error on %s %s", request.method, request.url.path)
    return _err(502, "upstream", f"{type(exc).__name__}: {exc}")


def session(request: Request) -> SessionManager:
    return request.app.state.session


def store(request: Request) -> Store:
    return request.app.state.store


# --- auth --------------------------------------------------------------------


@app.get("/auth/status")
async def auth_status(s: SessionManager = Depends(session)):
    return s.status()


@app.post("/auth/login")
async def auth_login(s: SessionManager = Depends(session)):
    return await s.login()


# --- features & translation -------------------------------------------------


@app.get("/features")
async def features(request: Request):
    return {"translate": request.app.state.translator is not None}


def translator(request: Request) -> Translator:
    """The translator, or 404 (checked before the body, so off is always 404)."""
    if request.app.state.translator is None:
        raise ApiError(404, "not_enabled")
    return request.app.state.translator


class TranslateIn(BaseModel):
    texts: list[str]


@app.post("/translate")
async def translate(body: TranslateIn, t: Translator = Depends(translator)):
    if len(body.texts) > 50:
        raise ApiError(400, "bad_request", "at most 50 texts")
    if any(len(x) > 20_000 for x in body.texts):
        raise ApiError(400, "bad_request", "each text must be at most 20000 characters")
    return {"texts": await t.translate(body.texts)}


# --- today -------------------------------------------------------------------


@app.get("/today")
async def today(s: SessionManager = Depends(session), st: Store = Depends(store)):
    async def run(client):
        profile = await s.profile(client)
        days = [await m.load_child_day(client, c) for c in profile.children]
        children = [m.child_out(d, st.register_attachment) for d in days]
        child_ids = [c.id for c in profile.children]
        attention = await m._optional("holiday requests", m.holiday_requests(client, child_ids)) or []
        thread_rows = await m._optional("threads", m.threads(client)) or []
        attention += m.unread_threads_attention(thread_rows)
        groups = [c["group"] for c in children if c["group"]]
        upcoming = await m._optional("upcoming", m.upcoming(client, profile.children, groups)) or []
        posts = await m._optional("posts", m.posts(client, profile, st.register_attachment)) or []
        return {
            "date": m.aula_today().isoformat(),
            "children": children,
            "attention": attention,
            "upcoming": upcoming,
            "posts": posts,
        }

    return await s.call(run)


# --- pickup and sick ---------------------------------------------------------


class PickupIn(BaseModel):
    time: str
    by: str
    note: str | None = None


async def _child_response(st: Store, client, child) -> dict:
    return m.child_out(await m.load_child_day(client, child), st.register_attachment)


@app.get("/children/{child_id}/pickup")
async def get_pickup(child_id: int, s: SessionManager = Depends(session)):
    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        return m.pickup_out(await m.load_child_day(client, child, with_people=True))

    return await s.call(run)


@app.put("/children/{child_id}/pickup")
async def put_pickup(
    child_id: int, body: PickupIn, s: SessionManager = Depends(session), st: Store = Depends(store)
):
    if not m.valid_hhmm(body.time):
        raise ApiError(400, "bad_request", "time must be HH:mm")

    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        await m.set_pickup(client, child, body.time, body.by, body.note)
        return await _child_response(st, client, child)

    return await s.call(run)


async def _sick(s: SessionManager, st: Store, child_id: int, sick: bool) -> dict:
    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        await m.set_sick(client, child, sick)
        return await _child_response(st, client, child)

    return await s.call(run)


@app.post("/children/{child_id}/sick")
async def report_sick(child_id: int, s: SessionManager = Depends(session), st: Store = Depends(store)):
    return await _sick(s, st, child_id, True)


@app.delete("/children/{child_id}/sick")
async def unreport_sick(child_id: int, s: SessionManager = Depends(session), st: Store = Depends(store)):
    return await _sick(s, st, child_id, False)


# --- holidays ----------------------------------------------------------------


@app.get("/holiday-requests/{request_id}")
async def get_holiday_request(request_id: str, s: SessionManager = Depends(session)):
    async def run(client):
        return await m.holiday_request(client, await s.profile(client), request_id)

    return await s.call(run)


class HolidayDayIn(BaseModel):
    date: str
    coming: bool
    entryTime: str | None = None
    exitTime: str | None = None


class HolidayChildIn(BaseModel):
    id: int
    days: list[HolidayDayIn]
    comment: str = ""


class HolidayAnswerIn(BaseModel):
    children: list[HolidayChildIn]


@app.post("/holiday-requests/{request_id}")
async def answer_holiday_request(request_id: str, body: HolidayAnswerIn, s: SessionManager = Depends(session)):
    answers: dict[int, m.ChildAnswer] = {}
    for c in body.children:
        if c.id in answers:
            raise ApiError(400, "bad_request", f"child {c.id} is listed twice")
        answers[c.id] = m.ChildAnswer([m.DayAnswer(d.date, d.coming, d.entryTime, d.exitTime) for d in c.days], c.comment)

    async def run(client):
        profile = await s.profile(client)
        await m.answer_holiday_request(client, profile, request_id, answers)
        return await m.holiday_request(client, profile, request_id)

    return await s.call(run)


class AbsenceIn(BaseModel):
    childIds: list[int]
    startDate: date
    endDate: date
    comment: str = ""


@app.post("/absences")
async def add_absence(body: AbsenceIn, s: SessionManager = Depends(session)):
    async def run(client):
        await m.add_absence(client, await s.profile(client), body.childIds, body.startDate, body.endDate, body.comment)

    await s.call(run)
    return {"ok": True}


# --- posts & attachments -----------------------------------------------------


@app.get("/posts")
async def list_posts(
    page: int = Query(1, ge=1, le=100), s: SessionManager = Depends(session), st: Store = Depends(store)
):
    async def run(client):
        return await m.posts(client, await s.profile(client), st.register_attachment, page=page)

    return await s.call(run)


@app.get("/albums")
async def list_albums(
    page: int = Query(1, ge=1, le=100), s: SessionManager = Depends(session), st: Store = Depends(store)
):
    async def run(client):
        return await m.albums(client, await s.profile(client), st.register_attachment, page=page)

    return await s.call(run)


@app.get("/albums/{album_id}/photos")
async def list_album_photos(
    album_id: int, page: int = Query(1, ge=1, le=100), s: SessionManager = Depends(session), st: Store = Depends(store)
):
    async def run(client):
        return await m.album_photos(client, await s.profile(client), album_id, st.register_attachment, page=page)

    return await s.call(run)


async def _save(s: SessionManager, post_id: int, saved: bool) -> dict:
    await s.call(lambda client: m.set_bookmark(client, post_id, saved))
    return {"saved": saved}


@app.post("/posts/{post_id}/save")
async def save_post(post_id: int, s: SessionManager = Depends(session)):
    return await _save(s, post_id, True)


@app.delete("/posts/{post_id}/save")
async def unsave_post(post_id: int, s: SessionManager = Depends(session)):
    return await _save(s, post_id, False)


@app.get("/attachments/{att_id}")
async def attachment(att_id: str, s: SessionManager = Depends(session), st: Store = Depends(store)):
    found = st.attachment(att_id)
    if found is None:
        raise ApiError(404, "not_found")
    url, name = found  # a URL Aula gave us, never one from the client
    if not m.file_url_allowed(url):  # e.g. a link URL registered by older code
        raise ApiError(404, "not_found")

    async def run(client):
        try:
            return await m.download_attachment(client, url, fake=s.fake)
        except (httpx.HTTPError, HttpRequestError) as e:
            raise Upstream(f"Could not download attachment: {e}") from e

    data = await s.call(run)
    content_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    ascii_name = name.encode("ascii", "replace").decode().replace('"', "")
    disposition = f"inline; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"
    # An id names one Aula file (pictures: one picture), so the app may keep its copy.
    headers = {"Content-Disposition": disposition, "Cache-Control": "private, max-age=604800"}
    return Response(content=data, media_type=content_type, headers=headers)


# --- messages ----------------------------------------------------------------


def thread_rows(request: Request) -> dict[str, dict]:
    return request.app.state.thread_rows


@app.get("/threads")
async def list_threads(
    request: Request,
    page: int = Query(0, ge=0, le=100),
    folder: int | None = Query(None, ge=1),
    s: SessionManager = Depends(session),
    st: Store = Depends(store),
):
    return await s.call(
        lambda client: m.threads(client, page, folder, seen=thread_rows(request), register=st.register_attachment)
    )


class ThreadPatchIn(BaseModel):
    muted: StrictBool = False
    starred: StrictBool = False
    folderId: int | None = None


@app.patch("/threads/{thread_id}")
async def patch_thread(
    thread_id: str, body: ThreadPatchIn, request: Request, s: SessionManager = Depends(session), st: Store = Depends(store)
):
    if not thread_id.isdigit():
        raise ApiError(404, "not_found")
    changes = {k: getattr(body, k) for k in ("muted", "starred", "folderId") if k in body.model_fields_set}
    if not changes:
        raise ApiError(400, "bad_request", "nothing to change")
    return await s.call(lambda client: m.update_thread(client, thread_rows(request), thread_id, changes, st.register_attachment))


@app.get("/threads/{thread_id}")
async def get_thread(thread_id: str, s: SessionManager = Depends(session), st: Store = Depends(store)):
    if not thread_id.isdigit():
        raise ApiError(404, "not_found")

    async def run(client):
        return await m.thread_detail(client, await s.profile(client), thread_id, st.register_attachment)

    return await s.call(run)


class ReplyIn(BaseModel):
    text: str
    audience: Literal["everyone", "sender"]
    messageId: str | None = None


@app.post("/threads/{thread_id}/reply")
async def reply(thread_id: str, body: ReplyIn, s: SessionManager = Depends(session)):
    if not thread_id.isdigit():
        raise ApiError(404, "not_found")
    if not body.text.strip():
        raise ApiError(400, "bad_request", "text is empty")
    if body.audience == "sender" and not body.messageId:
        raise ApiError(400, "bad_request", "messageId is required for audience sender")

    async def run(client):
        if body.audience == "everyone":
            return await m.reply_all(client, thread_id, body.text)
        return await m.reply_sender(client, await s.profile(client), thread_id, body.messageId, body.text)

    new_id = await s.call(run)
    return {"ok": True, "threadId": new_id}


# --- folders -----------------------------------------------------------------


class FolderIn(BaseModel):
    name: str


@app.get("/folders")
async def list_folders(s: SessionManager = Depends(session)):
    return await s.call(m.folders)


@app.post("/folders")
async def create_folder(body: FolderIn, s: SessionManager = Depends(session)):
    m.folder_name(body.name)  # 400 before touching Aula
    return await s.call(lambda client: m.create_folder(client, body.name))


@app.patch("/folders/{folder_id}")
async def rename_folder(folder_id: int, body: FolderIn, s: SessionManager = Depends(session)):
    m.folder_name(body.name)
    return await s.call(lambda client: m.rename_folder(client, folder_id, body.name))


@app.delete("/folders/{folder_id}")
async def delete_folder(folder_id: int, s: SessionManager = Depends(session)):
    await s.call(lambda client: m.delete_folder(client, folder_id))
    return {"ok": True}


# --- fake-mode helpers (push testing) ---------------------------------------


def fake_aula(request: Request):
    """The fake Aula, or 404: these routes only exist with SALA_FAKE=1."""
    fake = request.app.state.session.fake_aula
    if fake is None:
        raise ApiError(404, "not_found")
    return fake


@app.post("/debug/fake/new-message")
async def debug_new_message(fake=Depends(fake_aula)):
    return {"ok": True, "threadId": str(fake.add_direct_message())}


@app.post("/debug/fake/important-post")
async def debug_important_post(fake=Depends(fake_aula)):
    return {"ok": True, "postId": fake.add_important_post()}


@app.post("/debug/fake/holiday-request")
async def debug_holiday_request(fake=Depends(fake_aula)):
    return {"ok": True, "id": fake.add_holiday_request()}


