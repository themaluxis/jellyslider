#!/bin/bash
JELLYFIN_WEB="/usr/share/jellyfin/web"
SLIDER_DIR="$JELLYFIN_WEB/slider"
SOURCE_DIR="$(dirname "$(realpath "$0")")"

if [ "$(id -u)" -ne 0 ]; then
    echo "HATA: Bu script root olarak çalıştırılmalıdır."
    exit 1
fi

ERRORS=0
[ ! -d "$JELLYFIN_WEB" ] && echo "HATA: Jellyfin web dizini bulunamadı: $JELLYFIN_WEB" >&2 && ERRORS=1
[ ! -d "$SOURCE_DIR" ] && echo "HATA: Kaynak dizin bulunamadı: $SOURCE_DIR" >&2 && ERRORS=1

if [ $ERRORS -ne 0 ]; then
    exit 1
fi

echo "Slider güncelleme başlatılıyor..."
if ! mkdir -p "$SLIDER_DIR"; then
    echo "HATA: Slider dizini oluşturulamadı: $SLIDER_DIR" >&2
    exit 1
fi

if ! cp -r "$SOURCE_DIR"/* "$SLIDER_DIR"/ 2>/dev/null; then
    echo "HATA: Dosyalar kopyalanırken bir sorun oluştu!" >&2
    echo "NOT: Kaynak dizin olmayabilir veya izin sorunu olabilir: $SOURCE_DIR" >&2
    exit 1
fi
echo "Dosyalar başarıyla kopyalandı: $SLIDER_DIR"


echo "Güncelleme başarıyla tamamlandı!"
