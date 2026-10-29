#!/usr/bin/env bash
# health.sh: check that the deployed server actually works.
#
#   ./health.sh
#
# Logs in, uploads a small file, downloads it back, and checks it matches.
# Prints OK and exits 0 if healthy. Prints FAIL and exits 1 if not.
cd "$(dirname "$0")"
source pipeline.conf

URL="ftp://$FTP_USER:$FTP_PASS@$HOST:$PORT"
SENT="health check $(date)"

if ! echo "$SENT" | curl --silent --show-error -T - "$URL/health.txt"; then
  echo "health: FAIL, could not log in and upload"
  exit 1
fi

if ! GOT=$(curl --silent --show-error "$URL/health.txt"); then
  echo "health: FAIL, could not download the file back"
  exit 1
fi

if [ "$GOT" != "$SENT" ]; then
  echo "health: FAIL, the file that came back is different"
  exit 1
fi

# Legacy leg: clients built before the passive-mode reply changed (the M0 JFTP) send
# PASV and parse a 227 reply. curl normally tries EPSV first, which hides a broken PASV,
# so force PASV here. A release that strands those clients is not healthy.
LEGACY_SENT="legacy health check $(date)"
if ! echo "$LEGACY_SENT" | curl --silent --show-error --disable-epsv --max-time 15 -T - "$URL/health-legacy.txt"; then
  echo "health: FAIL, a legacy (PASV) client could not upload; clients built before this release are locked out"
  exit 1
fi
if ! LEGACY_GOT=$(curl --silent --show-error --disable-epsv --max-time 15 "$URL/health-legacy.txt") || [ "$LEGACY_GOT" != "$LEGACY_SENT" ]; then
  echo "health: FAIL, a legacy (PASV) client could not download the file back correctly"
  exit 1
fi
curl --silent --quote "DELE health-legacy.txt" "$URL/" > /dev/null

curl --silent --quote "DELE health.txt" "$URL/" > /dev/null   # clean up the test file
echo "health: OK, $(cat "$DEPLOY/current") is serving on $HOST:$PORT"
echo "health: legacy PASV client OK"
