#!/usr/bin/env bash
# deploy.sh: deploy one tagged version of the FTP server.
#
#   ./deploy.sh v1
#
# Then run ./health.sh. A version only counts as deployed once health.sh passes.
set -e
cd "$(dirname "$0")"     # work from the repo, wherever this is called from
source pipeline.conf     # HOST, PORT, FTP_USER, FTP_PASS, DEPLOY

TAG=$1
RELEASE="$DEPLOY/$TAG"   # a clean folder for this version
DATA="$DEPLOY/data"      # uploads, shared by every version, so deploying never deletes them

# Step 3 below deletes $RELEASE. Check here that $RELEASE can only ever be a
# folder inside the deploy folder, so a bad tag or a broken pipeline.conf can
# never turn that into a delete of something else.
case "$DEPLOY" in
  "" | "/") echo "deploy: pipeline.conf must set DEPLOY to a real folder (got '$DEPLOY')"; exit 1 ;;
  /*)       ;;   # absolute path, good
  *)        echo "deploy: DEPLOY in pipeline.conf must be an absolute path (got '$DEPLOY')"; exit 1 ;;
esac
case "$TAG" in
  "" | */* | *..*) echo "deploy: '$TAG' is not a usable tag name"; exit 1 ;;
esac
PYTHON=python
command -v python > /dev/null || PYTHON=python3

# 1. A version is a git tag, not whatever is in your working copy.
if ! git rev-parse --verify --quiet "refs/tags/$TAG" > /dev/null; then
  echo "deploy: no tag named '$TAG' (tags: $(git tag | tr '\n' ' '))"
  exit 1
fi

# 2. Stop the version that is running now. Anyone connected gets dropped.
if [ -f "$DEPLOY/server.pid" ]; then
  echo "deploy: stopping the running server"
  $PYTHON -c "import os, signal, sys; os.kill(int(sys.argv[1]), signal.SIGTERM)" "$(cat "$DEPLOY/server.pid")" 2> /dev/null || true
  rm "$DEPLOY/server.pid"
  sleep 1
fi

# 3. Copy exactly what the tag points at into a clean folder.
echo "deploy: copying $TAG into $RELEASE"
if [ "$RELEASE" = "/" ] || [ "$RELEASE" = "$DEPLOY" ] || [ "$RELEASE" = "$DATA" ]; then
  echo "deploy: refusing to delete $RELEASE"; exit 1
fi
rm -rf "$RELEASE"
mkdir -p "$RELEASE" "$DATA"
git archive "$TAG" | tar -x -C "$RELEASE"

# 4. Make a Python environment for this version and install the server into it
#    from the tagged copy, so the code that runs is the code that was tagged.
echo "deploy: installing the server"
$PYTHON -m venv "$RELEASE/venv"
PY="$RELEASE/venv/bin/python"                          # Mac and Linux
[ -f "$PY" ] || PY="$RELEASE/venv/Scripts/python.exe"  # Windows
"$PY" -m pip install --quiet --disable-pip-version-check "$RELEASE/pyftpdlib"

# 5. Start the server in the background.
# Mediator for clients built before the passive-mode reply changed (see compat.py).
# Only tags whose server knows the flag get it, so older tags (v1...) still deploy.
LEGACY=""
if [ "${LEGACY_PASV:-0}" = "1" ]; then
  if grep -q -- "--legacy-pasv" "$RELEASE/pyftpdlib/pyftpdlib/__main__.py"; then
    LEGACY="--legacy-pasv"
  else
    echo "deploy: $TAG has no --legacy-pasv support, starting without the compatibility mediator"
  fi
fi
"$PY" -m pyftpdlib $LEGACY --interface "$HOST" --port "$PORT" --write --directory "$DATA" \
  --username "$FTP_USER" --password "$FTP_PASS" > "$DEPLOY/server.log" 2>&1 &
PID=$!
[ -f "/proc/$PID/winpid" ] && PID=$(cat "/proc/$PID/winpid")  # Git Bash: save the Windows process id
echo "$PID" > "$DEPLOY/server.pid"
sleep 2                                                       # give it a moment to start listening

# 6. Record what is deployed: which version is live, and when each one went out.
echo "$TAG" > "$DEPLOY/current"
echo "$(date '+%Y-%m-%d %H:%M:%S') $TAG $(git rev-parse --short "$TAG")" >> "$DEPLOY/history.log"
echo "deploy: $TAG started on $HOST:$PORT. Now run ./health.sh (if it fails, see $DEPLOY/server.log)"
