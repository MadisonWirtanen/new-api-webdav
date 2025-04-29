#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
DB_FILE_PATH="/data/one-api.db" # Absolute path to the database file
BACKUP_PREFIX="oneapi_backup_" # Prefix for backup files
TMP_DIR="/tmp" # Directory for temporary files
CHECKSUM_FILE="${TMP_DIR}/oneapi_last_checksum" # File to store checksum of last backed up db

# --- WebDAV Sync Logic ---

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2
}

# Check if WebDAV is enabled via environment variables
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    log "WEBDAV_URL, WEBDAV_USERNAME, or WEBDAV_PASSWORD not set. Backup/restore functionality disabled."
    WEBDAV_ENABLED=false
else
    log "WebDAV environment variables detected. Enabling backup/restore functionality."
    WEBDAV_ENABLED=true

    # Sanitize and construct WebDAV URL
    WEBDAV_URL=$(echo "$WEBDAV_URL" | sed 's:/*$::') # Remove trailing slashes from base URL
    WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-"oneapi_backups"} # Default backup sub-directory
    WEBDAV_BACKUP_PATH=$(echo "$WEBDAV_BACKUP_PATH" | sed 's:^/*::' | sed 's:/*$::') # Remove surrounding slashes from path

    if [ -n "$WEBDAV_BACKUP_PATH" ]; then
        FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
        # Check and create backup directory on WebDAV server
        log "Checking/Creating WebDAV backup directory: ${WEBDAV_BACKUP_PATH}"
        python3 -c "
import os, sys
from webdav3.client import Client
options = {
    'webdav_hostname': '$WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD',
    'verify_ssl': os.environ.get('WEBDAV_VERIFY_SSL', 'true').lower() == 'true' # Control SSL verification
}
backup_dir = '$WEBDAV_BACKUP_PATH'
try:
    client = Client(options)
    if not client.is_dir(backup_dir):
        print(f'Directory {backup_dir} does not exist. Attempting to create...')
        client.mkdir(backup_dir)
        print(f'Successfully created directory {backup_dir}')
    else:
        print(f'Directory {backup_dir} already exists.')
except Exception as e:
    print(f'Error interacting with WebDAV directory {backup_dir}: {e}', file=sys.stderr)
    # Decide if this error is critical; maybe just log and continue?
