@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [HATA] Bu islemi yapabilmek icin yonetici olarak calistirmalisiniz.
    pause
    exit /b
)

echo Jellyfin servisi durduruluyor...
net stop JellyfinServer >nul 2>&1

set "HTML_FILE=C:\Program Files\Jellyfin\Server\jellyfin-web\index.html"

echo HTML dosyasindaki slider kodlari kaldiriliyor...
if exist "%HTML_FILE%" (
    powershell -Command "$content = Get-Content -Raw '%HTML_FILE%'; $content = $content -replace '<script[^>]*slider[^>]*></script>', ''; Set-Content -Encoding UTF8 -Path '%HTML_FILE%' -Value $content"
    echo [BASARILI] HTML slider kodlari kaldirildi!
) else (
    echo [HATA] HTML dosyasi bulunamadi: %HTML_FILE%
)

set "SLIDER_DIR=C:\Program Files\Jellyfin\Server\jellyfin-web\slider"
if exist "%SLIDER_DIR%" (
    echo Slider dosyalari siliniyor...
    rmdir /s /q "%SLIDER_DIR%"
    echo [BASARILI] Slider dosyalari silindi.
) else (
    echo [BILGI] Slider dizini bulunamadi: %SLIDER_DIR%
)

echo Jellyfin servisi baslatiliyor...
net start JellyfinServer >nul 2>&1

endlocal
echo.
echo [TAMAMLANDI] Slider kaldirma islemi basariyla tamamlandi.
pause
