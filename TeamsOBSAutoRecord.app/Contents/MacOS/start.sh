#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PY="$SCRIPT_DIR/venv/bin/python3"
PY_SCRIPT="$SCRIPT_DIR/teams_obs_autorecord.py"

if [ ! -f "$VENV_PY" ]; then
    osascript -e 'display dialog "Virtual environment not found. Please re-download the app." buttons {"OK"} with title "Teams OBS Auto-Record"'
    exit 1
fi

export PATH="/Users/Evgenii_Sopetin/.cargo/bin:/Users/Evgenii_Sopetin/.antigravity/antigravity/bin:/Users/Evgenii_Sopetin/.bun/bin:/Users/Evgenii_Sopetin/.opencode/bin:/Users/Evgenii_Sopetin/.local/bin:/opt/homebrew/bin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/Library/Apple/usr/bin"

exec "$VENV_PY" "$PY_SCRIPT" &