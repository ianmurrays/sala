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
| `SALA_DATA_DIR` | Default `./data`. Holds `aula_tokens.json` (Aula session) and `sala.sqlite3` (attachment ids, push seen-set). |
| `SALA_FAKE` | `1` = fake Aula, no network (see below). |
| `SALA_FAKE_LOGIN_SECONDS` | Fake MitID duration, default `3`. |
| `SALA_EXTRA_FILE_HOSTS` | Optional, comma list. Extra hosts the attachment proxy may fetch from besides `*.aula.dk` (`.example.com` = domain and subdomains). |
| `NTFY_TOPIC` | ntfy topic to publish to. Unset = push off. |
| `NTFY_URL` | ntfy server root only (no topic path; a path is dropped with an error in the log), default `https://ntfy.sh`. |
| `NTFY_TOKEN` | Optional Bearer token for an access-controlled ntfy server. |
| `POLL_SECONDS` | How often push polls Aula, default `300`. |

On start the server loads the stored session and lets the library refresh it. It never starts MitID by itself: when the session is gone, API calls answer `503 auth_required` until the app calls `POST /auth/login` (one attempt, no automatic retry; a failure shows as `state: error`). A keep-alive runs every 10 minutes.

`POST /auth/login` first tries the stored tokens once (a token refresh, no MitID). Only if Aula refuses them does it start MitID, which times out after 5 minutes.

## Push (ntfy)

With `NTFY_TOPIC` set, a background poller checks Aula every `POLL_SECONDS` (only while the session is `ok`) and publishes new direct messages, important posts and holiday requests to ntfy, plus a reminder for each unanswered holiday request the day before its deadline and on the deadline day. While the session is `needs_login` or `error` it instead publishes "Aula login needed", once per loss: retried every poll until ntfy accepts it, and not repeated after a restart (the loss is recorded in `sala.sqlite3` and cleared by a successful login). See the Push section of [`../API.md`](../API.md) for the exact events. Titles only, never message or post bodies.

- Install the ntfy iOS app and subscribe to the topic (same server as `NTFY_URL`).
- On public ntfy.sh anyone who knows the topic can read it: use a long random topic, e.g. `python3 -c "import secrets; print('sala-' + secrets.token_urlsafe(24))"`.
- A self-hosted ntfy needs `upstream-base-url: "https://ntfy.sh"` in its `server.yml` for instant delivery on iOS (Apple push goes through ntfy.sh's relay).
- On the first poll every existing item is recorded silently, so enabling push never floods. An item counts as sent only once ntfy accepts it, so a failed publish is retried on the next poll. The seen-set is in `sala.sqlite3`.

A message counts as direct when the thread's participants, read from the `messaging.getThreads` row the way the portal does (`recipients` without those who left and without my own mailbox, plus `extraRecipientsCount`, plus the creator and the latest sender), minus my own profiles, are exactly one person, and that person sent the newest message. Threads that include the other parent are therefore not direct.

## Debugging against live Aula

- `SALA_DEBUG_SHAPES=1` logs one line per Aula API call: method, status and the JSON reduced to its shape. Strings become `str[n]`, URLs keep only their host, and dates plus a few enum keys (`status`, `type`, `activityType`, ...) stay readable. Names and message text never reach the log. Writes log their payload shape too (`aula →`).
- `SALA_READ_ONLY=1` answers every write route (pickup, sick, save, reply, holiday answers, absences) with 403 `read_only`, so nothing reaches the daycare. Opening a thread still marks it read in Aula.

```
SALA_TOKEN=... AULA_USERNAME=... SALA_DEBUG_SHAPES=1 SALA_READ_ONLY=1 \
  uv run uvicorn sala.app:app --host 0.0.0.0 --port 8000 2>&1 | tee data/sala.log
```

## Fake mode

```sh
cd server && SALA_FAKE=1 SALA_TOKEN=dev uv run uvicorn sala.app:app --host 0.0.0.0 --port 8000
```

`sala/fake.py` fakes Aula at the HTTP layer (the library's `HttpClient`), so the real client and mapping code run on top of it. Data: daycare "Børnehuset", child Oskar in "Stue", a weekly pickup template, 2 open holiday requests (one due tomorrow, one that asks for drop-off and pickup times) that can be answered, 5 threads, 3 posts with a PDF and a PNG. Writes are recorded (`FakeAula.writes`) and reflected in later reads. It starts in `needs_login`; `POST /auth/login` shows OTP `482915` for about 3 seconds, then `ok`.

Fake mode starts in `needs_login`, so with `NTFY_TOPIC` set it publishes "Aula login needed" at startup (and after each restart, since fake keeps no session). To test push end to end, fake mode adds three routes (bearer token still required; 404 without `SALA_FAKE=1`) that make a new item appear for the next poll:

- `POST /debug/fake/new-message`: Mette writes in a thread with only you and her.
- `POST /debug/fake/important-post`: a new important post.
- `POST /debug/fake/holiday-request`: a new holiday request due tomorrow (high priority).

```sh
SALA_FAKE=1 SALA_TOKEN=dev NTFY_TOPIC=sala-test-$RANDOM POLL_SECONDS=5 uv run uvicorn sala.app:app --port 8000
```

## Tests

```sh
cd server && uv run pytest
```