" || log_error "Failed to ensure WebDAV backup directory exists. Check connection and permissions."
    else
        FULL_WEBDAV_URL="${WEBDAV_URL}"
        log "Using root WebDAV URL for backups: ${FULL_WEBDAV_URL}"
    fi
    log "Full WebDAV backup URL: ${FULL_WEBDAV_URL}"

    # --- Restore Function ---
    restore_backup() {
        log "Attempting to restore latest backup from WebDAV..."
        local latest_backup_file
        local local_tmp_path
        local temp_extract_dir="${TMP_DIR}/oneapi_restore_temp"

        # Use Python to find the latest backup and download it
        restore_script_output=$(python3 -c "
import sys, os, tarfile, requests, shutil
from webdav3.client import Client
from urllib.parse import urljoin

options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD',
    'verify_ssl': os.environ.get('WEBDAV_VERIFY_SSL', 'true').lower() == 'true'
}
target_db_path = '$DB_FILE_PATH'
backup_prefix = '$BACKUP_PREFIX'
tmp_dir = '$TMP_DIR'
temp_extract_dir = '$temp_extract_dir'

try:
    client = Client(options)
    files_info = client.list(get_info=True)
    backups = sorted([
        info['name'] for info in files_info
        if info['name'].endswith('.tar.gz') and info['name'].startswith(backup_prefix)
    ])

    if not backups:
        print('INFO: No backups found matching prefix {backup_prefix}*.tar.gz in {options['webdav_hostname']}. Skipping restore.', file=sys.stderr)
        sys.exit(0)

    latest_backup = backups[-1]
    remote_backup_path = latest_backup # Relative path from client's perspective
    # Construct full URL for requests, handling potential double slashes carefully
    backup_file_url = urljoin(options['webdav_hostname'].strip('/') + '/', remote_backup_path.strip('/'))
    local_tmp_path = os.path.join(tmp_dir, os.path.basename(latest_backup))

    print(f'INFO: Found latest backup: {latest_backup}. Downloading from {backup_file_url}...', file=sys.stderr)
    with requests.get(backup_file_url, auth=(options['webdav_login'], options['webdav_password']), stream=True, verify=options['verify_ssl']) as r:
        r.raise_for_status()
        with open(local_tmp_path, 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
    print(f'INFO: Successfully downloaded backup to {local_tmp_path}', file=sys.stderr)

    if os.path.exists(local_tmp_path):
        if os.path.exists(temp_extract_dir): shutil.rmtree(temp_extract_dir)
        os.makedirs(temp_extract_dir, exist_ok=True)

        print(f'INFO: Extracting {local_tmp_path} to {temp_extract_dir}...', file=sys.stderr)
        try:
            with tarfile.open(local_tmp_path, 'r:gz') as tar:
                # Basic check for safe paths (relative, within extract dir)
                for member in tar.getmembers():
                    if member.name.startswith('/') or '..' in member.name:
                        raise ValueError(f'Unsafe path found in tar: {member.name}')
                tar.extractall(path=temp_extract_dir)

            # Find 'one-api.db' within the extracted files
            found_db_path = None
            db_filename = os.path.basename(target_db_path) # Should be 'one-api.db'
            for root, dirs, files in os.walk(temp_extract_dir):
                if db_filename in files:
                    found_db_path = os.path.join(root, db_filename)
                    print(f'INFO: Found {db_filename} at {found_db_path}', file=sys.stderr)
                    break

            if found_db_path:
                print(f'INFO: Restoring {found_db_path} to {target_db_path}...', file=sys.stderr)
                os.makedirs(os.path.dirname(target_db_path), exist_ok=True)
                os.replace(found_db_path, target_db_path) # Atomic replace if possible
                print(f'INFO: Successfully restored database from {latest_backup}.', file=sys.stderr)
                # Output the path for bash script confirmation
                print(f'{local_tmp_path}')
            else:
                print(f'ERROR: Could not find {db_filename} in the extracted backup {latest_backup}.', file=sys.stderr)

        except (tarfile.TarError, ValueError, Exception) as e:
            print(f'ERROR: Failed to extract or process backup file {local_tmp_path}: {e}', file=sys.stderr)
        finally:
            if os.path.exists(temp_extract_dir): shutil.rmtree(temp_extract_dir)
            if os.path.exists(local_tmp_path) and found_db_path is None: # Clean up tmp if restore failed finding db
                 os.remove(local_tmp_path)
            elif found_db_path is None: # No file downloaded or other error
                 pass # Keep the tmp file path empty if download failed
    else:
        print(f'ERROR: Downloaded backup file {local_tmp_path} does not exist.', file=sys.stderr)

except requests.exceptions.RequestException as e:
    print(f'ERROR: WebDAV request failed during restore: {e}', file=sys.stderr)
except Exception as e:
    print(f'ERROR: Unexpected error during restore preparation: {e}', file=sys.stderr)

" 2>&1) # Capture stdout and stderr

        # Check if Python script outputted a path (indicating download success)
        local_tmp_path=$(echo "$restore_script_output" | grep "^${TMP_DIR}/" | tail -n 1)
        # Log Python script's stderr messages
        echo "$restore_script_output" | grep -v "^${TMP_DIR}/" | while IFS= read -r line; do log "$line"; done

        # Clean up the downloaded tar.gz file if it exists
        if [[ -n "$local_tmp_path" && -f "$local_tmp_path" ]]; then
            rm -f "$local_tmp_path"
            log "Cleaned up temporary downloaded file: $local_tmp_path"
        fi
        # Always remove the temp extraction dir if it exists
        if [ -d "$temp_extract_dir" ]; then
             rm -rf "$temp_extract_dir"
             log "Cleaned up temporary extraction directory: $temp_extract_dir"
        fi
    }

    # --- Sync Function (runs in background) ---
    sync_data() {
        local initial_delay=${INITIAL_SYNC_DELAY:-30} # Delay before first sync check (seconds)
        log "Sync process starting. Initial check delay: ${initial_delay}s."
        sleep "$initial_delay"

        while true; do
            local sync_interval=${SYNC_INTERVAL:-600} # Interval between sync checks (seconds)
            log "Starting periodic sync check..."

            if [ ! -f "$DB_FILE_PATH" ]; then
                log "Database file $DB_FILE_PATH not found. Skipping backup cycle."
            else
                # Calculate checksum (use md5sum or sha256sum)
                local current_checksum
                if command -v md5sum >/dev/null; then
                    current_checksum=$(md5sum "$DB_FILE_PATH" | awk '{ print $1 }')
                elif command -v sha256sum >/dev/null; then
                     current_checksum=$(sha256sum "$DB_FILE_PATH" | awk '{ print $1 }')
                else
                    log_error "Neither md5sum nor sha256sum found. Cannot perform checksum comparison. Backing up unconditionally."
                    current_checksum="" # Force backup
                fi

                local last_checksum=""
                if [ -f "$CHECKSUM_FILE" ]; then
                    last_checksum=$(cat "$CHECKSUM_FILE")
                fi

                if [ "$current_checksum" != "$last_checksum" ] || [ -z "$last_checksum" ] ; then # Backup if changed or first time
                    if [ "$current_checksum" != "$last_checksum" ]; then
                         log "Database file $DB_FILE_PATH has changed (Checksum: ${current_checksum:0:8}...). Proceeding with backup."
                    else
                         log "No previous checksum found. Proceeding with initial backup."
                    fi

                    local timestamp=$(date +%Y%m%d_%H%M%S)
                    local backup_file="${BACKUP_PREFIX}${timestamp}.tar.gz"
                    local local_tmp_backup_path="${TMP_DIR}/${backup_file}"

                    log "Creating backup archive: $local_tmp_backup_path"
                    # Tar options: -C changes directory before adding files
                    if tar -czf "$local_tmp_backup_path" -C "$(dirname "$DB_FILE_PATH")" "$(basename "$DB_FILE_PATH")"; then
                        log "Backup archive created successfully."
                        local upload_url="${FULL_WEBDAV_URL}/${backup_file}"
                        log "Uploading ${backup_file} to ${FULL_WEBDAV_URL} ..."

                        # Use curl for upload, handle SSL verification via env var
                        local curl_opts=("-u" "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "-T" "$local_tmp_backup_path")
                        if [[ "${WEBDAV_VERIFY_SSL:-true}" != "true" ]]; then
                             curl_opts+=("-k") # Add insecure flag if verification is disabled
                             log "Warning: WEBDAV_VERIFY_SSL is not 'true'. Disabling SSL verification for upload."
                        fi

                        if curl "${curl_opts[@]}" "$upload_url"; then
                            log "Successfully uploaded ${backup_file} to WebDAV."
                            # Update checksum file on successful upload
                            echo "$current_checksum" > "$CHECKSUM_FILE"

                            # --- Cleanup Old Backups ---
                            local keep_latest=${WEBDAV_KEEP_LATEST:-5} # Number of backups to keep
                            log "Cleaning up old backups on WebDAV, keeping latest ${keep_latest}..."
                            cleanup_output=$(python3 -c "
import sys, os
from webdav3.client import Client
options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD',
    'verify_ssl': os.environ.get('WEBDAV_VERIFY_SSL', 'true').lower() == 'true'
}
keep_latest = int('$keep_latest')
backup_prefix = '$BACKUP_PREFIX'
try:
    client = Client(options)
    files_info = client.list(get_info=True)
    backups = sorted([
        info['name'] for info in files_info
        if info['name'].endswith('.tar.gz') and info['name'].startswith(backup_prefix)
    ])

    if len(backups) > keep_latest:
        to_delete_count = len(backups) - keep_latest
        print(f'Found {len(backups)} backups. Deleting {to_delete_count} oldest backups...', file=sys.stderr)
        deleted_count = 0
        for file_rel_path in backups[:to_delete_count]:
            try:
                print(f'Deleting {file_rel_path}...', file=sys.stderr)
                client.clean(file_rel_path) # clean likely takes relative path
                deleted_count += 1
            except Exception as e:
                print(f'Failed to delete {file_rel_path}: {e}', file=sys.stderr)
        print(f'Successfully deleted {deleted_count} old backups.', file=sys.stderr)
    else:
        print(f'Found {len(backups)} backups. No cleanup needed (keeping {keep_latest}).', file=sys.stderr)
except Exception as e:
    print(f'Error during WebDAV cleanup: {e}', file=sys.stderr)
" 2>&1) # Capture stdout and stderr
                            # Log Python cleanup script's stderr messages
                            echo "$cleanup_output" | while IFS= read -r line; do log "$line"; done

                        else
                            log_error "Failed to upload ${backup_file} to WebDAV (curl exit code: $?)."
                        fi

                        # Clean up local temporary backup file regardless of upload status? Yes.
                        rm -f "$local_tmp_backup_path"
                        log "Cleaned up local temporary backup file: $local_tmp_backup_path"

                    else
                        log_error "Failed to create backup archive $local_tmp_backup_path."
                    fi
                else
                    log "Database file $DB_FILE_PATH unchanged (Checksum: ${current_checksum:0:8}...). Skipping backup."
                fi
            fi

            log "Sync check finished. Next check in ${sync_interval} seconds."
            sleep "$sync_interval"
        done
    }

    # --- Initial Restore (Optional) ---
    if [[ "${RECOVERY_ON_START:-false}" == "true" ]]; then
        log "RECOVERY_ON_START is true. Attempting initial restore..."
        restore_backup
    else
        log "RECOVERY_ON_START is not 'true'. Skipping initial restore."
    fi

    # --- Start Background Sync Process ---
    log "Starting background sync process..."
    sync_data &
    SYNC_PID=$!
    log "Background sync process started with PID: $SYNC_PID"

    # Trap TERM and INT signals to gracefully shut down background process if possible
    trap 'log "Received termination signal. Killing sync process $SYNC_PID..."; kill $SYNC_PID; wait $SYNC_PID 2>/dev/null; log "Sync process terminated."; exit 0' TERM INT

fi # End of WEBDAV_ENABLED check

# --- Start Main Application ---
log "Starting one-api application..."
# Use exec to replace the shell process with the main application
# Pass any arguments received by this script to the main application
exec /one-api "$@"

# Fallback exit if exec fails for some reason
exit $?