"""Measure process launch to a visible native window using isolated app data."""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("executable")
parser.add_argument("data")
parser.add_argument("output")
parser.add_argument("--count", type=int, default=3)
args = parser.parse_args()
data = Path(args.data).resolve()
data.mkdir(parents=True, exist_ok=True)
user = ctypes.windll.user32
callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
user.EnumChildWindows.argtypes = [wintypes.HWND, callback_type, wintypes.LPARAM]
user.IsWindowVisible.argtypes = [wintypes.HWND]
user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
samples = []
first_frames = []
for run in range(args.count):
    env = {**os.environ, "LANFLOW_DATA_DIR": str(data), "LANFLOW_ISOLATED_STORAGE": "1"}
    env.pop("LANFLOW_START_HIDDEN", None)
    start = time.perf_counter()
    process = subprocess.Popen(
        [str(Path(args.executable).resolve())], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    found = []

    @callback_type
    def visit(window, _):
        pid = wintypes.DWORD()
        user.GetWindowThreadProcessId(window, ctypes.byref(pid))
        if pid.value == process.pid and user.IsWindowVisible(window):
            found.append(window)
        return True

    try:
        while time.perf_counter() - start < 20 and process.poll() is None:
            user.EnumWindows(visit, 0)
            if found:
                samples.append(round((time.perf_counter() - start) * 1000, 1))
                break
            time.sleep(.002)
        if not found:
            raise RuntimeError("No visible window from this process (another instance may be running)")
        rendered = []

        @callback_type
        def visit_child(window, _):
            name = ctypes.create_unicode_buffer(128)
            user.GetClassNameW(window, name, len(name))
            if "FLUTTER" in name.value.upper() and user.IsWindowVisible(window):
                rendered.append(window)
            return True

        # The runner attaches Flutter's child only after its first rendered frame.
        while time.perf_counter() - start < 20 and process.poll() is None:
            user.EnumChildWindows(found[0], visit_child, 0)
            if rendered:
                first_frames.append(round((time.perf_counter() - start) * 1000, 1))
                break
            time.sleep(.002)
        if not rendered:
            raise RuntimeError("The first Flutter frame never became visible")
        time.sleep(.5)
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=10)
    time.sleep(.3)
result = {
    "processToVisibleWindowMs": samples,
    "medianMs": sorted(samples)[len(samples)//2],
    "processToFirstChatFrameMs": first_frames,
    "firstChatFrameMedianMs": sorted(first_frames)[len(first_frames)//2],
}
Path(args.output).write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result))
