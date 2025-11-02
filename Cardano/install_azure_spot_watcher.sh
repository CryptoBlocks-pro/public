#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="azure-spot-eviction-watcher"
PYTHON_SCRIPT_NAME="azure-spot-eviction-watcher.py"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run with root privileges. Try again with sudo or as root." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
HOME_DIR="$(eval echo "~${TARGET_USER}")"
PYTHON_SCRIPT_PATH="${HOME_DIR}/${PYTHON_SCRIPT_NAME}"
PYTHON_BIN=""

install_python() {
  echo "Attempting to install Python..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3
  elif command -v zypper >/dev/null 2>&1; then
    zypper refresh
    zypper install -y python3
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python
  else
    echo "Unsupported package manager. Please install Python manually and re-run." >&2
    exit 1
  fi
}

ensure_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$candidate")"
      return
    fi
  done
  install_python
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$candidate")"
      return
    fi
  done
  echo "Python installation failed." >&2
  exit 1
}

ensure_python

TARGET_GROUP="$(id -gn "$TARGET_USER")"

cat <<'PYTHONSCRIPT' >"${PYTHON_SCRIPT_PATH}"
#!/usr/bin/env python3
"""Azure Spot VM eviction watcher.

Polls Azure Instance Metadata Service for scheduled eviction events and logs
warnings when a preemption is imminent.
"""
import json
import logging
import logging.handlers
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from urllib import error, request

METADATA_ENDPOINT = "http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01"
HEADERS = {"Metadata": "true"}
POLL_INTERVAL = int(os.environ.get("AZURE_EVICTION_POLL_INTERVAL_SECONDS", "5"))
LOGGER = logging.getLogger("azure_spot_eviction_watcher")
LOGGER.setLevel(logging.INFO)

CARDANO_SERVICE = os.environ.get("AZURE_EVICTION_CARDANO_SERVICE", "cnode.service")
SERVICE_STOP_TIMEOUT = int(os.environ.get("AZURE_EVICTION_SERVICE_STOP_TIMEOUT_SECONDS", "120"))
SERVICE_STOP_COMMAND_TEMPLATE = os.environ.get(
    "AZURE_EVICTION_SERVICE_STOP_COMMAND",
    "sudo -n systemctl stop {service}",
)

try:
    handler = logging.handlers.SysLogHandler(address="/dev/log")
except OSError:
    handler = logging.StreamHandler(sys.stdout)

formatter = logging.Formatter("%(asctime)s %(name)s %(levelname)s: %(message)s")
handler.setFormatter(formatter)
LOGGER.addHandler(handler)

SHOULD_RUN = True
SEEN_EVENTS = set()


def _handle_signal(signum, _frame):
    global SHOULD_RUN
    LOGGER.info("Received signal %s, shutting down.", signum)
    SHOULD_RUN = False


for _sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(_sig, _handle_signal)


def fetch_scheduled_events():
    req = request.Request(METADATA_ENDPOINT, headers=HEADERS)
    try:
        with request.urlopen(req, timeout=2) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except TimeoutError as exc:
        LOGGER.warning("Timed out querying scheduled events: %s", exc)
    except socket.timeout as exc:
        LOGGER.warning("Socket timeout while querying scheduled events: %s", exc)
    except error.URLError as exc:  # Includes HTTP errors
        LOGGER.warning("Failed to query scheduled events: %s", exc)
    except json.JSONDecodeError as exc:
        LOGGER.warning("Invalid JSON from metadata service: %s", exc)
    except Exception as exc:  # Catch-all to keep the watcher alive
        LOGGER.exception("Unexpected error querying scheduled events: %s", exc)
    return None


def is_service_active(service_name: str) -> bool:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service_name],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception as exc:
        LOGGER.warning("Failed to check status for %s: %s", service_name, exc)
        return False
    return result.returncode == 0


def stop_service(service_name: str) -> None:
    if not service_name:
        LOGGER.info("No service configured for eviction shutdown; skipping stop request.")
        return

    if not is_service_active(service_name):
        LOGGER.info("Service %s already inactive; no shutdown needed.", service_name)
        return

    LOGGER.warning("Requesting graceful stop of service %s due to imminent spot eviction.", service_name)
    command_str = SERVICE_STOP_COMMAND_TEMPLATE.format(service=service_name)
    command = shlex.split(command_str)
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=SERVICE_STOP_TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        LOGGER.error("Timeout while stopping service %s: %s", service_name, exc)
        return
    except Exception as exc:
        LOGGER.exception("Error while stopping service %s: %s", service_name, exc)
        return

    if result.returncode == 0:
        if not is_service_active(service_name):
            LOGGER.info("Service %s stop command completed successfully.", service_name)
        else:
            LOGGER.warning(
                "Service %s stop command succeeded but service still reports active.",
                service_name,
            )
    else:
        LOGGER.error(
            "Service %s stop command failed (exit %s). stdout=%r stderr=%r",
            service_name,
            result.returncode,
            result.stdout.strip(),
            result.stderr.strip(),
        )


def process_events(payload):
    if not payload:
        return
    events = payload.get("Events", [])
    for event in events:
        event_id = event.get("EventId")
        event_type = event.get("EventType")
        status = event.get("EventStatus")
        resources = ",".join(event.get("Resources", []))
        not_before = event.get("NotBefore")

        if event_id in SEEN_EVENTS:
            continue

        if event_type == "Preempt" and status in {"Scheduled", "InProgress"}:
            LOGGER.warning(
                "Spot eviction event detected (id=%s, resources=%s, not_before=%s)",
                event_id,
                resources or "*",
                not_before or "unknown",
            )
            stop_service(CARDANO_SERVICE)
            SEEN_EVENTS.add(event_id)


if __name__ == "__main__":
    LOGGER.info("Azure Spot eviction watcher started. Poll interval: %ss", POLL_INTERVAL)
    while SHOULD_RUN:
        payload = fetch_scheduled_events()
        process_events(payload)
        time.sleep(POLL_INTERVAL)
    LOGGER.info("Azure Spot eviction watcher stopped.")
PYTHONSCRIPT

chmod 0755 "${PYTHON_SCRIPT_PATH}"
chown "${TARGET_USER}:${TARGET_GROUP}" "${PYTHON_SCRIPT_PATH}"

cat <<SERVICE >"${SERVICE_FILE}"
[Unit]
Description=Azure Spot Eviction Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_GROUP}
ExecStart=${PYTHON_BIN} ${PYTHON_SCRIPT_PATH}
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

printf 'Installation complete. Service status:\n\n'
systemctl status --no-pager "${SERVICE_NAME}.service" || true
