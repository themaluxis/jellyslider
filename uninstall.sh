#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
HTML_FILE="$JELLYFIN_WEB/index.html"
SLIDER_DIR="$JELLYFIN_WEB/slider"

SLIDER_SCRIPTS=(
    '<script type="module" async src="/web/slider/main.js"></script>'
    '<script type="module" async src="/web/slider/modules/player/main.js"></script>'
)

if [ "$(id -u)" -ne 0 ]; then
    echo "Bu script root olarak çalıştırılmalıdır."
    exit 1
fi

echo "Jellyfin servisi durduruluyor..."
systemctl stop jellyfin

echo "HTML dosyasındaki slider kodları kaldırılıyor..."
REMOVED_ANY=false
for script in "${SLIDER_SCRIPTS[@]}"; do
    if grep -qF "$script" "$HTML_FILE"; then
        sed -i "s|$script||g" "$HTML_FILE"
        echo "Script kaldırıldı: $script"
        REMOVED_ANY=true
    fi
done

if [ "$REMOVED_ANY" = false ]; then
    echo "HTML dosyasında slider kodları bulunamadı."
else
    echo "HTML slider kodları başarıyla kaldırıldı!"
fi

echo "Slider dosyaları siliniyor..."
if [ -d "$SLIDER_DIR" ]; then
    rm -rf "$SLIDER_DIR"
    echo "Slider dosyaları başarıyla silindi: $SLIDER_DIR"
else
    echo "Slider dizini bulunamadı: $SLIDER_DIR"
fi

echo "Jellyfin servisi başlatılıyor..."
systemctl start jellyfin

echo "Slider kaldırma işlemi tamamlandı!"
