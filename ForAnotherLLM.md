# Teams OBS Auto-Record

## What This App Does

- **Monitors Microsoft Teams** for meeting windows
- **Auto-starts OBS recording** when a Teams meeting begins
- **Auto-stops recording** when the meeting ends
- **OBS auto-launches** on-demand and quits when done (saves resources)
- **Renames recordings** with format: `(Mon DD, Tue) HH:MM - [Meeting Name].mp4`

## File Structure

```
TeamsOBSAutoRecord.app/
  Contents/
    Info.plist           # App metadata
    MacOS/
      start.sh           # Launcher script
      teams_obs_autorecord.py  # Main Python script
      venv/              # Python venv with websocket-client
    Resources/
      AppIcon.icns      # OBS app icon
```

## Key Implementation Details

### Meeting Detection
- Uses AppleScript to query Teams windows via System Events
- Window title pattern: `Meeting compact view | {meeting_name} | ...`
- Also detects: `| Microsoft Teams` in title, `Call`, `Meeting` keywords
- Excludes: `Chat |`, `Stand-up |` (channel browsing, not meetings)

### OBS WebSocket Communication
- Raw WebSocket implementation (no obs-websocket library needed)
- OBS WebSocket v5 protocol with Identify message
- Uses `ToggleRecord` request (not `StartRecording` - the latter doesn't work in v5)
- Port: 4455, No auth required

### OBS Lifecycle
- Launch via `open -a OBS`
- Quit gracefully via `osascript -e 'tell application "OBS" to quit'`
- Waits up to 10s for graceful quit before force-killing
- Clears `~/Library/Application Support/obs-studio/safe_mode` to prevent crash dialogs

### Recording Path
- OBS configured to save to `~/Movies/OBS/`
- Script finds newest `.mp4`/`.mkv` file modified within 10 minutes
- Renames using `recording.rename(new_path)`

### Naming Format
```python
date_str = now.strftime("%b %d, %a")  # "May 13, Wed"
time_str = now.strftime("%H") + ":" + now.strftime("%M")  # "21:49"
new_name = f"({date_str}) {time_str} - [{meeting_name}]{suffix}"
# Result: "(May 13, Wed) 21:49 - [Gartner weekly update].mp4"
```

## For Another LLM / Developer

### To Run Without App Bundle
```bash
cd TeamsOBSAutoRecord.app/Contents/MacOS
./start.sh
# Or directly:
./venv/bin/python3 teams_obs_autorecord.py
```

### Dependencies
- Python 3 with venv
- `websocket-client` package (for raw WebSocket, not obs-websocket)
- macOS accessibility permissions for AppleScript (System Events)

### OBS Requirements
1. Enable WebSocket: OBS → Tools → WebSocket Server Settings → Enable (Port 4455, no auth)
2. Set recording path to `~/Movies/OBS` in OBS Settings

### Troubleshooting
- If recordings named wrong: check meeting window title patterns
- If OBS crash dialog: script clears `safe_mode` file on launch/quit
- If WebSocket fails: OBS may need WebSocket enabled (Tools menu)
- To uninstall: remove `~/Documents/MiniMax/apps/TeamsOBSAutoRecord.app`

### Testing Meeting Detection
```python
script = '''
tell application "System Events"
    set teamsProcess to first process whose name is "MSTeams"
    set winList to every window of teamsProcess
    -- get titles...
end tell
'''
```
