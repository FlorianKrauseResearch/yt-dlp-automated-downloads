#!/usr/bin/env bash
#
# yt-dlp-queue.sh — Process a queue of URLs and subscriptions with yt-dlp
#
# This script:
#   1. Downloads one-off URLs from the queue file (cleared after success)
#   2. Downloads new videos from subscriptions file (channels/playlists, never cleared)
#   3. If a download fails due to auth/cookie issues, retries with browser cookies
#   4. Generates Jellyfin-compatible .nfo files from .info.json metadata
#
# Designed to be run via cron. Uses a lockfile to prevent overlapping runs.

set -euo pipefail

# ──────────────────────────── PATH (for cron) ──────────────────────────
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ──────────────────────────── Directory layout ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ──────────────────────────── Configuration ────────────────────────────
if [[ -f "$SCRIPT_DIR/yt-dlp-queue.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/yt-dlp-queue.conf"
fi

# Defaults (used if conf file doesn't set them)
QUEUE_FILE="${QUEUE_FILE:-$PROJECT_DIR/downloads.queue}"
SUBSCRIPTIONS_FILE="${SUBSCRIPTIONS_FILE:-$PROJECT_DIR/subscriptions.txt}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Videos}"
ARCHIVE_FILE="${ARCHIVE_FILE:-$PROJECT_DIR/data/.yt-dlp-archive}"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/data/yt-dlp-queue.log}"
COOKIE_BROWSER="${COOKIE_BROWSER:-firefox}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-1048576}"

LOCK_FILE="/tmp/yt-dlp-queue.lock"
JSON2NFO_SCRIPT="$SCRIPT_DIR/yt-dlp-json2nfo.py"

# Patterns in yt-dlp output that indicate cookies/auth are needed
COOKIE_ERROR_PATTERNS=(
    "Sign in to confirm your age"
    "sign in to confirm your age"
    "This video requires authentication"
    "Login required"
    "login required"
    "cookies"
    "Sign in to confirm you"
    "Private video"
    "members-only"
    "Join this channel"
    "This video is available to this channel"
    "HTTP Error 403"
)

# ──────────────────────────── Functions ─────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log "Log rotated"
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}

needs_cookies() {
    local output="$1"
    for pattern in "${COOKIE_ERROR_PATTERNS[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            return 0
        fi
    done
    return 1
}

download_url() {
    local url="$1"
    local mode="${2:-queue}"  # "queue" or "subscription"

    # Output template: subscriptions go into channel-specific folders
    local output_template
    if [[ "$mode" == "subscription" ]]; then
        output_template="$DOWNLOAD_DIR/%(channel)s/%(title)s/%(title)s.%(ext)s"
    else
        output_template="$DOWNLOAD_DIR/%(title)s/%(title)s.%(ext)s"
    fi

    # Common yt-dlp arguments
    local common_args=(
        --download-archive "$ARCHIVE_FILE"
        -f 'bestvideo+bestaudio/best'
        --merge-output-format mp4
        --write-info-json
        --write-description
        -o "$output_template"
        -o "infojson:$DOWNLOAD_DIR/metadata/%(title)s.%(ext)s"
        -o "description:$DOWNLOAD_DIR/metadata/%(title)s.%(ext)s"
        -o "pl_infojson:$DOWNLOAD_DIR/metadata/%(playlist_title)s.%(ext)s"
        -o "pl_description:$DOWNLOAD_DIR/metadata/%(playlist_title)s.%(ext)s"
        --no-overwrites
        --trim-filenames 200
    )

    # First attempt: without cookies
    log "  Downloading: $url"
    local output
    output=$(yt-dlp "${common_args[@]}" "$url" 2>&1) || true
    echo "$output" >> "$LOG_FILE"

    # Check for success indicators
    if echo "$output" | grep -qE '(has already been recorded|Merging formats|Already downloaded|\[download\] 100%)'; then
        log "  ✓ Success"
        return 0
    fi

    # Check if it failed due to auth/cookie issues — retry with cookies
    if needs_cookies "$output"; then
        log "  ⟳ Auth/cookie error detected. Retrying with $COOKIE_BROWSER cookies..."
        local retry_output
        retry_output=$(yt-dlp "${common_args[@]}" --cookies-from-browser "$COOKIE_BROWSER" "$url" 2>&1) || true
        echo "$retry_output" >> "$LOG_FILE"

        if echo "$retry_output" | grep -qE '(has already been recorded|Merging formats|Already downloaded|\[download\] 100%)'; then
            log "  ✓ Success (with cookies)"
            return 0
        else
            log "  ✗ Failed even with cookies"
            return 1
        fi
    fi

    # Some other failure (network, removed video, etc.)
    if echo "$output" | grep -qiE 'ERROR'; then
        log "  ✗ Failed: non-auth error"
        return 1
    fi

    # If we can't tell, assume success (e.g. already in archive with different wording)
    log "  ✓ Done"
    return 0
}

