#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
# Update these to match your setup
CONTAINER="Jellyfin"

# Paths
# We use 'slider' as the directory name because main.js hardcodes paths like '/slider/src/...'
CRX_DIR="/jellyfin/jellyfin-web/slider"
WEB_DIR="/jellyfin/jellyfin-web"
TMP_DIR="$(mktemp -d)"

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
# STEP 1: Prepare Local Files
# ==========================================
echo "📂 Preparing local files..."
mkdir -p "$TMP_DIR/slider"

# Copy jellyslider files to temp dir
# We copy everything from current dir except the temp dir itself and hidden files
cp main.js auth.js "$TMP_DIR/slider/"
cp -r modules src language list "$TMP_DIR/slider/" 2>/dev/null || true

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
# This ensures we always start from a clean state (idempotency)
if grep -q "slider/main.js" "$TMP_DIR/index.html" || grep -q "jellyfin-crx" "$TMP_DIR/index.html"; then
    echo "   ℹ️  Existing modification detected. Restoring from backup..."
    docker exec "$CONTAINER" bash -c "cp $WEB_DIR/bak/index.html $WEB_DIR/index.html"
    # Download the restored file
    docker cp "$CONTAINER:$WEB_DIR/index.html" "$TMP_DIR/index.html"
else
    echo "   ℹ️  First time installation. Creating backup..."
    docker exec "$CONTAINER" bash -c "cp $WEB_DIR/index.html $WEB_DIR/bak/index.html"
fi

# 3. Prepare the injection code
# We use /web/slider/ path.
INJECTION_CODE='<script type="module" async src="/web/slider/main.js"></script><script type="module" async src="/web/slider/modules/player/main.js"></script>'

# 4. Inject before </body>
# We replace </body> with INJECTION_CODE</body>
# We append a newline to ensure we don't accidentally delete the </body> tag if we were to grep -v later,
# although restoring from backup makes that less of an issue.
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
echo "  - Files: $CRX_DIR"
echo "  - Backup: $WEB_DIR/bak/index.html"
echo ""
echo "⚠️  Note: You MUST clear your browser cache (Ctrl+F5) to see changes."
echo "💡 Tip: Restart Jellyfin container if changes don't appear: docker restart $CONTAINER"
