#!/usr/bin/env bash
#
# setup-yt-dlp-queue.sh — One-time setup for the yt-dlp auto-download queue
#
# What this does:
#   1. Makes scripts executable
#   2. Creates the data/ directory, queue file, subscriptions file, and download directory
#   3. Adds a cron job to run every 6 hours
#   4. Adds shell functions dlq, dlsub, and dlq-now to ~/.bashrc
#
# All project files stay in this folder. Nothing is copied elsewhere.
#
# Expected folder structure:
#   <project>/
#   ├── downloads.queue
#   ├── subscriptions.txt
#   ├── scripts/        ← you are here
#   │   ├── setup-yt-dlp-queue.sh
#   │   ├── yt-dlp-queue.sh
#   │   ├── yt-dlp-json2nfo.py
#   │   └── yt-dlp-queue.conf
#   └── data/
#       ├── .yt-dlp-archive
#       └── yt-dlp-queue.log
#
# Usage: bash scripts/setup-yt-dlp-queue.sh
#    or: cd scripts && bash setup-yt-dlp-queue.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source config
if [[ -f "$SCRIPT_DIR/yt-dlp-queue.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/yt-dlp-queue.conf"
fi

# Defaults if conf didn't set them
QUEUE_FILE="${QUEUE_FILE:-$PROJECT_DIR/downloads.queue}"
SUBSCRIPTIONS_FILE="${SUBSCRIPTIONS_FILE:-$PROJECT_DIR/subscriptions.txt}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Videos}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"

echo "╔══════════════════════════════════════════════╗"
echo "║     yt-dlp Auto-Download Queue — Setup       ║"
echo "╚══════════════════════════════════════════════╝"
echo
echo "  Project folder: $PROJECT_DIR"
echo "  Scripts folder: $SCRIPT_DIR"
echo

# ──────────────────────────── Step 1: Check dependencies ───────────────

echo "▶ Checking dependencies..."

missing=()
if ! command -v yt-dlp &>/dev/null; then
    missing+=("yt-dlp")
fi
if ! command -v python3 &>/dev/null; then
    missing+=("python3")
fi
if ! command -v crontab &>/dev/null; then
    missing+=("cron")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "  ✗ Missing: ${missing[*]}"
    echo "  Install them first, e.g.:"
    echo "    sudo apt install ${missing[*]}"
    exit 1
fi
echo "  ✓ All dependencies found"

# ──────────────────────────── Step 2: Make scripts executable ──────────

echo
echo "▶ Making scripts executable..."

chmod +x "$SCRIPT_DIR/yt-dlp-queue.sh"
echo "  ✓ yt-dlp-queue.sh"

chmod +x "$SCRIPT_DIR/yt-dlp-json2nfo.py"
echo "  ✓ yt-dlp-json2nfo.py"

# ──────────────────────────── Step 3: Create directories and files ─────

echo
echo "▶ Setting up directories..."

mkdir -p "$PROJECT_DIR/data"
echo "  ✓ $PROJECT_DIR/data/"

mkdir -p "$DOWNLOAD_DIR"
echo "  ✓ $DOWNLOAD_DIR"

echo
echo "▶ Setting up queue file..."

if [[ ! -f "$QUEUE_FILE" ]]; then
    cat > "$QUEUE_FILE" << 'QEOF'
# yt-dlp download queue
# Paste URLs below, one per line. They will be downloaded and removed automatically.
# Lines starting with # are comments and will be preserved.
#
QEOF
    echo "  ✓ Created $QUEUE_FILE"
else
    echo "  ✓ Queue file already exists at $QUEUE_FILE"
fi

echo
echo "▶ Setting up subscriptions file..."

if [[ ! -f "$SUBSCRIPTIONS_FILE" ]]; then
    cat > "$SUBSCRIPTIONS_FILE" << 'SEOF'
# yt-dlp subscriptions
# Paste channel or playlist URLs below, one per line.
# These are checked every run — new videos are downloaded automatically.
# This file is NEVER cleared. Remove a line to unsubscribe.
#
SEOF
    echo "  ✓ Created $SUBSCRIPTIONS_FILE"
else
    echo "  ✓ Subscriptions file already exists at $SUBSCRIPTIONS_FILE"
fi

# ──────────────────────────── Step 4: Set up cron job ──────────────────

echo
echo "▶ Setting up cron job..."

CRON_CMD="$CRON_SCHEDULE PATH=\"/usr/local/bin:/usr/bin:/bin\" \"$SCRIPT_DIR/yt-dlp-queue.sh\""
CRON_MARKER="# yt-dlp-queue auto-download"

CURRENT_CRONTAB=$(crontab -l 2>/dev/null || echo "")

if echo "$CURRENT_CRONTAB" | grep -qF "yt-dlp-queue.sh"; then
    echo "  ⚠ Cron job already exists — replacing with updated path"
    CURRENT_CRONTAB=$(echo "$CURRENT_CRONTAB" | grep -vF "yt-dlp-queue.sh")
fi

(echo "$CURRENT_CRONTAB"; echo "$CRON_CMD $CRON_MARKER") | crontab -
echo "  ✓ Cron job set: schedule $CRON_SCHEDULE"

# ──────────────────────────── Step 5: Shell functions ──────────────────

echo
echo "▶ Setting up shell functions..."

# Detect shell RC file
SHELL_RC=""
if [[ -f "$HOME/.bashrc" ]]; then
    SHELL_RC="$HOME/.bashrc"
elif [[ -f "$HOME/.zshrc" ]]; then
    SHELL_RC="$HOME/.zshrc"
fi

if [[ -n "$SHELL_RC" ]]; then
    # Remove old version if present
    if grep -qF "# yt-dlp-queue-functions-start" "$SHELL_RC"; then
        sed -i '/# yt-dlp-queue-functions-start/,/# yt-dlp-queue-functions-end/d' "$SHELL_RC"
        echo "  ✓ Removed old shell functions"
    elif grep -qF "# yt-dlp-queue-functions" "$SHELL_RC"; then
        # Handle legacy marker from earlier versions
        sed -i '/# yt-dlp-queue-functions/,/^}$/d' "$SHELL_RC"
        echo "  ✓ Removed old shell functions (legacy)"
    fi

    # Write new functions with the current project paths baked in
    cat >> "$SHELL_RC" << FUNCEOF

# yt-dlp-queue-functions-start (do not remove this marker line)
dlq() {
    local queue_file="$QUEUE_FILE"
    if [[ \$# -eq 0 ]]; then
        echo "Usage: dlq <url> [url2] [url3] ..."
        echo "Queue file: \$queue_file"
        echo "Current queue:"
        grep -E "^[[:space:]]*[^#[:space:]]" "\$queue_file" 2>/dev/null || echo "  (empty)"
        return 0
    fi
    for url in "\$@"; do
        echo "\$url" >> "\$queue_file"
        echo "✓ Queued: \$url"
    done
}

dlsub() {
    local subs_file="$SUBSCRIPTIONS_FILE"
    if [[ \$# -eq 0 ]]; then
        echo "Usage: dlsub <channel_or_playlist_url> [url2] ..."
        echo "Subscriptions file: \$subs_file"
        echo "Current subscriptions:"
        grep -E "^[[:space:]]*[^#[:space:]]" "\$subs_file" 2>/dev/null || echo "  (none)"
        return 0
    fi
    for url in "\$@"; do
        if grep -qF "\$url" "\$subs_file" 2>/dev/null; then
            echo "⚠ Already subscribed: \$url"
        else
            echo "\$url" >> "\$subs_file"
            echo "✓ Subscribed: \$url"
        fi
    done
}

dlq-now() {
    echo "Running yt-dlp queue download now..."
    "$SCRIPT_DIR/yt-dlp-queue.sh"
}
# yt-dlp-queue-functions-end
FUNCEOF
    echo "  ✓ Added dlq, dlsub, and dlq-now functions to $SHELL_RC"
else
    echo "  ⚠ Could not detect .bashrc or .zshrc."
    echo "    You'll need to add the shell functions manually."
fi

# ──────────────────────────── Done ─────────────────────────────────────

echo
echo "╔══════════════════════════════════════════════╗"
echo "║              Setup complete!                 ║"
echo "╚══════════════════════════════════════════════╝"
echo
echo "IMPORTANT: Load the new shell functions now by running:"
echo
echo "    source $SHELL_RC"
echo
echo "How to use:"
echo
echo "  1. Add URLs to the queue (downloaded once, then removed):"
echo "     dlq 'https://www.youtube.com/watch?v=XXXXX'"
echo "     (or edit $QUEUE_FILE directly)"
echo
echo "  2. Subscribe to channels/playlists (checked every run):"
echo "     dlsub 'https://www.youtube.com/@ChannelName'"
echo "     (or edit $SUBSCRIPTIONS_FILE directly)"
echo
echo "  3. Downloads run automatically every 6 hours via cron."
echo "     To run immediately:  dlq-now"
echo
echo "  4. Check the log:"
echo "     cat $PROJECT_DIR/data/yt-dlp-queue.log"
echo
echo "  5. Change paths (download dir, queue file, etc.):"
echo "     Edit $SCRIPT_DIR/yt-dlp-queue.conf"
echo
echo "  6. Firefox cookies are used automatically when needed"
echo "     (e.g. age-restricted or members-only videos)."
echo
echo "  7. Videos download to: $DOWNLOAD_DIR"
echo "     Each video gets its own folder with: .mp4 + .nfo"
echo "     Metadata (.info.json, .description) goes to: $DOWNLOAD_DIR/metadata/"
echo
