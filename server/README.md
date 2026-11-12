# sala server

Home server that holds the Aula session (MitID login) and serves the JSON API in [`../API.md`](../API.md) to the iOS app. Personal use only.

## Run

```sh
cd server
SALA_TOKEN=... AULA_USERNAME=... uv run uvicorn sala.app:app --host 0.0.0.0 --port 8000
```

| Env | Meaning |
| --- | --- |
| `SALA_TOKEN` | Required. Bearer token the app sends (`Authorization: Bearer ...`). |
| `AULA_USERNAME` | MitID username used by `POST /auth/login`. |
| `SALA_DATA_DIR` | Default `./data`. Holds `aula_tokens.json` (Aula session) and `sala.sqlite3` (device tokens, attachment ids). |
| `SALA_FAKE` | `1` = fake Aula, no network (see below). |
| `SALA_FAKE_LOGIN_SECONDS` | Fake MitID duration, default `3`. |

On start the server loads the stored session and lets the library refresh it. It never starts MitID by itself: when the session is gone, API calls answer `503 auth_required` until the app calls `POST /auth/login` (one attempt, no automatic retry; a failure shows as `state: error`). A keep-alive runs every 10 minutes.

## Fake mode

```sh
cd server && SALA_FAKE=1 SALA_TOKEN=dev uv run uvicorn sala.app:app --host 0.0.0.0 --port 8000
```

`sala/fake.py` fakes Aula at the HTTP layer (the library's `HttpClient`), so the real client and mapping code run on top of it. Data: daycare "Børnehuset", child Oskar in "Stue", a weekly pickup template, 2 open holiday requests (one due tomorrow), 5 threads, 3 posts with a PDF and a PNG. Writes are recorded (`FakeAula.writes`) and reflected in later reads. It starts in `needs_login`; `POST /auth/login` shows OTP `482915` for about 3 seconds, then `ok`.

## Tests

```sh
cd server && uv run pytest
```
