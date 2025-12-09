#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
# 1. DOWNLOAD SETTINGS
# ⚠️ REPLACE THIS with the actual link to your zip file
DOWNLOAD_URL="https://temp_url/archive.zip"

# 2. JELLYFIN SETTINGS
CONTAINER="Jellyfin"
JELLYFIN_URL=""
API_KEY=""
# User ID (Taken from your logs)
USER_ID=""

# 3. PATHS
WEB_DIR="/jellyfin/jellyfin-web"
CRX_DIR="${WEB_DIR}/slider"
TMP_DIR="$(mktemp -d)"

# Date Logic for List Generation
CUTOFF=$(date -u -d "180 days ago" +"%Y-%m-%dT%H:%M:%S")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S")

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================
command -v curl >/dev/null 2>&1 || { echo "❌ Error: 'curl' is required."; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "❌ Error: 'unzip' is required."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ Error: 'jq' is required."; exit 1; }

cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "📦 Starting Complete Jellyslider Installation..."

# ==========================================
# STEP 1: Download & Extract
# ==========================================
echo "⬇️  Downloading files..."
mkdir -p "$TMP_DIR/slider"

# Download the zip
if ! curl -L -f -o "$TMP_DIR/archive.zip" "$DOWNLOAD_URL"; then
    echo "❌ Error: Failed to download archive from $DOWNLOAD_URL"
    exit 1
fi

echo "📂 Extracting..."
unzip -q "$TMP_DIR/archive.zip" -d "$TMP_DIR/slider"

# Sanity Check: If unzip created a subfolder (e.g. JellySkin-main), move contents up
SUBDIR=$(find "$TMP_DIR/slider" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -n "$SUBDIR" ] && [ ! -f "$TMP_DIR/slider/main.js" ]; then
    echo "   - Detected subfolder structure. Flattening..."
    mv "$SUBDIR"/* "$TMP_DIR/slider/"
    rmdir "$SUBDIR"
fi

# ==========================================
# STEP 2: Code Patching (Local)
# ==========================================
echo "🩹 Patching code paths..."

# 1. Fix the '/slider/' vs '/web/slider/' path issue
# We use a simple global replace which covers JS paths, CSS urls, and imports.
# We also run a second command to fix accidental double-patches (idempotency).
find "$TMP_DIR/slider" -type f \( -name '*.js' -o -name '*.css' \) | while read file; do
    sed -i 's|/slider/|/web/slider/|g' "$file"
    sed -i 's|/web/web/slider/|/web/slider/|g' "$file"
done

# 2. Fix the 'scrollTo' bug (TypeError: null is not a valid enum value)
if [ -f "$TMP_DIR/slider/main.js" ]; then
    sed -i 's|behavior: behavior|behavior: (behavior || "smooth")|g' "$TMP_DIR/slider/main.js"
    echo "   - Applied 'scrollTo' bug fix."
fi

# ==========================================
# STEP 3: Generate Movie List
# ==========================================
echo "📝 Generating movie list for User: $USER_ID"
LIST_FILE="$TMP_DIR/slider/list/list_${USER_ID}.txt"
mkdir -p "$(dirname "$LIST_FILE")"

echo "Spotlight MuteOn" > "$LIST_FILE"

curl -s "${JELLYFIN_URL}/Items?api_key=${API_KEY}&UserId=${USER_ID}&IncludeItemTypes=Movie&Recursive=true&Fields=PremiereDate" \
| jq -r --arg cutoff "$CUTOFF" --arg now "$NOW" '
  .Items 
  | map(select(.PremiereDate != null)) 
  | map(.PremiereDate |= sub("\\.\\d+Z$"; "Z")) 
  | map(select(.PremiereDate >= ($cutoff + "Z") and .PremiereDate <= ($now + "Z"))) 
  | sort_by(.PremiereDate) 
  | reverse 
  | .[:10] 
  | map(.Id) 
  | .[]
' >> "$LIST_FILE"

COUNT=$(wc -l < "$LIST_FILE")
echo "   - Generated list with $(expr $COUNT - 1) movies."

# ==========================================
# STEP 4: Install to Container
# ==========================================
echo "📤 Installing files to container..."

# 1. Remove old folder (Start fresh to avoid conflicts)
docker exec "$CONTAINER" rm -rf "$CRX_DIR"

# 2. Upload the prepared folder
# Note: We copy the *contents* of local 'slider' to remote 'jellyfin-web/' 
# resulting in 'jellyfin-web/slider'
docker cp "$TMP_DIR/slider" "$CONTAINER:$WEB_DIR/"

# 3. Fix Permissions (The 404 Fix)
echo "🔐 Enforcing 777 permissions..."
docker exec -u 0 "$CONTAINER" chmod -R 777 "$CRX_DIR"

# ==========================================
# STEP 5: Inject into index.html
# ==========================================
echo "💉 Checking index.html injection..."

docker cp "$CONTAINER:$WEB_DIR/index.html" "$TMP_DIR/index.html"

# Define the injection string (Using the correct /web/ path)
INJECTION_CODE='<script type="module" async src="/web/slider/main.js"></script><script type="module" async src="/web/slider/modules/player/main.js"></script>'

# Check if already modified
if grep -q "slider/main.js" "$TMP_DIR/index.html"; then
    echo "   - Existing injection found. Updating paths if necessary..."
    # Ensure existing injection uses /web/slider/
    sed -i 's|src="/slider/|src="/web/slider/|g' "$TMP_DIR/index.html"
else
    echo "   - First time installation. Injecting scripts..."
    # Backup
    docker exec "$CONTAINER" cp "$WEB_DIR/index.html" "$WEB_DIR/bak/index.html" 2>/dev/null || true
    # Inject before </body>
    sed -i "s|</body>|${INJECTION_CODE}\n</body>|g" "$TMP_DIR/index.html"
fi

# Upload modified index
docker cp "$TMP_DIR/index.html" "$CONTAINER:$WEB_DIR/index.html"

# ==========================================
# FINISH
# ==========================================
echo ""
echo "🎉 Installation Complete!"
echo "📋 Summary:"
echo "  - Files Location: $CRX_DIR"
echo "  - List Generated: list_${USER_ID}.txt"
echo "  - Code Patched: Yes (/web/slider/)"
echo ""
echo "⚠️  IMPORTANT: You MUST clear your browser cache (Ctrl+F5) to see the changes."
