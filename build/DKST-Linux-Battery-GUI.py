#!/usr/bin/env python3
#pqr term=false; close=true; cat=Util
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from tkinter import BOTH, LEFT, RIGHT, StringVar, Tk, messagebox, ttk

APP_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dkst-linux-battery"
CONFIG_PATH = APP_DIR / "config.json"
PID_PATH = APP_DIR / "agent.pid"
LOG_PATH = APP_DIR / "agent.log"

DEFAULT_CONFIG = {
    "server": "http://macos.local:8787/battery",
    "api_key": "",
    "interval_seconds": "30",
}


def load_config():
    if not CONFIG_PATH.exists():
        return DEFAULT_CONFIG.copy()

    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return DEFAULT_CONFIG.copy()

    config = DEFAULT_CONFIG.copy()
    config.update({key: str(value) for key, value in data.items()})
    return config


def save_config(config):
    APP_DIR.mkdir(parents=True, exist_ok=True)
    with CONFIG_PATH.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def read_pid():
    try:
        return int(PID_PATH.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def is_process_running(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def running_pid():
    pid = read_pid()
    if is_process_running(pid):
        return pid
    try:
        PID_PATH.unlink()
    except OSError:
        pass
    return None


def stop_agent():
    pid = running_pid()
    if not pid:
        return

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    deadline = time.time() + 5
    while time.time() < deadline:
        if not is_process_running(pid):
            break
        time.sleep(0.1)

    if is_process_running(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        PID_PATH.unlink()
    except OSError:
        pass


def find_agent_binary():
    path_agent = shutil.which("DKST Linux Battery Agent")
    candidates = [
        Path(__file__).resolve().parent / "DKST Linux Battery Agent",
        Path(__file__).resolve().parents[1] / "linux-agent" / "DKST Linux Battery Agent",
        Path("/usr/local/bin/DKST Linux Battery Agent"),
    ]
    if path_agent:
        candidates.append(Path(path_agent))

    for candidate in candidates:
        if candidate and candidate.exists() and os.access(candidate, os.X_OK):
            return candidate
    return None


class LinuxBatteryGUI:
    def __init__(self):
        self.root = Tk()
        self.root.title("DKST Linux Battery Agent")
        self.root.resizable(False, False)

        self.config = load_config()
        self.server_var = StringVar(value=self.config["server"])
        self.api_key_var = StringVar(value=self.config["api_key"])
        self.interval_var = StringVar(value=self.config["interval_seconds"])
        self.status_var = StringVar()
        self.next_row = 0

        self.build()
        self.refresh_status()

    def build(self):
        main = ttk.Frame(self.root, padding=16)
        main.pack(fill=BOTH, expand=True)

        self.add_row(main, "Server URL (macOS):Port", self.server_var, show=None)
        self.add_row(main, "API Key", self.api_key_var, show="*")
        self.add_row(main, "Interval seconds", self.interval_var, show=None)

        status = ttk.Label(main, textvariable=self.status_var)
        status.grid(row=self.next_row, column=0, columnspan=2, sticky="w", pady=(8, 0))
        self.next_row += 1

        buttons = ttk.Frame(main)
        buttons.grid(row=self.next_row, column=0, columnspan=2, sticky="e", pady=(16, 0))

        run_button = ttk.Button(buttons, text="Run", command=self.run_agent)
        run_button.pack(side=LEFT, padx=(0, 8))

        quit_button = ttk.Button(buttons, text="Quit", command=self.quit_app)
        quit_button.pack(side=RIGHT)

    def add_row(self, parent, label, variable, show):
        row = self.next_row
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=6)
        entry = ttk.Entry(parent, textvariable=variable, width=46, show=show)
        entry.grid(row=row, column=1, sticky="ew", pady=6)
        self.next_row += 1

    def refresh_status(self):
        pid = running_pid()
        if pid:
            self.status_var.set(f"Running: PID {pid}")
        else:
            self.status_var.set("Idle")

    def current_config(self):
        server = self.server_var.get().strip()
        api_key = self.api_key_var.get().strip()
        interval = self.interval_var.get().strip()
        return {
            "server": server,
            "api_key": api_key,
            "interval_seconds": interval,
        }

    def validate(self, config):
        if not config["server"]:
            raise ValueError("Enter the server URL (macOS):port.")
        if not config["api_key"]:
            raise ValueError("Enter the API key.")
        try:
            interval = float(config["interval_seconds"])
        except ValueError as exc:
            raise ValueError("Interval seconds must be a number.") from exc
        if interval <= 0:
            raise ValueError("Interval seconds must be greater than 0.")
        return interval

    def run_agent(self):
        config = self.current_config()
        try:
            interval = self.validate(config)
        except ValueError as exc:
            messagebox.showerror("Linux Battery", str(exc))
            return

        agent = find_agent_binary()
        if not agent:
            messagebox.showerror(
                "Linux Battery",
                "Could not find the DKST Linux Battery Agent executable.\n"
                "Run ./build-linux.sh from the project root first.",
            )
            return

        save_config(config)
        stop_agent()
        APP_DIR.mkdir(parents=True, exist_ok=True)

        command = [
            str(agent),
            "-server",
            config["server"],
            "-api-key",
            config["api_key"],
            "-interval",
            f"{interval:g}s",
        ]

        with LOG_PATH.open("ab") as log_file:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )

        PID_PATH.write_text(str(process.pid), encoding="utf-8")
        self.root.destroy()

    def quit_app(self):
        stop_agent()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def main():
    try:
        LinuxBatteryGUI().run()
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
