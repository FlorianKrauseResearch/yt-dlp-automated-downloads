# yt-dlp Auto-Download Queue

A hands-off video download system built around [yt-dlp](https://github.com/yt-dlp/yt-dlp). Paste links into a file, and a cron job takes care of the rest — including automatic cookie retry for age-restricted content and Jellyfin-compatible metadata generation.

## Features

- **Queue file** — paste URLs, they get downloaded and cleared automatically
- **Subscriptions** — add channel/playlist URLs that are checked every run for new uploads
- **Automatic cookie retry** — downloads are first attempted without cookies; if yt-dlp hits an auth wall (age gate, login required, members-only), it retries with browser cookies automatically
- **Jellyfin integration** — generates Kodi-style `.nfo` files from yt-dlp metadata so Jellyfin picks up titles, descriptions, upload dates, and more
- **Duplicate prevention** — uses yt-dlp's `--download-archive` to never download the same video twice
- **Cron-based** — runs every 6 hours with no manual intervention; exits instantly if there's nothing to do
- **Portable** — everything lives in one project folder; run the setup script on any Linux machine and you're good to go

## Project Structure

```
Yt-dlp automation/
├── downloads.queue          ← paste one-off URLs here (cleared after download)
├── subscriptions.txt        ← channel/playlist URLs (checked every run, never cleared)
├── README.md
├── scripts/
│   ├── setup-yt-dlp-queue.sh    setup script (run once per machine)
│   ├── yt-dlp-queue.sh          main downloader (called by cron)
│   ├── yt-dlp-json2nfo.py       .info.json → .nfo converter
│   └── yt-dlp-queue.conf        configuration (paths, browser, etc.)
└── data/
    ├── .yt-dlp-archive          tracks downloaded video IDs
    └── yt-dlp-queue.log         log file
```

Downloaded videos are organized as:

```
~/Videos/
├── metadata/                    .info.json and .description files
│   ├── Video Title.info.json
│   └── Video Title.description
├── Video Title/                 one folder per video
│   ├── Video Title.mp4
│   └── Video Title.nfo
└── Another Video/
    ├── Another Video.mp4
    └── Another Video.nfo
```

## Requirements

- **Linux** (tested on Linux Mint; should work on any Debian/Ubuntu-based distro)
- **yt-dlp**
- **python3**
- **cron**
- **ffmpeg** (used by yt-dlp for merging video and audio streams)

Install on Debian/Ubuntu/Mint:

```bash
sudo apt install python3 cron ffmpeg
```

For yt-dlp, install via pip for the latest version:

```bash
pip install --break-system-packages yt-dlp
```

Or via your package manager:

```bash
sudo apt install yt-dlp
```

## Installation

1. Clone or copy this folder to wherever you like, e.g. `~/Software/Yt-dlp automation/`
2. Run the setup script:

```bash
cd "/path/to/Yt-dlp automation"
bash scripts/setup-yt-dlp-queue.sh
source ~/.bashrc
```

The setup script will:
- Make the scripts executable
- Create the `data/` directory, `downloads.queue`, and `subscriptions.txt`
- Create the download directory (`~/Videos` by default)
- Add a cron job that runs every 6 hours
- Add `dlq`, `dlsub`, and `dlq-now` shell functions to your `.bashrc`

## Usage

### Queue a video for download

```bash
dlq 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
```

You can queue multiple at once:

```bash
dlq 'https://url1' 'https://url2' 'https://url3'
```

Or just open `downloads.queue` in any text editor and paste URLs (one per line).

Queued URLs are downloaded on the next cron run and then removed from the file. Failed URLs stay in the queue for retry.

### Subscribe to a channel or playlist

```bash
dlsub 'https://www.youtube.com/@SomeChannel'
```

Or edit `subscriptions.txt` directly. Subscription URLs are checked every run and never removed — the download archive ensures only new videos are fetched. To unsubscribe, simply delete the line.

### Run immediately

```bash
dlq-now
```

### Check status

```bash
dlq          # shows current queue
dlsub        # shows current subscriptions
cat data/yt-dlp-queue.log   # view the log
```

## Configuration

All settings are in `scripts/yt-dlp-queue.conf`:

| Setting | Default | Description |
|---------|---------|-------------|
| `QUEUE_FILE` | `$PROJECT_DIR/downloads.queue` | Path to the queue file |
| `SUBSCRIPTIONS_FILE` | `$PROJECT_DIR/subscriptions.txt` | Path to the subscriptions file |
| `DOWNLOAD_DIR` | `$HOME/Videos` | Where videos are saved |
| `ARCHIVE_FILE` | `$PROJECT_DIR/data/.yt-dlp-archive` | Tracks downloaded videos |
| `LOG_FILE` | `$PROJECT_DIR/data/yt-dlp-queue.log` | Log file location |
| `COOKIE_BROWSER` | `firefox` | Browser to pull cookies from when needed |

After editing the config, re-run `bash scripts/setup-yt-dlp-queue.sh` and `source ~/.bashrc` to update the shell functions and cron job.

## Jellyfin Integration

Each downloaded video gets a `.nfo` file in its folder containing the title, description, upload date, channel name, duration, tags, and source URL. Jellyfin reads these automatically when you add the download directory as a library.

The raw `.info.json` and `.description` files from yt-dlp are kept separately in the `metadata/` subdirectory in case you need them for other purposes.

## How the Cookie Retry Works

1. Every URL is first downloaded **without cookies**
2. If yt-dlp's output contains auth-related errors (age gate, login required, 403, members-only, etc.), the download is retried **with cookies** from the configured browser
3. This means cookies are only used when actually needed, keeping things simple for public content

The browser must have an active session (i.e. you must be logged in to YouTube in Firefox) for cookie-based downloads to work.

## Cron Schedule

The default schedule is every 6 hours (`0 */6 * * *`). To change it:

```bash
crontab -e
```

Find the line containing `yt-dlp-queue.sh` and adjust the schedule. The script exits instantly when there's nothing to download, so running it frequently is cheap.

## Troubleshooting

**`dlq: command not found`**
Run `source ~/.bashrc` or open a new terminal.

**Downloads aren't running automatically**
Check that cron is running: `systemctl status cron`. Check the cron entry exists: `crontab -l`.

**yt-dlp not found (in cron)**
The script sets its own PATH, but if yt-dlp is installed somewhere unusual, add its location to the PATH line at the top of `scripts/yt-dlp-queue.sh`.

**Cookie retry not working**
Make sure the configured browser (`COOKIE_BROWSER` in the config) is installed and you're logged in to the relevant site. The browser must not be running a private/incognito session.

**Log file growing too large**
The script automatically rotates the log when it exceeds 1 MB, keeping one `.old` backup.
