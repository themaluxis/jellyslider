#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
HTML_FILE="$JELLYFIN_WEB/index.html"
SLIDER_DIR="$JELLYFIN_WEB/slider"
SOURCE_DIR="$(dirname "$(realpath "$0")")"

INSERT_HTML='<script type="module" async src="/web/jellyslider/main.js"></script><script type="module" async src="/web/jellyslider/modules/player/main.js"></script>'

echo "Creating slider folder: $SLIDER_DIR"
if mkdir -p "$SLIDER_DIR"; then
    if [ -d "$SLIDER_DIR" ]; then
        echo "Folder created successfully, copying files..."
        if cp -r "$SOURCE_DIR"/* "$SLIDER_DIR"/ 2>/dev/null; then
            echo "Files copied successfully: $SLIDER_DIR"
        else
            echo "ERROR: There was a problem copying the files!" >&2
            exit 1
        fi
    else
        echo "ERROR: Could not create folder: $SLIDER_DIR" >&2
        exit 1
    fi
else
    echo "ERROR: Could not create folder: $SLIDER_DIR" >&2
    exit 1
fi

if ! grep -q "jellyslider/main.js" "$HTML_FILE" || ! grep -q "jellyslider/modules/player/main.js" "$HTML_FILE"; then
    sed -i '/jellyslider\/main.js/d' "$HTML_FILE"
    sed -i '/jellyslider\/modules\/player\/main.js/d' "$HTML_FILE"
    sed -i "s|</body>|__TEMP_BODY__|g" "$HTML_FILE"
    sed -i "s|__TEMP_BODY__|${INSERT_HTML}</body>|g" "$HTML_FILE"
    echo "HTML snippets added successfully!"
else
    echo "HTML snippets already exist. Skipping..."
fi

echo "Installation complete!"
