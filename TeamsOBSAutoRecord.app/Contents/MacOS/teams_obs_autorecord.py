#!/usr/bin/env python3
"""
OBS Auto-Record for Microsoft Teams Meetings
Meeting detection is done by StatusApp (Swift) which has Accessibility permission.
This script reads the meeting status file and controls OBS recording.
"""

import subprocess
import time
import json
import os
import fcntl
import struct
import base64
import socket
from datetime import datetime
from pathlib import Path

OBS_WEBSOCKET_HOST = "localhost"
OBS_WEBSOCKET_PORT = 4455

RECORDINGS_DIR = Path.home() / "Movies" / "OBS"
MEETING_STATUS_FILE = Path.home() / ".teams-obs-meeting.json"   # written by StatusApp (Swift)
OBS_STATUS_FILE = Path.home() / ".teams-obs-status.json"        # written here, read by StatusApp for UI
LOG_FILE = Path.home() / ".teams-obs-log.txt"
LOCK_FILE = Path.home() / ".teams-obs-autorecord.lock"

POLL_INTERVAL = 2

# ── Single-instance lock ───────────────────────────────────────────────────────

def acquire_lock():
    """Exit immediately if another instance is already running."""
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Another instance already running. Exiting.")
        raise SystemExit(0)
    lock_fd.write(str(os.getpid()))
    lock_fd.flush()
    return lock_fd  # keep fd open to hold the lock


