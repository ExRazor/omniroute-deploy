#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"

echo "OmniRoute Backup Cron Job Uninstaller"
echo "==================================="
echo ""

# Check if crontab exists
if ! crontab -l > /dev/null 2>&1; then
    echo "No crontab found for current user."
    exit 0
fi

# Backup current crontab
TEMP_CRON=$(mktemp)
crontab -l > "$TEMP_CRON" 2>/dev/null

# Check if backup job exists
if ! grep -q "$BACKUP_SCRIPT" "$TEMP_CRON"; then
    echo "No backup job found in crontab."
    rm -f "$TEMP_CRON"
    exit 0
fi

# Show existing job
echo "Found backup job(s) in crontab:"
echo ""
grep -B1 "$BACKUP_SCRIPT" "$TEMP_CRON" | grep -v "^--$"
echo ""

read -p "Remove this job from crontab? (y/n): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Uninstall cancelled."
    rm -f "$TEMP_CRON"
    exit 0
fi

# Remove backup job and its comment line
grep -v "$BACKUP_SCRIPT" "$TEMP_CRON" | grep -v "^# OmniRoute backup -" > "${TEMP_CRON}.new"

# Install modified crontab
if crontab "${TEMP_CRON}.new"; then
    echo ""
    echo "✓ Backup job removed successfully from crontab!"
else
    echo "Error: Failed to update crontab"
    rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
    exit 1
fi

# Cleanup
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
