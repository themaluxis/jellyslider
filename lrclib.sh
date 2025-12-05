#!/bin/bash
# GMMP
# LRC Lib Şarkı Sözü İndirici (Synced/Plain Öncelikli)
# Gerekli bağımlılıklar: curl, jq, find

MUSIC_DIR="${1%/}"
OVERWRITE=false

if [ -z "$MUSIC_DIR" ]; then
    echo "Usage: $0 /path/to/music/folder [--overwrite]"
    echo "Example: $0 ~/Music"
    echo "Example (overwrite): $0 ~/Music --overwrite"
    exit 1
fi

if [ "$2" == "--overwrite" ]; then
    OVERWRITE=true
    echo "WARNING: Existing LRC files will be overwritten!"
fi

if [ ! -d "$MUSIC_DIR" ]; then
    echo "Error: Specified folder not found: $MUSIC_DIR"
    exit 1
fi

API_URL="https://lrclib.net/api/search"

TOTAL=0
SUCCESS_SYNCED=0
SUCCESS_PLAIN=0
FAILED=0
SKIPPED=0

echo "Downloading lyrics: $MUSIC_DIR"
echo "Overwrite mode: $OVERWRITE"
echo "----------------------------------------"

while IFS= read -r -d '' file; do
    ((TOTAL++))

    lrc_file="${file%.*}.lrc"

    if [ -f "$lrc_file" ] && [ "$OVERWRITE" = false ]; then
        echo -e "\nFile: $file"
        echo "Skipped: LRC file already exists (overwrite off)"
        ((SKIPPED++))
        continue
    fi

    filename=$(basename "$file")
    filename="${filename%.*}"

    echo -e "\nFile: $file"

    artist=$(echo "$filename" | awk -F " - " '{print $1}' | sed -e 's/\[.*\]//g' -e 's/(.*)//g' | xargs)
    title=$(echo "$filename" | awk -F " - " '{print $2}' | sed -e 's/\[.*\]//g' -e 's/(.*)//g' | xargs)

    if [ -z "$title" ]; then
        artist=$(echo "$filename" | awk -F "--" '{print $1}' | xargs)
        title=$(echo "$filename" | awk -F "--" '{print $2}' | xargs)
    fi

    if [ -z "$title" ]; then
        artist=$(echo "$filename" | awk -F "_" '{print $1}' | xargs)
        title=$(echo "$filename" | awk -F "_" '{print $2}' | xargs)
    fi

    if [ -z "$artist" ] || [ -z "$title" ]; then
        echo "Warning: Filename format not valid: '$filename'"
        ((FAILED++))
        continue
    fi

    echo "Searching: '$artist' - '$title'"

    response=$(curl -s -G "$API_URL" \
        --data-urlencode "artist_name=$artist" \
        --data-urlencode "track_name=$title")

    if [ $? -ne 0 ]; then
        echo "Error: API request failed"
        ((FAILED++))
        continue
    fi

    lrc_content=$(echo "$response" | jq -r '.[0]?.syncedLyrics')
    lrc_type="synced"

    if [ -z "$lrc_content" ] || [ "$lrc_content" = "null" ]; then
        lrc_content=$(echo "$response" | jq -r '.[0]?.plainLyrics')
        lrc_type="plain"

        if [ -z "$lrc_content" ] || [ "$lrc_content" = "null" ]; then
            echo "Warning: No lyrics found (neither synced nor plain)"
            ((FAILED++))
            continue
        fi
    fi

    echo "$lrc_content" > "$lrc_file"

    if [ $? -eq 0 ]; then
        if [ "$lrc_type" = "synced" ]; then
            echo "Success: $lrc_file created (SYNCED lyrics)"
            ((SUCCESS_SYNCED++))
        else
            echo "Success: $lrc_file created (PLAIN lyrics)"
            ((SUCCESS_PLAIN++))
        fi
    else
        echo "Error: $lrc_file could not be created/updated"
        ((FAILED++))
    fi

done < <(find "$MUSIC_DIR" -type f \( -iname "*.mp3" -o -iname "*.flac" \) -print0)

echo -e "\n----------------------------------------"
echo "Process completed"
echo "Total songs: $TOTAL"
echo "Success (Synced): $SUCCESS_SYNCED"
echo "Success (Plain): $SUCCESS_PLAIN"
echo "Skipped: $SKIPPED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
    echo -e "\nNote: For failed items:"
    echo "1. Try organizing filenames as 'Artist - Song'"
    echo "2. Try overwriting existing LRCs with --overwrite parameter"
    echo "3. You can manually search lyrics via lrclib.net"
fi
