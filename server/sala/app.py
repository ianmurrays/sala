"""Sala server: FastAPI routes implementing ../API.md."""

import logging
import mimetypes
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal
from urllib.parse import quote

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

from aula.http import HttpRequestError

from . import mapping as m
from .aula_session import AuthRequired, SessionManager, Upstream
from .store import Store

_LOGGER = logging.getLogger(__name__)


class ApiError(Exception):
    def __init__(self, status: int, error: str, message: str | None = None) -> None:
        self.status, self.error, self.message = status, error, message


def _err(status: int, error: str, message: str | None = None) -> JSONResponse:
    body = {"error": error}
    if message is not None:
        body["message"] = message
    return JSONResponse(body, status_code=status)


@asynccontextmanager
async def lifespan(app: FastAPI):
    token = os.environ.get("SALA_TOKEN")
    if not token:
        raise RuntimeError("SALA_TOKEN must be set")
    data_dir = Path(os.environ.get("SALA_DATA_DIR", "./data"))
    data_dir.mkdir(parents=True, exist_ok=True)
    fake = os.environ.get("SALA_FAKE") == "1"
    app.state.token = token
    app.state.store = Store(data_dir / "sala.sqlite3")
    app.state.session = SessionManager(
        data_dir,
        os.environ.get("AULA_USERNAME"),
        fake=fake,
        fake_login_seconds=float(os.environ.get("SALA_FAKE_LOGIN_SECONDS", "3")),
    )
    await app.state.session.start()
    _LOGGER.info("Sala started (fake=%s, data=%s)", fake, data_dir)
    try:
        yield
    finally:
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


# --- today -------------------------------------------------------------------


@app.get("/today")
async def today(s: SessionManager = Depends(session), st: Store = Depends(store)):
    async def run(client):
        profile = await s.profile(client)
        days = [await m.load_child_day(client, c) for c in profile.children]
        children = [m.child_out(d) for d in days]
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


async def _child_response(s: SessionManager, client, child) -> dict:
    return m.child_out(await m.load_child_day(client, child))


@app.get("/children/{child_id}/pickup")
async def get_pickup(child_id: int, s: SessionManager = Depends(session)):
    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        return m.pickup_out(await m.load_child_day(client, child, with_people=True))

    return await s.call(run)


@app.put("/children/{child_id}/pickup")
async def put_pickup(child_id: int, body: PickupIn, s: SessionManager = Depends(session)):
    if m.hhmm(body.time) != body.time:
        raise ApiError(400, "bad_request", "time must be HH:mm")

    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        await m.set_pickup(client, child, body.time, body.by, body.note)
        return await _child_response(s, client, child)

    return await s.call(run)


async def _sick(s: SessionManager, child_id: int, sick: bool) -> dict:
    async def run(client):
        child = m.find_child(await s.profile(client), child_id)
        await m.set_sick(client, child, sick)
        return await _child_response(s, client, child)

    return await s.call(run)


@app.post("/children/{child_id}/sick")
async def report_sick(child_id: int, s: SessionManager = Depends(session)):
    return await _sick(s, child_id, True)


@app.delete("/children/{child_id}/sick")
async def unreport_sick(child_id: int, s: SessionManager = Depends(session)):
    return await _sick(s, child_id, False)


# --- posts & attachments -----------------------------------------------------


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

    async def run(client):
        try:
            return await client.download_file(url)
        except (httpx.HTTPError, HttpRequestError) as e:
            raise Upstream(f"Could not download attachment: {e}") from e

    data = await s.call(run)
    content_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
    ascii_name = name.encode("ascii", "replace").decode().replace('"', "")
    disposition = f"inline; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"
    return Response(content=data, media_type=content_type, headers={"Content-Disposition": disposition})


# --- messages ----------------------------------------------------------------


@app.get("/threads")
async def list_threads(s: SessionManager = Depends(session)):
    return await s.call(m.threads)


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


# --- push --------------------------------------------------------------------


class DeviceIn(BaseModel):
    token: str


@app.post("/devices")
async def register_device(body: DeviceIn, st: Store = Depends(store)):
    token = body.token.strip()
    if not token or any(c not in "0123456789abcdefABCDEF" for c in token):
        raise ApiError(400, "bad_request", "token must be the APNs device token in hex")
    st.add_device(token.lower())
    return {"ok": True}
