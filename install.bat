@echo off
NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Bu script yonetici olarak calistirilmalidir.
    pause
    exit /b 1
)

set "JELLYFIN_WEB=C:\Program Files\Jellyfin\Server\jellyfin-web"
set "HTML_FILE=%JELLYFIN_WEB%\index.html"
set "SLIDER_DIR=%JELLYFIN_WEB%\slider"
set "SOURCE_DIR=%~dp0"

set "INSERT_HTML=<script type=\"module\" async src=\"/web/slider/main.js\"></script><script type=\"module\" async src=\"/web/slider/modules/player/main.js\"></script>"

echo Slider klasoru olusturuluyor: %SLIDER_DIR%
mkdir "%SLIDER_DIR%" >nul 2>&1

if not exist "%SLIDER_DIR%" (
    echo HATA: Klasor olusturulamadi: %SLIDER_DIR%
    pause
    exit /b 1
)

echo Dosyalar kopyalaniyor...
xcopy "%SOURCE_DIR%\*" "%SLIDER_DIR%\" /E /Y /Q >nul
if %ERRORLEVEL% NEQ 0 (
    echo HATA: Dosyalar kopyalanirken bir sorun olustu!
    pause
    exit /b 1
)
echo Dosyalar basariyla kopyalandi.

echo HTML dosyasi guncelleniyor...
if exist "%HTML_FILE%" (
    powershell -Command "$content = Get-Content -Raw '%HTML_FILE%'; $content = $content -replace '<script[^>]*slider[^>]*></script>', ''; $content = $content -replace '</body>', '%INSERT_HTML%</body>'; Set-Content -Encoding UTF8 -Path '%HTML_FILE%' -Value $content"
    
    echo HTML basariyla guncellendi.
) else (
    echo HATA: HTML dosyasi bulunamadi: %HTML_FILE%
    pause
    exit /b 1
)

echo Kurulum tamamlandi!
pause
