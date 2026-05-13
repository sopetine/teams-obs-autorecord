#!/usr/bin/env python3
"""
OBS Auto-Record for Microsoft Teams Meetings
Detects Teams meeting start/end and controls OBS recording automatically.
Saves recordings as: Date/Time_Meeting-Name.mp4
"""

import subprocess
import time
import re
import json
import sys
import os
import struct
import base64
import socket
from datetime import datetime
from pathlib import Path

OBS_WEBSOCKET_HOST = "localhost"
OBS_WEBSOCKET_PORT = 4455
OBS_WEBSOCKET_PASSWORD = None

TEAMS_APP_NAME = "Microsoft Teams"
RECORDINGS_DIR = Path.home() / "Movies" / "OBS"

POLL_INTERVAL = 2
MEETING_TITLE_KEYWORDS = ["Meeting", "Call", "Calling", "Waiting", "Join"]
CHAT_WINDOW_PREFIX = "Chat |"
MEETING_WINDOW_PREFIX = "Meeting compact view"


class OBSWebSocket:
    def __init__(self, host=OBS_WEBSOCKET_HOST, port=OBS_WEBSOCKET_PORT, password=OBS_WEBSOCKET_PASSWORD):
        self.host = host
        self.port = port
        self.password = password
        self.ws = None
        self.request_id = 0

    def _generate_ws_key(self):
        return base64.b64encode(b'randomkey12345678901234').decode()

    def _ws_handshake(self):
        key = self._generate_ws_key()
        handshake = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"Origin: http://localhost\r\n"
            f"\r\n"
        )
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        sock.connect((self.host, self.port))
        sock.send(handshake.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += sock.recv(4096)
        sock.settimeout(30)
        self.ws = sock
        return resp

    def _ws_send(self, data):
        if isinstance(data, str):
            data = data.encode()
        elif isinstance(data, dict):
            data = json.dumps(data).encode()

        length = len(data)
        mask = os.urandom(4)
        masked = bytes([b ^ m for b, m in zip(data, (mask * (length // 4 + 1))[:length])])

        header = struct.pack('B', 0x81)
        if length < 126:
            header += struct.pack('B', 0x80 | length)
        elif length < 65536:
            header += struct.pack('!BH', 0xfe, length)
        else:
            header += struct.pack('!BQ', 0xff, length)
        header += mask

        self.ws.send(header + masked)

    def _ws_recv(self):
        first = self.ws.recv(2)
        if not first:
            return None
        opcode = first[0] & 0x0f
        length = first[1] & 0x7f

        if length == 126:
            length = struct.unpack('!H', self.ws.recv(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.ws.recv(8))[0]

        if opcode == 0x08:
            return None

        data = b""
        while len(data) < length:
            chunk = self.ws.recv(length - len(data))
            if not chunk:
                break
            data += chunk

        return data.decode('utf-8', errors='replace')

    def connect(self):
        try:
            resp = self._ws_handshake()
            if b"101" not in resp:
                print("WebSocket handshake failed")
                return False

            init_data = self._ws_recv()
            if init_data:
                init_json = json.loads(init_data)
                if init_json.get("op") == 0:
                    print("OBS WebSocket connected successfully, sending Identify...")
                    self._ws_send({"op": 1, "d": {"rpcVersion": 1}})
                    import time as time_module
                    for i in range(5):
                        ident_data = self._ws_recv()
                        if not ident_data:
                            break
                        try:
                            ident_json = json.loads(ident_data)
                            op = ident_json.get("op")
                            if op == 2:
                                print("OBS authenticated successfully")
                                return True
                            elif op == 7:
                                print("OBS identified")
                                return True
                        except:
                            pass
                        time_module.sleep(0.2)
        except Exception as e:
            print(f"Failed to connect to OBS WebSocket: {e}")
            import traceback
            traceback.print_exc()
            return False
        return False

    def send_request(self, request_type, request_data=None):
        if not self.ws:
            return None
        self.request_id += 1
        request = {"op": 6, "d": {"requestType": request_type, "requestId": str(self.request_id)}}
        if request_data:
            request["d"]["requestData"] = request_data

        self._ws_send(json.dumps(request))
        try:
            while True:
                response = self._ws_recv()
                if not response:
                    return None
                resp_json = json.loads(response)
                if resp_json.get("op") == 7 and resp_json.get("d", {}).get("requestId") == str(self.request_id):
                    return resp_json.get("d", {}).get("responseData")
        except Exception as e:
            print(f"Request error: {e}")
            return None

    def get_output_active(self):
        scenes = self.send_request("GetSceneList")
        return False

    def get_recording_status(self):
        scenes = self.send_request("GetSceneList")
        return {"outputActive": False}

    def start_recording(self):
        result = self.send_request("ToggleRecord")
        if result and isinstance(result, dict):
            return result.get("outputActive", False)
        return False

    def stop_recording(self):
        result = self.send_request("ToggleRecord")
        if result and isinstance(result, dict):
            return result.get("outputActive", False) == False
        return False

    def get_current_scene(self):
        result = self.send_request("GetCurrentProgramScene")
        if result:
            return result.get("currentProgramSceneName")
        return None

    def close(self):
        if self.ws:
            try:
                self.ws.close()
            except:
                pass
            self.ws = None


class TeamsMeetingDetector:
    def is_in_meeting(self):
        windows = self.get_teams_windows()
        meeting_name = None
        for window in windows:
            title = window.get("title", "")
            if title.startswith(MEETING_WINDOW_PREFIX):
                meeting_name = title
                break
        if not meeting_name:
            for window in windows:
                title = window.get("title", "")
                if title.startswith(CHAT_WINDOW_PREFIX):
                    continue
                if title.startswith("Stand-up |"):
                    continue
                if "| Microsoft Teams" in title:
                    meeting_name = title
                    break
                if "Meeting" in title or "Call" in title or "meeting" in title.lower():
                    meeting_name = title
                    break
        if meeting_name:
            return True, self.extract_meeting_name(meeting_name)
        return False, None

    def extract_meeting_name(self, title):
        name = title.strip()
        name = re.sub(r'^Meeting compact view \| ', '', name)
        parts = name.split('|')
        name = parts[0].strip()
        name = re.sub(r'[<>:"/\\|?*]', '-', name)
        name = re.sub(r'_+', ' ', name)
        return name if name else None

    def get_teams_windows(self):
        try:
            script = '''
            tell application "System Events"
                try
                    set teamsProcess to first process whose name is "MSTeams"
                    set winList to every window of teamsProcess
                    set winNames to {}
                    repeat with w in winList
                        set wName to title of w
                        if wName is not "" then
                            set end of winNames to wName
                        end if
                    end repeat
                    return winNames
                end try
            end tell
            '''
            result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and result.stdout.strip():
                titles = result.stdout.strip()
                windows = []
                for title in titles.split(', '):
                    title = title.strip()
                    if title:
                        windows.append({'title': title})
                return windows
        except Exception as e:
            print(f"Error getting Teams windows: {e}")
        return []


def get_newest_recording():
    if not RECORDINGS_DIR.exists():
        return None
    files = list(RECORDINGS_DIR.glob("*.mp4")) + list(RECORDINGS_DIR.glob("*.mkv"))
    if files:
        newest = max(files, key=os.path.getmtime)
        age = time.time() - os.path.getmtime(newest)
        if age < 300:
            return newest
    return None


def rename_latest_recording(meeting_name=None):
    recording = get_newest_recording()
    if not recording:
        print("  No new recording found to rename")
        return None

    now = datetime.now()
    date_str = now.strftime("%b %d, %a")
    time_str = now.strftime("%H") + ":" + now.strftime("%M")

    if meeting_name:
        new_name = f"({date_str}) {time_str} - [{meeting_name}]{recording.suffix}"
    else:
        new_name = f"({date_str}) {time_str} - [Teams Meeting]{recording.suffix}"

    new_path = recording.parent / new_name
    try:
        recording.rename(new_path)
        print(f"  Renamed recording to: {new_name}")
        return new_path
    except Exception as e:
        print(f"  Failed to rename recording: {e}")
        return None


def obs_start_recording_keyboard():
    subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to set frontmost of process "OBS" to true',
        "-e", 'tell application "System Events" to key code 13 using {command down, shift down}'
    ], capture_output=True)


def obs_stop_recording_keyboard():
    subprocess.run([
        "osascript", "-e",
        'tell application "System Events" to set frontmost of process "OBS" to true',
        "-e", 'tell application "System Events" to key code 13 using {command down, shift down}'
    ], capture_output=True)


def main():
    print("=" * 60)
    print("OBS Auto-Record for Microsoft Teams Meetings")
    print("=" * 60)

    RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Recordings will be saved to: {RECORDINGS_DIR}")

    obs = OBSWebSocket()
    obs_launched_by_us = False

    print("\nWill launch OBS when meeting starts...")

    print("\nMonitoring Teams meetings...\n")

    detector = TeamsMeetingDetector()
    is_recording = False
    current_meeting_name = None
    obs_launched_by_us = False
    connected = False

    def ensure_obs_running():
        nonlocal obs, obs_launched_by_us, connected
        if obs and obs.ws:
            return True
        print("  Launching OBS...")
        subprocess.run(["osascript", "-e", 'tell application "OBS" to quit'], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-f", "OBS"], capture_output=True)
        time.sleep(1)
        safe_mode_file = Path.home() / "Library/Application Support/obs-studio/safe_mode"
        if safe_mode_file.exists():
            safe_mode_file.unlink()
        subprocess.Popen(["open", "-a", "OBS"])
        time.sleep(8)
        obs = OBSWebSocket()
        if obs.connect():
            connected = True
            obs_launched_by_us = True
            print("  OBS connected!")
            return True
        print("  Failed to connect to OBS")
        obs = None
        return False
        connected = False
        for attempt in range(10):
            obs_ws = OBSWebSocket()
            if obs_ws.connect():
                obs = obs_ws
                connected = True
                obs_launched_by_us = True
                print("  OBS connected!")
                return True
            time.sleep(2)
        print("  Failed to connect to OBS")
        return False

    def cleanup_obs():
        nonlocal obs, obs_launched_by_us
        if obs_launched_by_us:
            print("  Closing OBS...")
            if obs and obs.ws:
                obs.close()
            result = subprocess.run(["osascript", "-e", 'tell application "OBS" to quit'], capture_output=True)
            print("  Waiting for OBS to quit...")
            for i in range(10):
                time.sleep(1)
                check = subprocess.run(["pgrep", "-x", "OBS"], capture_output=True)
                if check.returncode != 0:
                    print(f"  OBS quit after {i+1} seconds")
                    break
            safe_mode_file = Path.home() / "Library/Application Support/obs-studio/safe_mode"
            if safe_mode_file.exists():
                safe_mode_file.unlink()
            obs = None
            obs_launched_by_us = False

    try:
        while True:
            in_meeting, meeting_name = detector.is_in_meeting()

            if in_meeting and not is_recording:
                print(f"[MEETING DETECTED] Starting recording...")
                if meeting_name:
                    print(f"  Meeting: {meeting_name}")
                current_meeting_name = meeting_name

                if ensure_obs_running():
                    print("  Starting recording...")
                    result = obs.start_recording()
                    if result:
                        print("  Recording started!")
                        is_recording = True
                    else:
                        print("  Failed to start recording")
                        cleanup_obs()
                else:
                    print("  Cannot start recording - OBS unavailable")

            elif not in_meeting and is_recording:
                print(f"[MEETING ENDED] Stopping recording...")
                current_meeting_name = current_meeting_name or meeting_name

                if obs and obs.ws:
                    result = obs.stop_recording()
                    if result:
                        print("  Recording stopped!")
                    else:
                        print("  Stop returned False")
                else:
                    print("  OBS not connected")

                time.sleep(2)
                rename_latest_recording(current_meeting_name)
                cleanup_obs()

                is_recording = False
                current_meeting_name = None

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        print("\n\nShutting down...")
        if is_recording:
            if obs and obs.ws:
                obs.stop_recording()
            time.sleep(2)
            rename_latest_recording(current_meeting_name)
        cleanup_obs()
        print("Done.")


if __name__ == "__main__":
    main()