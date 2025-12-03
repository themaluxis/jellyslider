#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
HTML_FILE="$JELLYFIN_WEB/index.html"
SLIDER_DIR="$JELLYFIN_WEB/slider"
SOURCE_DIR="$(dirname "$(realpath "$0")")"

INSERT_HTML='<script type="module" async src="/web/slider/main.js"></script><script type="module" async src="/web/slider/modules/player/main.js"></script>'

if [ "$(id -u)" -ne 0 ]; then
    echo "Bu script root olarak çalıştırılmalıdır."
    exit 1
fi

echo "Slider klasörü oluşturuluyor: $SLIDER_DIR"
if mkdir -p "$SLIDER_DIR"; then
    if [ -d "$SLIDER_DIR" ]; then
        echo "Klasör başarıyla oluşturuldu, dosyalar kopyalanıyor..."
        if cp -r "$SOURCE_DIR"/* "$SLIDER_DIR"/ 2>/dev/null; then
            echo "Dosyalar başarıyla kopyalandı: $SLIDER_DIR"
        else
            echo "HATA: Dosyalar kopyalanırken bir sorun oluştu!" >&2
            exit 1
        fi
    else
        echo "HATA: Klasör oluşturulamadı: $SLIDER_DIR" >&2
        exit 1
    fi
else
    echo "HATA: Klasör oluşturulamadı: $SLIDER_DIR" >&2
    exit 1
fi

if ! grep -q "slider/main.js" "$HTML_FILE" || ! grep -q "slider/modules/player/main.js" "$HTML_FILE"; then
    sed -i '/slider\/main.js/d' "$HTML_FILE"
    sed -i '/slider\/modules\/player\/main.js/d' "$HTML_FILE"
    sed -i "s|</body>|__TEMP_BODY__|g" "$HTML_FILE"
    sed -i "s|__TEMP_BODY__|${INSERT_HTML}</body>|g" "$HTML_FILE"
    echo "HTML snippet'leri başarıyla eklendi!"
else
    echo "HTML snippet'leri zaten mevcut. Atlanıyor..."
fi

echo "Kurulum tamamlandı!"
