#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PY="$SCRIPT_DIR/venv/bin/python3"
PY_SCRIPT="$SCRIPT_DIR/teams_obs_autorecord.py"

if [ ! -f "$VENV_PY" ]; then
    osascript -e 'display dialog "Virtual environment not found. Please re-download the app." buttons {"OK"} with title "Teams OBS Auto-Record"'
    exit 1
fi

exec "$VENV_PY" "$PY_SCRIPT" &