def log(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except:
        pass


def write_obs_status(recording=False, in_meeting=False, meeting=""):
    try:
        with open(OBS_STATUS_FILE, "w") as f:
            json.dump({
                "recording": recording,
                "in_meeting": in_meeting,
                "meeting": meeting or "None",
                "timestamp": datetime.now().isoformat()
            }, f)
    except Exception as e:
        log(f"Failed to write OBS status: {e}")


def read_meeting_status():
    """Read meeting status written by StatusApp (Swift)."""
    try:
        with open(MEETING_STATUS_FILE) as f:
            data = json.load(f)
        return data.get("in_meeting", False), data.get("meeting_name", "")
    except:
        return False, ""


# ── OBS WebSocket ──────────────────────────────────────────────────────────────

class OBSWebSocket:
    def __init__(self):
        self.ws = None
        self.request_id = 0

    def _ws_handshake(self):
        key = base64.b64encode(b'randomkey12345678901234').decode()
        handshake = (
            f"GET / HTTP/1.1\r\nHost: localhost:4455\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\nOrigin: http://localhost\r\n\r\n"
        )
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(("localhost", 4455))
        s.send(handshake.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += s.recv(4096)
        s.settimeout(30)
        self.ws = s

    def _ws_send(self, data):
        if isinstance(data, dict):
            data = json.dumps(data).encode()
        elif isinstance(data, str):
            data = data.encode()
        n = len(data)
        mask = os.urandom(4)
        masked = bytes([b ^ m for b, m in zip(data, (mask * (n // 4 + 1))[:n])])
        header = struct.pack('B', 0x81)
        if n < 126:
            header += struct.pack('B', 0x80 | n)
        elif n < 65536:
            header += struct.pack('!BH', 0xfe, n)
        else:
            header += struct.pack('!BQ', 0xff, n)
        self.ws.send(header + mask + masked)

    def _ws_recv(self):
        first = self.ws.recv(2)
        if not first:
            return None
        op = first[0] & 0x0f
        n = first[1] & 0x7f
        if n == 126:
            n = struct.unpack('!H', self.ws.recv(2))[0]
        elif n == 127:
            n = struct.unpack('!Q', self.ws.recv(8))[0]
        if op == 0x08:
            return None
        data = b""
        while len(data) < n:
            chunk = self.ws.recv(n - len(data))
            if not chunk:
                break
            data += chunk
        return data.decode('utf-8', errors='replace')

    def connect(self):
        try:
            self._ws_handshake()
            init = self._ws_recv()
            if init:
                j = json.loads(init)
                if j.get("op") == 0:
                    self._ws_send({"op": 1, "d": {"rpcVersion": 1}})
                    for _ in range(5):
                        resp = self._ws_recv()
                        if not resp:
                            break
                        try:
                            rj = json.loads(resp)
                            if rj.get("op") in (2, 7):
                                log("OBS connected")
                                return True
                        except:
                            pass
                        time.sleep(0.2)
        except Exception as e:
            log(f"OBS connect failed: {e}")
        return False

    def send_request(self, req_type):
        if not self.ws:
            return None
        self.request_id += 1
        self._ws_send(json.dumps({"op": 6, "d": {"requestType": req_type, "requestId": str(self.request_id)}}))
        try:
            while True:
                resp = self._ws_recv()
                if not resp:
                    return None
                rj = json.loads(resp)
                if rj.get("op") == 7 and rj.get("d", {}).get("requestId") == str(self.request_id):
                    return rj.get("d", {}).get("responseData")
        except Exception as e:
            log(f"Request error: {e}")
        return None

    def toggle_record(self):
        result = self.send_request("ToggleRecord")
        if result and isinstance(result, dict):
            return result.get("outputActive", False)
        return False

    def close(self):
        if self.ws:
            try:
                self.ws.close()
            except:
                pass
            self.ws = None


# ── Main loop ──────────────────────────────────────────────────────────────────

def get_newest_recording():
    if not RECORDINGS_DIR.exists():
        return None
    files = list(RECORDINGS_DIR.glob("*.mp4")) + list(RECORDINGS_DIR.glob("*.mkv"))
    if not files:
        return None
    newest = max(files, key=os.path.getmtime)
    if time.time() - os.path.getmtime(newest) < 600:
        return newest
    return None


def rename_recording(meeting_name):
    rec = get_newest_recording()
    if not rec:
        log("No recent recording to rename")
        return
    now = datetime.now()
    date_str = now.strftime("%b %d, %a")
    time_str = now.strftime("%H:%M")
    name = meeting_name or "Teams Meeting"
    new_name = f"({date_str}) {time_str} - [{name}]{rec.suffix}"
    try:
        rec.rename(rec.parent / new_name)
        log(f"Renamed to: {new_name}")
    except Exception as e:
        log(f"Rename failed: {e}")


def launch_obs():
    log("Launching OBS...")
    safe_mode = Path.home() / "Library/Application Support/obs-studio/safe_mode"
    if safe_mode.exists():
        safe_mode.unlink()
    subprocess.run(["/usr/bin/osascript", "-e", 'tell application "OBS" to quit'], capture_output=True)
    time.sleep(2)
    subprocess.Popen(["/usr/bin/open", "-a", "OBS"])
    time.sleep(8)


def quit_obs():
    subprocess.run(["/usr/bin/osascript", "-e", 'tell application "OBS" to quit'], capture_output=True)
    for i in range(10):
        time.sleep(1)
        if subprocess.run(["/usr/bin/pgrep", "-x", "OBS"], capture_output=True).returncode != 0:
            log(f"OBS quit after {i+1}s")
            break
    safe_mode = Path.home() / "Library/Application Support/obs-studio/safe_mode"
    if safe_mode.exists():
        safe_mode.unlink()


def main():
    lock_fd = acquire_lock()  # exit immediately if already running
    log("=" * 50)
    log("OBS Auto-Record (OBS controller)")
    log("=" * 50)
    RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
    write_obs_status(recording=False, in_meeting=False)
    log("Waiting for meeting status from StatusApp...")

    obs = None
    obs_launched = False
    is_recording = False
    current_meeting = None

    try:
        while True:
            in_meeting, meeting_name = read_meeting_status()

            if in_meeting and not is_recording:
                log(f"Meeting detected: {meeting_name}")
                write_obs_status(in_meeting=True, meeting=meeting_name)
                current_meeting = meeting_name

                launch_obs()
                obs = OBSWebSocket()
                if obs.connect():
                    obs_launched = True
                    result = obs.toggle_record()
                    if result:
                        log("Recording started!")
                        is_recording = True
                        write_obs_status(recording=True, in_meeting=True, meeting=current_meeting)
                    else:
                        log("Failed to start recording")
                        quit_obs()
                        obs = None
                        obs_launched = False
                else:
                    log("Could not connect to OBS")
                    obs = None
                    obs_launched = False

            elif not in_meeting and is_recording:
                log("Meeting ended, stopping recording...")
                write_obs_status(in_meeting=False, meeting=current_meeting or "")
                if obs and obs.ws:
                    obs.toggle_record()
                    obs.close()
                time.sleep(2)
                rename_recording(current_meeting)
                if obs_launched:
                    quit_obs()
                obs = None
                obs_launched = False
                is_recording = False
                current_meeting = None
                write_obs_status(recording=False, in_meeting=False)

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        log("Shutting down...")
        if is_recording and obs and obs.ws:
            obs.toggle_record()
            time.sleep(2)
            rename_recording(current_meeting)
        if obs_launched:
            quit_obs()


if __name__ == "__main__":
    main()
