#!/bin/bash

# Path to the plist file
PLIST_NAME=com.earu.service.plist
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"

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
