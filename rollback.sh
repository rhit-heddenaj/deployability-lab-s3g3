#!/usr/bin/env bash
# rollback.sh: put a previously deployed version back, fast.
#
#   ./rollback.sh          # back to the version deployed before the current one
#   ./rollback.sh v1       # back to a specific version still in the deploy folder
#
# Needs no git, no pip, no network: every release already has its own folder and
# venv under $DEPLOY, and uploads live in $DEPLOY/data, which this script never
# touches. It checks that the target can start BEFORE stopping the running
# server, and runs ./health.sh at the end. Anyone connected is dropped.
set -e
cd "$(dirname "$0")"
source pipeline.conf     # HOST, PORT, FTP_USER, FTP_PASS, DEPLOY

case "$DEPLOY" in
  "" | "/") echo "rollback: pipeline.conf must set DEPLOY to a real folder (got '$DEPLOY')"; exit 1 ;;
  /*)       ;;
  *)        echo "rollback: DEPLOY must be an absolute path (got '$DEPLOY')"; exit 1 ;;
esac
PYTHON=python
command -v python > /dev/null || PYTHON=python3

DATA="$DEPLOY/data"
CURRENT=$(cat "$DEPLOY/current" 2> /dev/null || true)
TARGET=$1

# 1. Pick the target: the most recent history entry that is not the current version.
if [ -z "$TARGET" ]; then
  [ -f "$DEPLOY/history.log" ] || { echo "rollback: no history.log, name a version: ./rollback.sh <tag>"; exit 1; }
  TARGET=$(awk -v cur="$CURRENT" '$3 != cur { t = $3 } END { print t }' "$DEPLOY/history.log")
  [ -n "$TARGET" ] || { echo "rollback: nothing earlier than '$CURRENT' to go back to"; exit 1; }
fi
case "$TARGET" in
  "" | */* | *..*) echo "rollback: '$TARGET' is not a usable version name"; exit 1 ;;
esac
RELEASE="$DEPLOY/$TARGET"

# 2. Check the target is runnable BEFORE touching the live server.
PY="$RELEASE/venv/bin/python"
[ -f "$PY" ] || PY="$RELEASE/venv/Scripts/python.exe"
if [ ! -f "$PY" ]; then
  echo "rollback: $TARGET is not installed in $DEPLOY (found: $(ls "$DEPLOY" | tr '\n' ' '))"
  echo "rollback: the running server was NOT touched"
  exit 1
fi
if [ "$TARGET" = "$CURRENT" ] && [ -f "$DEPLOY/server.pid" ]; then
  echo "rollback: $TARGET is already the current version; use ./deploy.sh $TARGET to redeploy it"
  exit 1
fi

# 3. Stop the running server (same method as deploy.sh).
if [ -f "$DEPLOY/server.pid" ]; then
  echo "rollback: stopping $CURRENT"
  $PYTHON -c "import os, signal, sys; os.kill(int(sys.argv[1]), signal.SIGTERM)" "$(cat "$DEPLOY/server.pid")" 2> /dev/null || true
  rm -f "$DEPLOY/server.pid"
  sleep 1
fi

# 3b. Salvage: a bad version may have stored uploads inside its OWN folder
#     instead of the shared data/ folder. Copy them into data/ and verify each
#     copy by checksum. Sources are never deleted. A same-named file with
#     different content is kept under a <version>- prefix, never overwritten.
SALVAGE_FAILED=0
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$TARGET" ]; then
  mkdir -p "$DATA"
  for SRC in "$DEPLOY/$CURRENT/venv/uploads" "$DEPLOY/$CURRENT/uploads"; do
    [ -d "$SRC" ] || continue
    for f in "$SRC"/*; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      dest="$DATA/$name"
      if [ -e "$dest" ]; then
        # already in data/ and identical: nothing to do
        [ "$(sha256sum < "$f")" = "$(sha256sum < "$dest")" ] && continue
        dest="$DATA/$CURRENT-$name"
      fi
      cp -p "$f" "$dest"
      if [ "$(sha256sum < "$f")" = "$(sha256sum < "$dest")" ]; then
        echo "rollback: salvaged $name from $CURRENT"
      else
        echo "rollback: WARNING: copy of $name does not match; original left in $SRC"
        SALVAGE_FAILED=1
      fi
    done
  done
fi

# 4. Start the old release against the SAME data folder.
mkdir -p "$DATA"
echo "rollback: starting $TARGET"
"$PY" -m pyftpdlib --interface "$HOST" --port "$PORT" --write --directory "$DATA" \
  --username "$FTP_USER" --password "$FTP_PASS" > "$DEPLOY/server.log" 2>&1 &
PID=$!
[ -f "/proc/$PID/winpid" ] && PID=$(cat "/proc/$PID/winpid")
echo "$PID" > "$DEPLOY/server.pid"
sleep 2

# 5. Record it, then prove it works. A rollback only counts once health.sh passes.
echo "$TARGET" > "$DEPLOY/current"
echo "$(date '+%Y-%m-%d %H:%M:%S') $TARGET $(git rev-parse --short "$TARGET" 2> /dev/null || echo '?') rollback-from-$CURRENT" >> "$DEPLOY/history.log"
if ./health.sh; then
  if [ "$SALVAGE_FAILED" = "1" ]; then
    echo "rollback: $TARGET is live, but some uploads could NOT be verified. Check the WARNING lines above."
    exit 1
  fi
  echo "rollback: $TARGET is live again. Everything $CURRENT stored was copied into $DATA and checksum-verified."
else
  echo "rollback: $TARGET started but FAILED the health check, see $DEPLOY/server.log"
  exit 1
fi