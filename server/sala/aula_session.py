"""Holds the Aula session: stored tokens, the client, and the one MitID login.

Rules:
- Only ``POST /auth/login`` (``SessionManager.login``) ever starts MitID, and it
  never retries on its own: repeated failed MitID attempts can lock the identity.
- Startup and keep-alive only load stored tokens and let the library refresh
  them (``create_client`` + its 401 refresh hook).
- Any auth error on a call (401/403/session-expired/invalid-token, after the
  library's own refresh) triggers one ``get_profile`` probe. Only if the probe
  is also refused is the session gone; a refused call with a working probe
  (step-up for a sensitive thread, say) is a 502 and the session stays.
"""

import asyncio
import inspect
import logging
from collections.abc import Awaitable, Callable
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx
from aula import AulaApiClient, FileTokenStorage
from aula.auth_flow import authenticate, create_client
from aula.http import HttpRequestError

from .fake import FAKE_OTP, FAKE_TOKEN_DATA, FakeAula
from .mapping import TZ, auth_error

_LOGGER = logging.getLogger(__name__)

KEEP_ALIVE_SECONDS = 600


class AuthRequired(Exception):
    """No usable Aula session; the app must show the MitID login (-> 503)."""


class Upstream(Exception):
    """Aula failed or is unreachable (-> 502)."""


