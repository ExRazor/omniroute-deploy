#!/bin/bash

# Exit on undefined variables (but not on errors - we handle those explicitly)
set -u

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .env file in parent directory
if [ ! -f "${SCRIPT_DIR}/../.env" ]; then
    echo "Error: .env file not found at ${SCRIPT_DIR}/../.env"
    echo "Please create .env file from .env.example"
    exit 1
fi

set -a
source "${SCRIPT_DIR}/../.env"
set +a

# Backup configuration (defaults)
PREFIX="${PREFIX:-omniroute}"
RCLONE_CONFIG_NAME="${RCLONE_CONFIG_NAME:-omniroute}"
RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH:-/}"
BACKUP_RETENTION_LOCAL_DAYS="${BACKUP_RETENTION_LOCAL_DAYS:-3}"
BACKUP_RETENTION_REMOTE_DAYS="${BACKUP_RETENTION_REMOTE_DAYS:-30}"

# Data dir to back up (HOST_DATA_DIR from .env, default = <repo>/data)
HOST_DATA_DIR="${HOST_DATA_DIR:-${SCRIPT_DIR}/../data}"
[[ "${HOST_DATA_DIR}" != /* ]] && HOST_DATA_DIR="${SCRIPT_DIR}/../${HOST_DATA_DIR}"

# Check if rclone is available and configured
RCLONE_AVAILABLE=false
RCLONE_UNAVAILABLE_REASON=""

if ! command -v rclone &> /dev/null; then
    RCLONE_UNAVAILABLE_REASON="rclone command not found"
elif ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_CONFIG_NAME}:$"; then
    RCLONE_UNAVAILABLE_REASON="rclone config '${RCLONE_CONFIG_NAME}' not found"
else
    RCLONE_AVAILABLE=true
fi

# Detect 7-Zip binary (7zz, 7z, 7za)
SEVENZIP=""
for candidate in 7zz 7z 7za; do
    if command -v "$candidate" &> /dev/null; then
        SEVENZIP="$candidate"
        break
    fi
done

if [ -z "$SEVENZIP" ]; then
    echo "Error: 7-Zip not found. Install p7zip (7z/7za) or 7-zip (7zz)."
    exit 1
fi

# Parse command line arguments
LOCAL_ONLY=false
if [ "${1:-}" == "--local" ]; then
    LOCAL_ONLY=true
    echo "Mode: Local backup only (no remote upload)"
else
    # Check if rclone is available
    if [ "$RCLONE_AVAILABLE" != true ]; then
        echo "Warning: ${RCLONE_UNAVAILABLE_REASON}. Falling back to local-only mode."
        LOCAL_ONLY=true
    fi

    if [ "$LOCAL_ONLY" = true ]; then
        echo "Mode: Local backup only (rclone not available)"
    else
        echo "Mode: Default (local + remote upload)"
    fi
fi

# Cleanup function for trap
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo "Script interrupted or failed. Cleaning up..."
        # Remove incomplete backup file if any
        if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ]; then
            rm -f "$BACKUP_FILE"
        fi
    fi
}

# Set trap for cleanup on exit, interrupt, or error
trap cleanup_on_exit EXIT INT TERM

BACKUP_DIR="${SCRIPT_DIR}/backups"
BACKUP_FILENAME="${PREFIX}_$(date +%Y%m%d_%H%M).7z"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILENAME}"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Clean up old local backups (keep last N days).
# Runs BEFORE new backup creation so disk space is freed first.
echo ""
echo "Cleaning up old local backups (retention: ${BACKUP_RETENTION_LOCAL_DAYS} days)..."
if find "$BACKUP_DIR" -name "${PREFIX}_*.7z" -type f -mtime +${BACKUP_RETENTION_LOCAL_DAYS} -delete; then
    echo "Local backup cleanup completed"
else
    echo "Warning: Failed to clean up old local backups"
fi

# Check if backup file with same name exists and remove it
if [ -f "$BACKUP_FILE" ]; then
    echo "Backup file already exists: $BACKUP_FILE"
    echo "Removing old backup file..."
    rm -f "$BACKUP_FILE"
fi

# Validate the data directory exists
if [ ! -d "$HOST_DATA_DIR" ]; then
    echo "Error: Data directory not found: $HOST_DATA_DIR"
    exit 1
fi

echo ""
echo "Starting OmniRoute data backup..."
echo "Data dir: $HOST_DATA_DIR"
echo "Backup file: $BACKUP_FILE"
echo "Compression: 7-Zip ($SEVENZIP) level 5"
echo ""

# Paths excluded from the archive (relative to the data dir root)
EXCLUDES=(
    -xr!.venv
    -xr!lazy-packages
    -xr!.npm
    -xr!node_modules
    -xr!cache
    -xr!image_cache
    -xr!audio_cache
    -xr!ms-playwright
    -xr!home/.cache
    -xr!home/.npm
    -xr!backups
    -xr!sandboxes
    -xr!desktop
    -xr!workspace
    -xr!redis
    -xr!call_logs
    -xr!logs
    -xr!db_backups
    -xr!tmp_fuzz
    -xr!lsp
    -xr!bin
    -xr!pulse
    -xr!models_dev_cache.json
    -xr!provider_models_cache.json
    -xr!*.log
    -xr!*.pid
    -xr!*.lock
)

# Archive the data dir contents (relative paths so restore extracts directly)
# 7z always runs via sudo -n: data dir is root-owned (container bind-mount).
# Ensure the invoking user can cd into the dir (root-owned 700 otherwise).
sudo -n chmod 755 "$HOST_DATA_DIR" 2>/dev/null || true
SEVENZIP_CMD=(sudo -n "$SEVENZIP")
( cd "$HOST_DATA_DIR" && "${SEVENZIP_CMD[@]}" a -mx=5 "$BACKUP_FILE" . "${EXCLUDES[@]}" )
SEVENZIP_EXIT=$?
# 7z exit codes: 0 = OK, 1 = warning (e.g. file vanished during scan) — archive is still valid
if [ "$SEVENZIP_EXIT" -ne 0 ] && [ "$SEVENZIP_EXIT" -ne 1 ]; then
    echo "Error: Backup failed (7-Zip exit code $SEVENZIP_EXIT)"
    exit 1
fi
# Restore ownership of the archive to the invoking user (7z ran as root via sudo)
sudo -n chown "$(id -u):$(id -g)" "$BACKUP_FILE" 2>/dev/null || true

# Validate backup file exists and has size
if [ ! -f "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
    echo "Error: Backup file is missing or empty"
    exit 1
fi

echo ""
echo "Backup completed successfully."
echo "Backup file: $BACKUP_FILE"
echo "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"

# Upload to remote if not local-only mode
if [ "$LOCAL_ONLY" = false ]; then
    echo ""
    echo "Uploading backup to remote storage..."

    # Upload to rclone remote
    REMOTE_PATH="${RCLONE_CONFIG_NAME}:${RCLONE_REMOTE_PATH}"
    echo "Remote path: ${REMOTE_PATH}"

    if rclone copy "$BACKUP_FILE" "${REMOTE_PATH}" --progress; then
        echo "Backup uploaded to remote successfully"
    else
        echo "Warning: Failed to upload backup to remote"
        echo "Local backup saved at: $BACKUP_FILE"
    fi
fi

# Clean up old remote backups if not local-only mode
if [ "$LOCAL_ONLY" = false ]; then
    echo ""
    echo "Cleaning up old remote backups (retention: ${BACKUP_RETENTION_REMOTE_DAYS} days)..."

    # Portable date calculation (works on Linux and macOS)
    # Try BSD date first (macOS), then GNU date (Linux)
    CUTOFF_DATE=""
    if date -v-${BACKUP_RETENTION_REMOTE_DAYS}d +%Y%m%d >/dev/null 2>&1; then
        CUTOFF_DATE=$(date -v-${BACKUP_RETENTION_REMOTE_DAYS}d +%Y%m%d)
    elif date -d "${BACKUP_RETENTION_REMOTE_DAYS} days ago" +%Y%m%d >/dev/null 2>&1; then
        CUTOFF_DATE=$(date -d "${BACKUP_RETENTION_REMOTE_DAYS} days ago" +%Y%m%d)
    fi

    # Verify we got a valid cutoff date
    if [ -z "$CUTOFF_DATE" ]; then
        echo "Warning: Unable to calculate cutoff date. Skipping remote backup cleanup."
    else
        # Validate cutoff date is in the past (should be less than today)
        TODAY=$(date +%Y%m%d)
        if [ "$CUTOFF_DATE" -ge "$TODAY" ]; then
            echo "Error: Cutoff date calculation error ($CUTOFF_DATE >= $TODAY). Skipping remote backup cleanup."
        else
            # Get list of remote backups
            rclone lsf "${REMOTE_PATH}" --files-only | grep "^${PREFIX}_[0-9]\{8\}_[0-9]\{4\}\.7z$" | while read -r filename; do
                # Extract date from filename (PREFIX_YYYYMMDD_HHMM.7z)
                file_date=$(echo "$filename" | grep -oE '[0-9]{8}' | head -1)

                # Compare dates (numeric comparison)
                if [ "$file_date" -lt "$CUTOFF_DATE" ]; then
                    echo "Deleting old remote backup: $filename (date: $file_date)"
                    rclone delete "${REMOTE_PATH}${filename}"
                fi
            done

            echo "Remote backup cleanup completed"
        fi
    fi
fi

echo ""
echo "To restore this backup, use:"
echo "  ./backup/restore.sh"
