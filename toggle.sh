#!/usr/bin/env bash
# toggle.sh: toggle IP rate limit.
#
#   ./toggle.sh
#
# Logs in, toggles IP rate limit
cd "$(dirname "$0")"
source pipeline.conf

echo "tog" | nc -C -q 1 localhost 2121
