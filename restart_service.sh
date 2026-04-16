#!/bin/bash

# Path to the plist file
PLIST_NAME=com.earu.service.plist
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"

# Copy the plist to /Library/LaunchDaemons
sudo cp ${PLIST_NAME} ${PLIST_PATH}
sudo chown root:wheel ${PLIST_PATH}
sudo chmod 644 ${PLIST_PATH}

# Unload the service if it is already loaded
sudo launchctl unload "$PLIST_PATH" 2>/dev/null

# Load the service
sudo launchctl load "$PLIST_PATH"

echo "Service ${PLIST_NAME} restarted."
