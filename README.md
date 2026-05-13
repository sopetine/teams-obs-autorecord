# Teams OBS Auto-Record

Automatically record Microsoft Teams meetings using OBS Studio.

## Features

- Automatically starts OBS recording when a Teams meeting begins
- Automatically stops recording when the meeting ends
- OBS launches on-demand (no resource drain when not in meetings)
- Records saved to `~/Movies/OBS/`
- Naming format: `(Mon DD, Tue) HH:MM - [Meeting Name].mp4`

## Setup

### 1. Enable OBS WebSocket

1. Open OBS → Tools → WebSocket Server Settings
2. Enable "Enable WebSocket server"
3. Set port: 4455
4. Authentication: disabled (leave unchecked)
5. Click OK

### 2. Set OBS Recording Path

1. Open OBS → Settings → Output → Recording
2. Set Path to: `~/Movies/OBS`

### 3. Install the App

Copy `TeamsOBSAutoRecord.app` to your `/Applications` folder.

## Usage

1. Open `TeamsOBSAutoRecord.app` from `/Applications`
2. The app runs in background - no window will appear
3. When you join a Teams meeting, OBS will automatically launch and start recording
4. When you leave the meeting, recording stops and OBS closes automatically

## Developer Documentation

See `ForAnotherLLM.md` for implementation details, troubleshooting, and how to run without the app bundle.

## Building the App (if needed)

The app bundle structure:
```
TeamsOBSAutoRecord.app/
  Contents/
    Info.plist
    MacOS/
      start.sh          # Launch script
      teams_obs_autorecord.py  # Main Python script
      venv/            # Python virtual environment
    Resources/
      AppIcon.icns     # OBS icon
```

To rebuild:
1. Create venv: `python3 -m venv venv && venv/bin/pip install websocket-client`
2. Copy the script and OBS icon into the structure
3. Create the app bundle with proper Info.plist