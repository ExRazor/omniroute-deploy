#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"
LOG_FILE="${SCRIPT_DIR}/logs/backup.log"

# Check if backup script exists
if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "Error: Backup script not found at $BACKUP_SCRIPT"
    exit 1
fi

# Create logs directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

echo "OmniRoute Backup Cron Job Installer"
echo "================================"
echo ""
echo "This will install a cron job to automatically backup the OmniRoute data directory."
echo ""
echo "Backup script: $BACKUP_SCRIPT"
echo "Log file: $LOG_FILE"
echo ""

# Ask user for schedule
echo "Select backup schedule:"
echo "1) Daily at 12:00 AM (default)"
echo "2) Daily at 2:00 AM"
echo "3) Daily at 3:00 AM"
echo "4) Every 6 hours"
echo "5) Every 12 hours"
echo "6) Weekly (Sunday at 2:00 AM)"
echo "7) Custom (manual crontab entry)"
echo "8) Cancel"
echo ""

read -p "Enter your choice (1-8): " choice

case $choice in
    1)
        CRON_SCHEDULE="0 0 * * *"
        DESCRIPTION="Daily at 12:00 AM"
        ;;
    2)
        CRON_SCHEDULE="0 2 * * *"
        DESCRIPTION="Daily at 2:00 AM"
        ;;
    3)
        CRON_SCHEDULE="0 3 * * *"
        DESCRIPTION="Daily at 3:00 AM"
        ;;
    4)
        CRON_SCHEDULE="0 */6 * * *"
        DESCRIPTION="Every 6 hours"
        ;;
    5)
        CRON_SCHEDULE="0 */12 * * *"
        DESCRIPTION="Every 12 hours"
        ;;
    6)
        CRON_SCHEDULE="0 2 * * 0"
        DESCRIPTION="Weekly on Sunday at 2:00 AM"
        ;;
    7)
        echo ""
        read -p "Enter custom crontab schedule (e.g., '0 0 * * *'): " CRON_SCHEDULE
        DESCRIPTION="Custom schedule: $CRON_SCHEDULE"
        ;;
    8)
        echo "Installation cancelled."
        exit 0
        ;;
    *)
        echo "Invalid choice. Installation cancelled."
        exit 1
        ;;
esac

echo ""
echo "Schedule: $DESCRIPTION"
echo ""

# Ask for backup mode
echo "Select backup mode:"
echo "1) Local + Remote (default - upload to rclone)"
echo "2) Local only (--local flag)"
echo ""

read -p "Enter your choice (1-2): " mode_choice

case $mode_choice in
    1)
        BACKUP_FLAGS=""
        MODE_DESCRIPTION="Local + Remote"
        ;;
    2)
        BACKUP_FLAGS="--local"
        MODE_DESCRIPTION="Local only"
        ;;
    *)
        echo "Invalid choice. Using default (Local + Remote)."
        BACKUP_FLAGS=""
        MODE_DESCRIPTION="Local + Remote"
        ;;
esac

echo ""
echo "Backup mode: $MODE_DESCRIPTION"
echo ""

# Construct the cron job
# Note: Using > to overwrite log file (not append)
CRON_JOB="$CRON_SCHEDULE $BACKUP_SCRIPT $BACKUP_FLAGS > $LOG_FILE 2>&1"

# Show the cron job to user
echo "Cron job to be installed:"
echo "-------------------------"
echo "$CRON_JOB"
echo ""

read -p "Proceed with installation? (y/n): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Installation cancelled."
    exit 0
fi

# Backup current crontab
TEMP_CRON=$(mktemp)
crontab -l > "$TEMP_CRON" 2>/dev/null || true

# Check if backup job already exists
if grep -q "$BACKUP_SCRIPT" "$TEMP_CRON"; then
    echo ""
    echo "Warning: A backup job already exists in crontab."
    read -p "Remove existing job and install new one? (y/n): " replace

    if [ "$replace" == "y" ] || [ "$replace" == "Y" ]; then
        # Remove existing backup job and its comment line
        grep -v "$BACKUP_SCRIPT" "$TEMP_CRON" | grep -v "^# OmniRoute backup -" > "${TEMP_CRON}.new"
        mv "${TEMP_CRON}.new" "$TEMP_CRON"
    else
        echo "Installation cancelled."
        rm -f "$TEMP_CRON"
        exit 0
    fi
fi

# Add comment and new cron job
echo "" >> "$TEMP_CRON"
echo "# OmniRoute backup - $DESCRIPTION ($MODE_DESCRIPTION)" >> "$TEMP_CRON"
echo "$CRON_JOB" >> "$TEMP_CRON"

# Install new crontab
if crontab "$TEMP_CRON"; then
    echo ""
    echo "✓ Cron job installed successfully!"
    echo ""
    echo "Summary:"
    echo "  Schedule: $DESCRIPTION"
    echo "  Mode: $MODE_DESCRIPTION"
    echo "  Log file: $LOG_FILE"
    echo ""
    echo "To view current crontab: crontab -l"
    echo "To edit crontab: crontab -e"
    echo "To remove this job: ./backup/uninstall_cron.sh"
else
    echo "Error: Failed to install cron job"
    rm -f "$TEMP_CRON"
    exit 1
fi

# Cleanup
rm -f "$TEMP_CRON"

echo ""
echo "Note: Logs will be overwritten on each backup run (not appended)."
echo "If you need to keep logs, consider modifying the cron job to use >> instead of >"