# ──────────────────────────── Preflight checks ─────────────────────────

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$ARCHIVE_FILE")"
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR/metadata"

# Rotate log if needed
rotate_log

# Check for yt-dlp
if ! command -v yt-dlp &>/dev/null; then
    log "ERROR: yt-dlp not found in PATH ($PATH)"
    exit 1
fi

# Create queue file if it doesn't exist
if [[ ! -f "$QUEUE_FILE" ]]; then
    touch "$QUEUE_FILE"
    log "Created queue file: $QUEUE_FILE"
fi

# Create subscriptions file if it doesn't exist
if [[ ! -f "$SUBSCRIPTIONS_FILE" ]]; then
    touch "$SUBSCRIPTIONS_FILE"
fi

# Check if there's anything to do (queue OR subscriptions)
HAS_QUEUE=false
HAS_SUBS=false
grep -qE '^[[:space:]]*[^#[:space:]]' "$QUEUE_FILE" 2>/dev/null && HAS_QUEUE=true
grep -qE '^[[:space:]]*[^#[:space:]]' "$SUBSCRIPTIONS_FILE" 2>/dev/null && HAS_SUBS=true

if [[ "$HAS_QUEUE" == "false" && "$HAS_SUBS" == "false" ]]; then
    exit 0  # Nothing to do, exit silently
fi

# Lockfile: prevent overlapping runs
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "Another instance is running (PID $LOCK_PID). Exiting."
        exit 0
    else
        log "Stale lockfile found. Removing."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

# ──────────────────────────── Start ────────────────────────────────────

log "Starting download run."

# ──────────────────────────── Process queue ─────────────────────────────

SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_URLS=()

if [[ "$HAS_QUEUE" == "true" ]]; then
    log "Processing queue: $QUEUE_FILE"

    mapfile -t URLS < <(grep -E '^[[:space:]]*[^#[:space:]]' "$QUEUE_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log "Found ${#URLS[@]} URL(s) in queue"

    for url in "${URLS[@]}"; do
        if download_url "$url"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_URLS+=("$url")
        fi
    done
fi

# ──────────────────────────── Process subscriptions ────────────────────

SUB_COUNT=0

if [[ "$HAS_SUBS" == "true" ]]; then
    log "Processing subscriptions: $SUBSCRIPTIONS_FILE"

    mapfile -t SUBS < <(grep -E '^[[:space:]]*[^#[:space:]]' "$SUBSCRIPTIONS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log "Found ${#SUBS[@]} subscription(s)"

    for url in "${SUBS[@]}"; do
        if download_url "$url" "subscription"; then
            SUB_COUNT=$((SUB_COUNT + 1))
        else
            log "  ⚠ Subscription error (will retry next run): $url"
        fi
    done
fi

log "Results: queue $SUCCESS_COUNT ok / $FAIL_COUNT failed, subscriptions $SUB_COUNT processed"

# ──────────────────────────── Generate NFO files ───────────────────────

if [[ -f "$JSON2NFO_SCRIPT" ]]; then
    log "Generating .nfo files from .info.json metadata..."
    python3 "$JSON2NFO_SCRIPT" --metadata-dir "$DOWNLOAD_DIR/metadata" --video-dir "$DOWNLOAD_DIR" >> "$LOG_FILE" 2>&1 || \
        log "WARNING: NFO generation had errors"
else
    log "WARNING: NFO generator not found at $JSON2NFO_SCRIPT — skipping"
fi

# ──────────────────────────── Update the queue ─────────────────────────

# Rebuild queue: keep comments + any URLs that failed (for retry next run)
{
    grep -E '^[[:space:]]*#' "$QUEUE_FILE" 2>/dev/null || true
    for url in "${FAILED_URLS[@]}"; do
        echo "$url"
    done
} > "$QUEUE_FILE.tmp"
mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    log "$FAIL_COUNT failed URL(s) kept in queue for next run"
fi

log "Download run complete."
log "────────────────────────────────────────"
