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

# Restore configuration (defaults)
PREFIX="${PREFIX:-omniroute}"
RCLONE_CONFIG_NAME="${RCLONE_CONFIG_NAME:-omniroute}"
RCLONE_REMOTE_PATH="${RCLONE_REMOTE_PATH:-/}"

# Data dir to restore into (HOST_DATA_DIR from .env, default = <repo>/data)
HOST_DATA_DIR="${HOST_DATA_DIR:-${SCRIPT_DIR}/../data}"
[[ "${HOST_DATA_DIR}" != /* ]] && HOST_DATA_DIR="${SCRIPT_DIR}/../${HOST_DATA_DIR}"

# Refuse to restore into unsafe paths
if [ -z "$HOST_DATA_DIR" ] || [ "$HOST_DATA_DIR" = "/" ]; then
    echo "Error: Refusing to restore into unsafe path: ${HOST_DATA_DIR}"
    exit 1
fi

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

# Track restore state
RESTORE_IN_PROGRESS=false

# Cleanup function for trap
cleanup_on_exit() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo ""

        if [ "$RESTORE_IN_PROGRESS" = true ]; then
            echo "=========================================="
            echo "WARNING: Restore was interrupted!"
            echo "Data directory '$HOST_DATA_DIR' may be in an incomplete state."
            echo "A pre-restore backup was created before extraction."
            echo "Please check the data directory and restore again if needed."
            echo "=========================================="
        else
            echo "Script cancelled or failed. Cleaning up..."
        fi
    fi
}

# Signal handler for Ctrl+C
handle_interrupt() {
    if [ "$RESTORE_IN_PROGRESS" = true ]; then
        echo ""
        echo "=========================================="
        echo "INTERRUPT DETECTED!"
        echo "Restore is in progress - interruption is NOT recommended!"
        echo "Data directory may be left in an incomplete state."
        echo "Press Ctrl+C again within 5 seconds to force quit,"
        echo "or wait to continue the restore process..."
        echo "=========================================="

        # Give user 5 seconds to abort
        sleep 5 && return

        # If we get here, user pressed Ctrl+C again
        echo ""
        echo "Force quit requested. Exiting..."
        exit 130
    else
        echo ""
        echo "Restore cancelled by user."
        exit 130
    fi
}

# Set trap for cleanup on exit
trap cleanup_on_exit EXIT

# Set trap for interrupt (Ctrl+C)
trap handle_interrupt INT TERM

# Find available backup files
BACKUP_DIR="${SCRIPT_DIR}/backups"
mkdir -p "$BACKUP_DIR"

# Function to list local backups
list_local_backups() {
    find "$BACKUP_DIR" -maxdepth 1 -name "${PREFIX}_*.7z" -type f | sort -r
}

# Maximum number of remote backups to list (newest first)
MAX_REMOTE_BACKUPS=5

# Function to list remote backups with sizes in a single rclone call.
# Emits "filename|bytes" lines, sorted by filename descending (newest first),
# capped at MAX_REMOTE_BACKUPS.
list_remote_backups() {
    REMOTE_PATH="${RCLONE_CONFIG_NAME}:${RCLONE_REMOTE_PATH}"
    rclone lsf "${REMOTE_PATH}" --files-only --format "ps" --separator "|" \
        --include "${PREFIX}_*.7z" 2>/dev/null \
        | grep -E "^${PREFIX}_[0-9]{8}_[0-9]{4}\.7z\|[0-9]+$" \
        | sort -t'|' -k1,1r \
        | head -n "$MAX_REMOTE_BACKUPS"
}

# Function to get backup date from filename
get_backup_date() {
    local filename=$(basename "$1")
    echo "$filename" | grep -oE '[0-9]{8}' | head -1
}

# Function to format date for display
format_date() {
    local date_str="$1"
    # Convert YYYYMMDD to YYYY-MM-DD
    echo "${date_str:0:4}-${date_str:4:2}-${date_str:6:2}"
}

# Function to get file size
get_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        du -h "$file" | cut -f1
    else
        echo "N/A"
    fi
}

# Convert a byte count to human-readable IEC format (local, no network)
human_readable_size() {
    local size="$1"
    if [ -z "$size" ] || ! [ "$size" -gt 0 ] 2>/dev/null; then
        echo "N/A"
        return
    fi
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "N/A"
    elif [ "$size" -lt 1024 ]; then
        echo "${size}B"
    elif [ "$size" -lt 1048576 ]; then
        echo "$((size / 1024))KiB"
    elif [ "$size" -lt 1073741824 ]; then
        echo "$((size / 1048576))MiB"
    else
        echo "$((size / 1073741824))GiB"
    fi
}

# Paths excluded from the archive (relative to the data dir root)
# Mirrors the excludes used by backup.sh
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
    -xr!*.log
    -xr!*.pid
    -xr!*.lock
)

echo "Scanning for available backups..."
echo ""

# Get local backups
LOCAL_BACKUPS=($(list_local_backups))

# Get remote backups with sizes (only if rclone is available and configured)
# Single rclone round-trip; sizes stored in REMOTE_SIZES, names in REMOTE_ORDERED (sorted).
REMOTE_ORDERED=()
declare -A REMOTE_SIZES
if [ "$RCLONE_AVAILABLE" = true ]; then
    echo "Checking remote storage..."
    while IFS='|' read -r name bytes; do
        [ -n "$name" ] || continue
        REMOTE_SIZES["$name"]="$bytes"
        REMOTE_ORDERED+=("$name")
    done < <(list_remote_backups)
else
    echo "Note: ${RCLONE_UNAVAILABLE_REASON}. Only showing local backups."
fi

# Create combined list with metadata
declare -A BACKUP_METADATA
declare -A LOCAL_NAMES
COMBINED_BACKUPS=()
BACKUP_LOCATIONS=()

# Process local backups
for backup in "${LOCAL_BACKUPS[@]}"; do
    filename=$(basename "$backup")
    LOCAL_NAMES["$filename"]=1
    date=$(get_backup_date "$filename")
    size=$(get_file_size "$backup")
    COMBINED_BACKUPS+=("$filename")
    BACKUP_LOCATIONS+=("local")
    BACKUP_METADATA["$filename"]="Local | $(format_date $date) | Size: $size"
done

# Process remote backups (skip any already present locally)
# Order preserved via REMOTE_ORDERED (already sorted newest-first).
for remote_backup in "${REMOTE_ORDERED[@]}"; do
    [ -n "${LOCAL_NAMES[$remote_backup]:-}" ] && continue
    date=$(get_backup_date "$remote_backup")
    size=$(human_readable_size "${REMOTE_SIZES[$remote_backup]}")
    COMBINED_BACKUPS+=("$remote_backup")
    BACKUP_LOCATIONS+=("remote")
    BACKUP_METADATA["$remote_backup"]="Remote | $(format_date $date) | Size: $size"
done

# Check if any backups exist
if [ ${#COMBINED_BACKUPS[@]} -eq 0 ]; then
    echo "Error: No backup files found in local or remote storage"
    exit 1
fi

# If backup file provided as argument, use it
if [ $# -gt 0 ]; then
    BACKUP_FILE="$1"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Error: Backup file not found: $BACKUP_FILE"
        exit 1
    fi
    SELECTED_LOCATION="local"
else
    # Interactive selection menu
    echo "Available backups:"
    echo ""

    # Display backups in readable format
    for i in "${!COMBINED_BACKUPS[@]}"; do
        filename="${COMBINED_BACKUPS[$i]}"
        metadata="${BACKUP_METADATA[$filename]}"
        # Add 1 to index since array is 0-indexed but menu should start at 1
        menu_num=$((i + 1))
        printf "%2d) %s\n" "$menu_num" "$metadata"
    done

    # Add Cancel option
    menu_num=$((${#COMBINED_BACKUPS[@]} + 1))
    printf "%2d) %s\n" "$menu_num" "Cancel"

    echo ""
    read -p "Select backup to restore (or Cancel to exit): " user_choice

    # Validate input
    if ! [[ "$user_choice" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid input. Please enter a number."
        exit 1
    fi

    SELECTED_INDEX=$((user_choice - 1))
    CANCEL_INDEX=$((${#COMBINED_BACKUPS[@]}))

    # Check if user selected Cancel
    if [ $user_choice -eq $((CANCEL_INDEX + 1)) ]; then
        echo ""
        echo "Restore cancelled by user."
        exit 0
    fi

    # Validate index is within range
    if [ $SELECTED_INDEX -lt 0 ] || [ $SELECTED_INDEX -ge ${#COMBINED_BACKUPS[@]} ]; then
        echo "Error: Invalid selection. Please select a number between 1 and $((CANCEL_INDEX + 1))."
        exit 1
    fi

    SELECTED_FILENAME="${COMBINED_BACKUPS[$SELECTED_INDEX]}"
    SELECTED_LOCATION="${BACKUP_LOCATIONS[$SELECTED_INDEX]}"

    # If remote backup is selected, download it first
    if [ "$SELECTED_LOCATION" == "remote" ]; then
        echo ""
        echo "Selected backup is on remote storage. Downloading..."
        BACKUP_FILE="${BACKUP_DIR}/${SELECTED_FILENAME}"

        # Double-check rclone is available
        if [ "$RCLONE_AVAILABLE" != true ]; then
            echo "Error: rclone is not available or not configured properly"
            exit 1
        fi

        REMOTE_PATH="${RCLONE_CONFIG_NAME}:${RCLONE_REMOTE_PATH}"
        if rclone copy "${REMOTE_PATH}${SELECTED_FILENAME}" "$BACKUP_DIR" --progress; then
            # Verify downloaded file exists and has size
            if [ ! -f "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
                echo "Error: Downloaded backup file is missing or empty"
                exit 1
            fi
            echo "Backup downloaded successfully"
        else
            echo "Error: Failed to download backup from remote storage"
            exit 1
        fi
    else
        BACKUP_FILE="${BACKUP_DIR}/${SELECTED_FILENAME}"
    fi
fi

echo ""
echo "Backup file: $BACKUP_FILE"
echo "Location: $SELECTED_LOCATION"

# Validate backup file integrity before restore
echo "Validating backup file integrity..."
if ! "$SEVENZIP" t "$BACKUP_FILE" > /dev/null 2>&1; then
    echo "Error: Backup file is corrupted or invalid"
    echo "File: $BACKUP_FILE"
    exit 1
fi
echo "Backup file integrity verified"
echo ""

echo "WARNING: This will OVERWRITE the OmniRoute data directory:"
echo "  $HOST_DATA_DIR"
echo "Contents (sessions, memories, skills, API keys) will be replaced by the backup."
echo "The current state will first be saved to $BACKUP_DIR/pre-restore-*.7z"
echo "Press Ctrl+C to cancel, or press Enter to continue..."
read -r

# Mark restore as in progress
RESTORE_IN_PROGRESS=true

# Stop the OmniRoute containers so they cannot write to the data dir during restore
echo ""
echo "Stopping OmniRoute containers..."
if ! systemctl --user stop omniroute.service omniroute-redis.service; then
    echo "Warning: Failed to stop OmniRoute containers"
    echo "Restore may conflict with a running container."
fi

# Create pre-restore backup of the current state
if [ -d "$HOST_DATA_DIR" ] && [ -n "$(ls -A "$HOST_DATA_DIR" 2>/dev/null)" ]; then
    PRE_RESTORE_FILE="${BACKUP_DIR}/pre-restore-${PREFIX}_$(date +%Y%m%d_%H%M%S).7z"
    echo ""
    echo "Creating pre-restore backup of current state..."
    echo "Pre-restore backup file: $PRE_RESTORE_FILE"
    if ! ( cd "$HOST_DATA_DIR" && "$SEVENZIP" a -mx=5 "$PRE_RESTORE_FILE" . "${EXCLUDES[@]}" ); then
        echo "Error: Failed to create pre-restore backup. Aborting restore."
        exit 1
    fi
    echo "Pre-restore backup created"
else
    echo ""
    echo "Data directory is empty or missing - skipping pre-restore backup."
fi

# Remove existing data dir contents
echo ""
echo "Removing existing data at $HOST_DATA_DIR..."
rm -rf "$HOST_DATA_DIR"
mkdir -p "$HOST_DATA_DIR"

# Extract backup archive into the data dir
echo ""
echo "Extracting backup archive..."
if ! "$SEVENZIP" x -y "$BACKUP_FILE" -o"$HOST_DATA_DIR"; then
    echo "Error: Failed to extract backup archive"
    if [ -n "${PRE_RESTORE_FILE:-}" ]; then
        echo "Pre-restore backup saved at: $PRE_RESTORE_FILE"
    fi
    exit 1
fi
echo "Backup extracted successfully"
echo ""

# Start the OmniRoute containers (app + redis sidecar)
echo "Starting OmniRoute containers..."
if systemctl --user start omniroute.service omniroute-redis.service; then
    echo "OmniRoute containers started successfully"
else
    echo "Warning: Failed to start OmniRoute containers"
    echo "Start manually: systemctl --user start omniroute.service omniroute-redis.service"
fi

echo ""
echo "Restore completed successfully."
echo "Data dir: $HOST_DATA_DIR"
