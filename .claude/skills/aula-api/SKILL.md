---
name: aula-api
description: Find and check Aula API calls for Sala. Use when adding or fixing anything that reads or writes Aula (a new screen, a route in ios/Sala/Aula/, a field Sala gets wrong), when you need to know which Aula `?method=` a portal feature uses or what its params are, or what live Aula actually answers.
---

Sala calls Aula from the iOS app (`ios/Sala/Aula/`). Nothing documents Aula's API; there are two sources of truth, and neither needs a MitID login from you.

## Which call, which params: the portal bundle

The web portal is public JavaScript. Every call is a `"?method=<area>.<name>"` string next to the code that builds its params and reads its answer.

```sh
scripts/aula-bundle.py fetch                  # into .cache/aula-bundle/; again when Aula deploys
scripts/aula-bundle.py methods contact        # method names matching "contact", and their chunks
scripts/aula-bundle.py show profiles.getContactlist 1200   # the code around each use
```

Read the params object, the `.then` that reads `e.data.data...`, and for writes the body. Cite what you used in a code comment, the way `AulaMapping.swift` does ("from the portal bundle (0.*.js LOAD_VACATION_REQUEST_RESPONSE: ...)"); chunk hashes change, the action names don't.

## What live Aula answers: traffic from the phone

The bundle shows what the portal reads, not every field Aula sends, and field names in the bundle can be guesses. For real shapes, ask the user to:

1. Install a debug build: `ios/scripts/install-device.sh "<device>"`.
2. Turn on Settings → Debug → **Capture Aula traffic**, then do the thing in the app (open the screen, the thread, ...).
3. Then you run `scripts/pull-aula-traffic.sh "<device>"`. It prints the file in `.cache/aula-traffic/`: one JSON line per call with `method`, `params`, `body`, `status`, `response`.

For a call the app doesn't make yet, the capture can't show it: add the read first (behind DEBUG if it isn't wired to a screen yet), then capture.

Live app logs (warnings for skipped parts, refusals): Console.app on the Mac, the phone selected, filter `subsystem:sala`.

## Rules

- **Never start MitID or log in yourself**, and never ask the user to retry a failed MitID login in a loop: repeated failures can lock their identity.
- **Captured traffic is real children's and families' data.** Keep it in `.cache/` (gitignored). Never paste it into commits, PRs, issues or docs as is.
- To keep a shape, write it to `docs/aula-shapes/<method>.json` with the same structure and every value replaced by its type (`"str"`, `"int|null"`, ...), so no real value is kept. Look at an existing file there first.
- **Writes to live Aula change a real child's record** (pickup, sick, holidays, messages). Never trigger one to test without the user saying so for that write; prefer reversible ones (save then unsave a post).

## Then change the code

- Mapping and routes: `ios/Sala/Aula/AulaMapping.swift`, `AulaRoutes.swift`, `AulaClient.swift` (raw calls). The contract the views see: `API.md`; change it first.
- Demo fixtures: add or update `ios/DemoAula/<method>.json` (invented data, the shape of the live answer) so demo mode and `DemoTests` cover the change. See `CLAUDE.md`.
- Tests: `ios/SalaTests/GoldenTests.swift` replays `ios/SalaTests/Goldens/*.json` (recorded Aula answers plus the expected route output). They're frozen: a deliberate change means editing the golden's Aula answer and expected output by hand. Run `cd ios && xcodebuild test -project Sala.xcodeproj -scheme Sala -destination 'platform=iOS Simulator,name=<an iPhone simulator>'`.
