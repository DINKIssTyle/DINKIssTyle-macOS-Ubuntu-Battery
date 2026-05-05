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

# PyQt6 모듈 임포트
from PyQt6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, 
                             QLabel, QLineEdit, QPushButton, QMessageBox, QGridLayout)
from PyQt6.QtCore import Qt

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
    if not pid: return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False

def running_pid():
    pid = read_pid()
    if is_process_running(pid):
        return pid
    try:
        if PID_PATH.exists(): PID_PATH.unlink()
    except OSError:
        pass
    return None

def stop_agent():
    pid = running_pid()
    if not pid: return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.time() + 5
    while time.time() < deadline:
        if not is_process_running(pid): break
        time.sleep(0.1)
    if is_process_running(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        if PID_PATH.exists(): PID_PATH.unlink()
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

class LinuxBatteryGUI(QWidget):
    def __init__(self):
        super().__init__()
        self.config = load_config()
        self.init_ui()
        self.refresh_status()

    def init_ui(self):
        self.setWindowTitle("DKST Linux Battery Agent")
        self.setFixedSize(450, 220)
        
        layout = QVBoxLayout()
        grid = QGridLayout()

        # 입력 필드 구성
        self.server_input = QLineEdit(self.config["server"])
        self.api_key_input = QLineEdit(self.config["api_key"])
        self.api_key_input.setEchoMode(QLineEdit.EchoMode.Password)
        self.interval_input = QLineEdit(self.config["interval_seconds"])

        grid.addWidget(QLabel("Server URL (macOS):Port"), 0, 0)
        grid.addWidget(self.server_input, 0, 1)
        grid.addWidget(QLabel("API Key"), 1, 0)
        grid.addWidget(self.api_key_input, 1, 1)
        grid.addWidget(QLabel("Interval seconds"), 2, 0)
        grid.addWidget(self.interval_input, 2, 1)
        
        layout.addLayout(grid)

        # 상태 표시 레이블
        self.status_label = QLabel("Idle")
        layout.addWidget(self.status_label)

        # 버튼 구성
        btn_layout = QHBoxLayout()
        run_btn = QPushButton("Run")
        run_btn.clicked.connect(self.run_agent)
        quit_btn = QPushButton("Quit")
        quit_btn.clicked.connect(self.quit_app)
        
        btn_layout.addStretch()
        btn_layout.addWidget(run_btn)
        btn_layout.addWidget(quit_btn)
        layout.addLayout(btn_layout)

        self.setLayout(layout)

    def refresh_status(self):
        pid = running_pid()
        self.status_label.setText(f"Running: PID {pid}" if pid else "Idle")

    def run_agent(self):
        config = {
            "server": self.server_input.text().strip(),
            "api_key": self.api_key_input.text().strip(),
            "interval_seconds": self.interval_input.text().strip(),
        }

        try:
            if not config["server"]: raise ValueError("Enter the server URL.")
            if not config["api_key"]: raise ValueError("Enter the API key.")
            interval = float(config["interval_seconds"])
            if interval <= 0: raise ValueError("Interval must be > 0.")
        except ValueError as e:
            QMessageBox.critical(self, "Error", str(e))
            return

        agent = find_agent_binary()
        if not agent:
            QMessageBox.critical(self, "Error", "Agent executable not found.")
            return

        save_config(config)
        stop_agent()
        APP_DIR.mkdir(parents=True, exist_ok=True)

        command = [str(agent), "-server", config["server"], "-api-key", config["api_key"], "-interval", f"{interval:g}s"]

        with LOG_PATH.open("ab") as log_file:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log_file, 
                                       stderr=subprocess.STDOUT, start_new_session=True)

        PID_PATH.write_text(str(process.pid), encoding="utf-8")
        self.close()

    def quit_app(self):
        stop_agent()
        self.close()

def main():
    app = QApplication(sys.argv)
    gui = LinuxBatteryGUI()
    gui.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()