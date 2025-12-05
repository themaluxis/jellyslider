#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
HTML_FILE="$JELLYFIN_WEB/index.html"
SLIDER_DIR="$JELLYFIN_WEB/slider"

SLIDER_SCRIPTS=(
    '<script type="module" async src="/web/slider/main.js"></script>'
    '<script type="module" async src="/web/slider/modules/player/main.js"></script>'
)

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "Stopping Jellyfin service..."
systemctl stop jellyfin

echo "Removing slider codes from HTML file..."
REMOVED_ANY=false
for script in "${SLIDER_SCRIPTS[@]}"; do
    if grep -qF "$script" "$HTML_FILE"; then
        sed -i "s|$script||g" "$HTML_FILE"
        echo "Script removed: $script"
        REMOVED_ANY=true
    fi
done

if [ "$REMOVED_ANY" = false ]; then
    echo "Slider codes not found in HTML file."
else
    echo "HTML slider codes successfully removed!"
fi

echo "Deleting slider files..."
if [ -d "$SLIDER_DIR" ]; then
    rm -rf "$SLIDER_DIR"
    echo "Slider files successfully deleted: $SLIDER_DIR"
else
    echo "Slider directory not found: $SLIDER_DIR"
fi

echo "Starting Jellyfin service..."
systemctl start jellyfin

echo "Slider uninstallation completed!"
