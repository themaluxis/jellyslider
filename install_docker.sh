#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
# Update these to match your setup
CONTAINER="Jellyfin"
DOWNLOAD_URL="https://github.com/themaluxis/jellyslider/releases/download/latest/jellyslider.zip"

# Paths
# We use 'slider' as the directory name because main.js hardcodes paths like '/slider/src/...'
CRX_DIR="/jellyfin/jellyfin-web/slider"
WEB_DIR="/jellyfin/jellyfin-web"
TMP_DIR="$(mktemp -d)"

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================
command -v curl >/dev/null 2>&1 || { echo "❌ Error: 'curl' is required but not installed."; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "❌ Error: 'unzip' is required but not installed."; exit 1; }

# ==========================================
# FUNCTIONS
# ==========================================

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "📦 Starting Jellyslider installation..."

# ==========================================
# STEP 1: Download & Extract
# ==========================================
echo "⬇️  Downloading Jellyslider archive..."
mkdir -p "$TMP_DIR/slider"

# Download the archive
if ! curl -L -f -o "$TMP_DIR/archive.zip" "$DOWNLOAD_URL"; then
    echo "❌ Error: Failed to download archive from $DOWNLOAD_URL"
    exit 1
fi

echo "📂 Extracting files..."
# Unzip contents directly into the slider directory
unzip -q "$TMP_DIR/archive.zip" -d "$TMP_DIR/slider"

# Sanity Check: Ensure the zip actually contained the expected structure
if [ ! -d "$TMP_DIR/slider/modules" ]; then
    echo "⚠️  Warning: 'modules' folder not found after extraction. The zip structure might be incorrect."
fi

# ==========================================
# STEP 2: Prepare Container Directories
# ==========================================
echo "📁 Preparing remote directories..."

docker exec "$CONTAINER" bash -c "
  # Remove existing directory if any
  rm -rf $CRX_DIR

  # Create Backup dir
  mkdir -p $WEB_DIR/bak
"

# ==========================================
# STEP 3: Upload Files to Container
# ==========================================
echo "📤 Uploading jellyslider files..."
# We copy the folder 'slider' into 'jellyfin-web' so it becomes 'jellyfin-web/slider'
docker cp "$TMP_DIR/slider" "$CONTAINER:$WEB_DIR/"

# ==========================================
# STEP 4: Modify index.html
# ==========================================
echo "📝 Modifying index.html..."

# 1. Download current index.html
docker cp "$CONTAINER:$WEB_DIR/index.html" "$TMP_DIR/index.html"

# 2. Check if already modified and restore from backup if needed
if grep -q "slider/main.js" "$TMP_DIR/index.html" || grep -q "jellyfin-crx" "$TMP_DIR/index.html"; then
    echo "   ℹ️  Existing modification detected. Restoring from backup..."
    
    # Try to copy backup to live
    if docker exec "$CONTAINER" bash -c "[ -f $WEB_DIR/bak/index.html ]"; then
        docker exec "$CONTAINER" bash -c "cp $WEB_DIR/bak/index.html $WEB_DIR/index.html"
    else
        echo "   ⚠️  Backup not found inside container! Skipping restore."
    fi
    
    # Download the clean/restored file
    docker cp "$CONTAINER:$WEB_DIR/index.html" "$TMP_DIR/index.html"
else
    echo "   ℹ️  First time installation. Creating backup..."
    docker exec "$CONTAINER" bash -c "cp $WEB_DIR/index.html $WEB_DIR/bak/index.html"
fi

# 3. Prepare the injection code
# Note: Ensure main.js exists in the zip root, otherwise update this path.
INJECTION_CODE='<script type="module" async src="/web/slider/main.js"></script><script type="module" async src="/web/slider/modules/player/main.js"></script>'

# 4. Inject before </body>
sed -i "s|</body>|${INJECTION_CODE}\n</body>|g" "$TMP_DIR/index.html"

# 5. Upload modified index.html
echo "📤 Uploading modified index.html..."
docker cp "$TMP_DIR/index.html" "$CONTAINER:$WEB_DIR/index.html"

# ==========================================
# FINISH
# ==========================================
echo ""
echo "🎉 Installation complete!"
echo ""
echo "📋 Summary:"
echo "  - Source: $DOWNLOAD_URL"
echo "  - Destination: $CRX_DIR"
echo "  - Backup: $WEB_DIR/bak/index.html"
echo ""
echo "⚠️  Note: You MUST clear your browser cache (Ctrl+F5) to see changes."
echo "💡 Tip: Restart Jellyfin container if changes don't appear: docker restart $CONTAINER"
