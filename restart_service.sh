#!/bin/bash

# restart_service.sh — Restart the EARU daemon service.
# Usage:
#   sudo bash restart_service.sh           — fast incremental restart
#   sudo bash restart_service.sh --clean   — force full clean rebuild

DAEMON_DIR="/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon"
PLIST_NAME=com.earu.service.plist
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"

# Handle --clean flag: create marker so start.sh knows to clean
if [ "$1" = "--clean" ]; then
    echo "[*] --clean flag: will force full clean rebuild on next start..."
    touch "$DAEMON_DIR/.force_clean"
fi

# Copy the plist to /Library/LaunchDaemons
sudo cp ${PLIST_NAME} ${PLIST_PATH}
sudo chown root:wheel ${PLIST_PATH}
sudo chmod 644 ${PLIST_PATH}

echo "Stopping service if running..."
sudo launchctl bootout system "${PLIST_PATH}" 2>/dev/null

echo "Enabling service..."
sudo launchctl enable "system/com.earu.service" 2>/dev/null

echo "Starting service..."
sudo launchctl bootstrap system "${PLIST_PATH}"

echo "Service ${PLIST_NAME} restarted."