class SessionManager:
    def __init__(
        self,
        data_dir: Path,
        username: str | None,
        *,
        fake: bool = False,
        fake_login_seconds: float = 3.0,
    ) -> None:
        self.username = username
        self.fake = fake
        self.fake_login_seconds = fake_login_seconds
        self.fake_aula: FakeAula | None = FakeAula() if fake else None
        self.storage = FileTokenStorage(data_dir / "aula_tokens.json")

        self.state = "needs_login"
        self.otp_code: str | None = None
        self.message: str | None = None
        self.since: datetime | None = datetime.now(TZ)

        self.client: AulaApiClient | None = None
        self._loss_notified = False
        self._profile = None
        self._login_lock = asyncio.Lock()
        self._connect_lock = asyncio.Lock()
        self._login_task: asyncio.Task | None = None
        self._keep_alive_task: asyncio.Task | None = None
        # Hook for the push stage: called (sync or async, no args) whenever the
        # session is lost and a MitID login is needed.
        self.login_needed_hooks: list[Callable[[], Any]] = []

    # --- lifecycle -----------------------------------------------------------

    async def start(self) -> None:
        if not self.fake:
            if await self.storage.load():
                # Optimistic: tokens exist. Connect now; if Aula is merely
                # unreachable we stay "ok" and connect lazily on the next call.
                self.state = "ok"
                try:
                    await self._connect()
                except AuthRequired:
                    pass
                except Upstream as e:
                    _LOGGER.warning("Aula unreachable at startup, will retry: %s", e)
            else:
                await self._lost("No stored Aula session")
        self._keep_alive_task = asyncio.create_task(self._keep_alive_loop())

    async def stop(self) -> None:
        for task in (self._keep_alive_task, self._login_task):
            if task and not task.done():
                task.cancel()
        if self.client:
            await self.client.close()
            self.client = None

    # --- status / login ------------------------------------------------------

    def status(self) -> dict:
        return {
            "state": self.state,
            "otpCode": self.otp_code if self.state == "logging_in" else None,
            "qr": None,
            "message": self.message,
            "since": self.since.isoformat(timespec="seconds") if self.since else None,
        }

    def _set(self, state: str, message: str | None = None) -> None:
        self.state = state
        self.message = message
        self.since = datetime.now(TZ)
        if state != "logging_in":
            self.otp_code = None

    async def login(self) -> dict:
        """Start one MitID login. No-op while logging in or already logged in."""
        async with self._login_lock:
            if self.state in ("logging_in", "ok"):
                return self.status()
            if not self.fake and not self.username:
                self._set("error", "AULA_USERNAME is not set on the server")
                return self.status()
            self._set("logging_in")
            self._login_task = asyncio.create_task(self._run_login())
        return self.status()

    def _on_otp_code(self, code: str) -> None:
        # Must never raise: the installed aula wraps callback errors as MitID failures.
        try:
            self.otp_code = str(code)
        except Exception:  # noqa: BLE001
            _LOGGER.exception("could not record OTP code")

    async def _run_login(self) -> None:
        try:
            if self.fake:
                lead = min(0.5, self.fake_login_seconds / 5)
                await asyncio.sleep(lead)
                self._on_otp_code(FAKE_OTP)
                await asyncio.sleep(self.fake_login_seconds - lead)
                client = await create_client(dict(FAKE_TOKEN_DATA), http_client=self.fake_aula)
            else:
                # force_login: never reuse/refresh here, this IS the MitID login.
                token_data = await authenticate(
                    self.username,
                    self.storage,
                    on_otp_code=self._on_otp_code,
                    force_login=True,
                    auth_method="app",
                )
                client = await create_client(token_data, token_storage=self.storage)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - every failure ends in "error", no retry
            _LOGGER.warning("MitID login failed: %s", e)
            self._set("error", str(e) or type(e).__name__)
            return
        old, self.client, self._profile = self.client, client, None
        if old and old is not client:
            await old.close()
        self._loss_notified = False
        self._set("ok")
        _LOGGER.info("Aula login complete")

    # --- client access -------------------------------------------------------

    async def _lost(self, reason: str) -> None:
        if self._loss_notified:
            return  # already lost; hooks fire once per loss
        self._loss_notified = True
        _LOGGER.warning("Aula session lost: %s", reason)
        old, self.client, self._profile = self.client, None, None
        if old:
            try:
                await old.close()
            except Exception:  # noqa: BLE001
                pass
        self._set("needs_login", reason)
        for hook in list(self.login_needed_hooks):
            try:
                result = hook()
                if inspect.isawaitable(result):
                    await result
            except Exception:  # noqa: BLE001
                _LOGGER.exception("login-needed hook failed")

    async def _connect(self) -> AulaApiClient:
        """Build the client from stored tokens (single-flight). Never MitID."""
        async with self._connect_lock:
            if self.client:
                return self.client
            token_data = await self.storage.load()
            if not token_data:
                await self._lost("No stored Aula session")
                raise AuthRequired
            try:
                self.client = await create_client(token_data, token_storage=self.storage)
            except ValueError as e:
                await self._lost(f"Stored session unusable: {e}")
                raise AuthRequired from e
            except Exception as e:  # noqa: BLE001
                if auth_error(e):
                    # The library treats this as rejected cookies too
                    # (authenticate_and_create_client).
                    await self._lost("Aula session expired")
                    raise AuthRequired from e
                raise Upstream(f"Could not reach Aula: {e}") from e
            return self.client

    async def call[T](self, fn: Callable[[AulaApiClient], Awaitable[T]]) -> T:
        """Run ``fn(client)``, mapping failures to AuthRequired / Upstream."""
        if self.state != "ok":
            raise AuthRequired
        client = self.client or await self._connect()
        try:
            return await fn(client)
        except (AuthRequired, Upstream):
            raise
        except Exception as e:
            if auth_error(e):
                await self._probe(client, e)
            if isinstance(e, (HttpRequestError, httpx.HTTPError)):
                raise Upstream(str(e) or type(e).__name__) from e
            raise

    async def _probe(self, client: AulaApiClient, original: Exception) -> None:
        """Confirm with one cheap read that the session is really gone."""
        try:
            await client.get_profile()
        except Exception as e:  # noqa: BLE001
            if auth_error(e):
                await self._lost("Aula session expired")
                raise AuthRequired from e
            raise Upstream(f"{original} (and the session check failed: {e})") from original
        raise Upstream(f"Aula refused the request: {original}") from original

    async def profile(self, client: AulaApiClient):
        """The user's profile, cached per client (get_profile costs two requests)."""
        if self._profile is None or self._profile[0] is not client:
            self._profile = (client, await client.get_profile())
        return self._profile[1]

    # --- keep-alive ----------------------------------------------------------

    async def _keep_alive_loop(self) -> None:
        while True:
            await asyncio.sleep(KEEP_ALIVE_SECONDS)
            try:
                await self.keep_alive_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                _LOGGER.exception("keep-alive failed")

    async def keep_alive_once(self) -> None:
        if self.state != "ok":
            return
        try:
            if self.client is None:
                await self._connect()
                return
            if not await self.client.keep_alive():
                # False also means "network down"; only a probe can tell.
                await self.call(lambda c: c.get_profile())
        except (AuthRequired, Upstream) as e:
            _LOGGER.info("keep-alive: %s", type(e).__name__)
