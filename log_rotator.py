import sys
import os

LOG_FILE = "EARUruntime.log"
MAX_LINES = 1000

def rotate():
    if os.path.exists(LOG_FILE):
        # Keep one backup
        backup = LOG_FILE + ".old"
        if os.path.exists(backup):
            os.remove(backup)
        os.rename(LOG_FILE, backup)

def get_line_count():
    if not os.path.exists(LOG_FILE):
        return 0
    try:
        with open(LOG_FILE, 'rb') as f:
            return sum(1 for _ in f)
    except Exception:
        return 0

# Initial check on startup
if get_line_count() >= MAX_LINES:
    rotate()

line_count = get_line_count()

with open(LOG_FILE, 'a') as f:
    for line in sys.stdin:
        # We don't write to stdout to avoid duplication if launchd is also capturing
        f.write(line)
        f.flush()
        line_count += 1
        if line_count >= MAX_LINES:
            f.close()
            rotate()
            f = open(LOG_FILE, 'a')
            line_count = 0
