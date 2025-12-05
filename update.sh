#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
SLIDER_DIR="$JELLYFIN_WEB/slider"
SOURCE_DIR="$(dirname "$(realpath "$0")")"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

ERRORS=0
[ ! -d "$JELLYFIN_WEB" ] && echo "ERROR: Jellyfin web directory not found: $JELLYFIN_WEB" >&2 && ERRORS=1
[ ! -d "$SOURCE_DIR" ] && echo "ERROR: Source directory not found: $SOURCE_DIR" >&2 && ERRORS=1

if [ $ERRORS -ne 0 ]; then
    exit 1
fi

echo "Starting slider update..."
if ! mkdir -p "$SLIDER_DIR"; then
    echo "ERROR: Could not create slider directory: $SLIDER_DIR" >&2
    exit 1
fi

if ! cp -r "$SOURCE_DIR"/* "$SLIDER_DIR"/ 2>/dev/null; then
    echo "ERROR: An error occurred while copying files!" >&2
    echo "NOTE: Source directory might be missing or permission issue: $SOURCE_DIR" >&2
    exit 1
fi
echo "Files copied successfully: $SLIDER_DIR"


echo "Update completed successfully!"
