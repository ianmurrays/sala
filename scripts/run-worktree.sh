#!/usr/bin/env bash
# Run this worktree's server against the main checkout's Aula session, on port 8000.
#
#   scripts/run-worktree.sh         copy the gitignored config in, stop main's server, start this one
#   scripts/run-worktree.sh stop    stop this one, start main's again
#
# Only one server may use an Aula session at a time: two would both refresh its
# tokens, and one refresh can log the other out. So main's server is stopped,
# and this one takes over its data volume (server_sala-data: compose project
# "server", named after main's server/ directory). SALA_DEBUG_SHAPES=1 passes through.
set -euo pipefail

here=$(git rev-parse --show-toplevel)
main=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
[ "$here" != "$main" ] || { echo "Run this from a worktree; the main checkout runs its own stack." >&2; exit 1; }
project="sala-$(basename "$here")"
main_compose=(docker compose -p server -f "$main/server/compose.yaml")

if [ "${1:-}" = stop ]; then
  docker compose -p "$project" -f "$here/server/compose.yaml" down
  "${main_compose[@]}" start
  exit 0
fi

# Gitignored, so a new worktree has neither. Local.xcconfig signs simulator builds too:
# unsigned, the app has no keychain access group and silently fails to save its settings.
for f in server/.env ios/Config/Local.xcconfig; do
  [ -e "$here/$f" ] || cp "$main/$f" "$here/$f"
done

override=$(mktemp)
trap 'rm -f "$override"' EXIT
cat > "$override" <<'EOF'
services:
  sala:
    environment:
      SALA_DEBUG_SHAPES: ${SALA_DEBUG_SHAPES:-0}
volumes:
  sala-data:
    external: true
    name: server_sala-data
EOF

"${main_compose[@]}" stop
docker compose -p "$project" -f "$here/server/compose.yaml" -f "$override" up -d --build
echo "Running $project on http://localhost:8000. Restore main's server with: scripts/run-worktree.sh stop"
