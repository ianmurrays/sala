#!/bin/sh
# Copy the app's captured Aula traffic (Settings → Debug → "Capture Aula traffic", debug builds only)
# off a connected phone: scripts/pull-aula-traffic.sh "<device name>"
# Lands in .cache/aula-traffic/ (gitignored): it holds real children's data, never commit it.
set -eu
device=${1:?usage: $0 "<device name, as in xcrun devicectl list devices>"}
cd "$(dirname "$0")/.."
bundle=$(sed -n 's/^SALA_BUNDLE_ID *= *//p' ios/Config/Local.xcconfig).app
mkdir -p .cache/aula-traffic
out=".cache/aula-traffic/$(date +%Y%m%d-%H%M%S).jsonl"
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
  --source Library/Caches/aula-traffic.jsonl --destination "$out" >/dev/null 2>&1 ||
  { echo "Nothing captured: turn on Settings → Debug → Capture Aula traffic in a debug build, use the app, try again" >&2; exit 1; }
echo "$out ($(wc -l < "$out" | tr -d ' ') calls)"
