#!/usr/bin/env python3
"""
Convert yt-dlp .info.json files to Jellyfin-compatible Kodi-style .nfo files.

Usage:
    yt-dlp-json2nfo.py <info.json>                                Convert a single file (NFO next to it)
    yt-dlp-json2nfo.py --dir <directory>                          Convert all in directory (NFO next to each)
    yt-dlp-json2nfo.py --scan <directory>                         Recursively find .info.json and write NFO next to each
    yt-dlp-json2nfo.py --metadata-dir <meta> --video-dir <vids>   Read from meta/, write NFO into video folders
"""

import json
import sys
import os
import xml.etree.ElementTree as ET
from xml.dom import minidom
from datetime import datetime


def parse_upload_date(date_str):
    """Convert yt-dlp date format (YYYYMMDD) to Jellyfin format (YYYY-MM-DD)."""
    if not date_str or len(date_str) != 8:
        return ""
    try:
        dt = datetime.strptime(date_str, "%Y%m%d")
        return dt.strftime("%Y-%m-%d")
    except ValueError:
        return ""


def is_playlist_metadata(info):
    """Check if an .info.json file is playlist-level metadata (not a video)."""
    return info.get("_type") == "playlist"


def build_nfo_xml(info):
    """Build NFO XML content from yt-dlp info dict."""
    movie = ET.Element("movie")

    title = ET.SubElement(movie, "title")
    title.text = info.get("title", "Unknown Title")

    plot = ET.SubElement(movie, "plot")
    plot.text = info.get("description", "")

    premiered_str = parse_upload_date(info.get("upload_date", ""))
    if premiered_str:
        premiered = ET.SubElement(movie, "premiered")
        premiered.text = premiered_str
        year = ET.SubElement(movie, "year")
        year.text = premiered_str[:4]

    uploader = info.get("uploader") or info.get("channel") or ""
    if uploader:
        studio = ET.SubElement(movie, "studio")
        studio.text = uploader
        director = ET.SubElement(movie, "director")
        director.text = uploader

    duration = info.get("duration")
    if duration:
        runtime = ET.SubElement(movie, "runtime")
        runtime.text = str(int(duration) // 60)

    video_id = info.get("id", "")
    extractor = info.get("extractor_key", info.get("extractor", "")).lower()
    if video_id:
        uniqueid = ET.SubElement(movie, "uniqueid")
        uniqueid.set("type", extractor or "unknown")
        uniqueid.set("default", "true")
        uniqueid.text = video_id

    for tag in info.get("tags", []) or []:
        tag_el = ET.SubElement(movie, "tag")
        tag_el.text = str(tag)

    for cat in info.get("categories", []) or []:
        genre = ET.SubElement(movie, "genre")
        genre.text = str(cat)

    webpage_url = info.get("webpage_url", "")
    if webpage_url:
        comment = ET.SubElement(movie, "comment")
        comment.text = webpage_url

    average_rating = info.get("average_rating")
    if average_rating:
        rating_el = ET.SubElement(movie, "rating")
        rating_el.text = str(average_rating)

    # Pretty-print XML
    rough_string = ET.tostring(movie, encoding="unicode")
    parsed = minidom.parseString(rough_string)
    pretty = parsed.toprettyxml(indent="  ", encoding=None)

    lines = pretty.split("\n")
    lines = [l for l in lines if not l.startswith("<?xml")]
    xml_content = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    xml_content += "\n".join(lines).strip() + "\n"

    return xml_content


def write_nfo(nfo_path, info):
    """Write NFO XML to a file."""
    xml_content = build_nfo_xml(info)
    with open(nfo_path, "w", encoding="utf-8") as f:
        f.write(xml_content)
    return nfo_path


def json_to_nfo(json_path):
    """Convert a single .info.json file to a .nfo file next to it."""
    with open(json_path, "r", encoding="utf-8") as f:
        info = json.load(f)

    base = json_path
    if base.endswith(".info.json"):
        base = base[: -len(".info.json")]
    else:
        base = os.path.splitext(base)[0]

    nfo_path = base + ".nfo"
    return write_nfo(nfo_path, info)


def process_directory(directory):
    """Convert all .info.json files in a directory (NFO written next to each)."""
    count = 0
    for filename in os.listdir(directory):
        if not filename.endswith(".info.json"):
            continue
        json_path = os.path.join(directory, filename)
        base = json_path[: -len(".info.json")]
        nfo_path = base + ".nfo"
        if os.path.exists(nfo_path):
            continue
        try:
            result = json_to_nfo(json_path)
            print(f"Created: {result}")
            count += 1
        except Exception as e:
            print(f"Error processing {json_path}: {e}", file=sys.stderr)
    return count


def scan_directory(directory):
    """
    Recursively walk a directory tree, find .info.json files, and write
    .nfo files next to each one. Skips playlist-level metadata and files
    that already have a corresponding .nfo.
    """
    count = 0
    for dirpath, _dirnames, filenames in os.walk(directory):
        for filename in filenames:
            if not filename.endswith(".info.json"):
                continue

            json_path = os.path.join(dirpath, filename)
            base = json_path[: -len(".info.json")]
            nfo_path = base + ".nfo"

            # Skip if NFO already exists
            if os.path.exists(nfo_path):
                continue

            try:
                with open(json_path, "r", encoding="utf-8") as f:
                    info = json.load(f)
            except Exception as e:
                print(f"Error reading {json_path}: {e}", file=sys.stderr)
                continue

            # Skip playlist-level metadata
            if is_playlist_metadata(info):
                continue

            try:
                write_nfo(nfo_path, info)
                print(f"Created: {nfo_path}")
                count += 1
            except Exception as e:
                print(f"Error processing {json_path}: {e}", file=sys.stderr)

    return count


def find_video_folder(video_dir, title):
    """
    Find the video folder for a given title.

    Checks both flat layout and channel-subfolder layout:
        video_dir/<title>/
        video_dir/<channel>/<title>/
    """
    # Direct match (queue downloads)
    direct = os.path.join(video_dir, title)
    if os.path.isdir(direct):
        return direct

    # Channel subfolder match (subscription downloads)
    try:
        for entry in os.listdir(video_dir):
            candidate = os.path.join(video_dir, entry, title)
            if os.path.isdir(candidate):
                return candidate
    except OSError:
        pass

    return None


def process_metadata_to_video_dirs(metadata_dir, video_dir):
    """
    Read .info.json files from metadata_dir.
    Write .nfo files into matching per-video folders in video_dir.

    Supports both flat and channel-subfolder layouts:
        video_dir/<title>/<title>.nfo
        video_dir/<channel>/<title>/<title>.nfo

    Skips playlist-level metadata files (they don't correspond to videos).
    """
    count = 0
    for filename in os.listdir(metadata_dir):
        if not filename.endswith(".info.json"):
            continue

        json_path = os.path.join(metadata_dir, filename)

        # Derive the video title (base name without .info.json)
        title = filename[: -len(".info.json")]

        # Load the JSON to check if it's playlist metadata
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                info = json.load(f)
        except Exception as e:
            print(f"Error reading {json_path}: {e}", file=sys.stderr)
            continue

        # Skip playlist-level metadata (no corresponding video folder)
        if is_playlist_metadata(info):
            continue

        # Find the video folder (flat or inside a channel subfolder)
        video_folder = find_video_folder(video_dir, title)
        if video_folder is None:
            continue

        nfo_path = os.path.join(video_folder, title + ".nfo")

        # Skip if NFO already exists
        if os.path.exists(nfo_path):
            continue

        try:
            write_nfo(nfo_path, info)
            print(f"Created: {nfo_path}")
            count += 1
        except Exception as e:
            print(f"Error processing {json_path}: {e}", file=sys.stderr)

    return count


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    if sys.argv[1] == "--metadata-dir":
        if len(sys.argv) < 5 or sys.argv[3] != "--video-dir":
            print("Usage: yt-dlp-json2nfo.py --metadata-dir <meta> --video-dir <vids>")
            sys.exit(1)
        metadata_dir = sys.argv[2]
        video_dir = sys.argv[4]
        count = process_metadata_to_video_dirs(metadata_dir, video_dir)
        print(f"Generated {count} new .nfo file(s)")
    elif sys.argv[1] == "--scan":
        if len(sys.argv) < 3:
            print("Usage: yt-dlp-json2nfo.py --scan <directory>")
            sys.exit(1)
        directory = sys.argv[2]
        count = scan_directory(directory)
        print(f"Generated {count} new .nfo file(s) (scan)")
    elif sys.argv[1] == "--dir":
        if len(sys.argv) < 3:
            print("Usage: yt-dlp-json2nfo.py --dir <directory>")
            sys.exit(1)
        directory = sys.argv[2]
        count = process_directory(directory)
        print(f"Generated {count} new .nfo file(s)")
    else:
        for path in sys.argv[1:]:
            try:
                result = json_to_nfo(path)
                print(f"Created: {result}")
            except Exception as e:
                print(f"Error processing {path}: {e}", file=sys.stderr)
                sys.exit(1)


if __name__ == "__main__":
    main()
