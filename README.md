# Stahovák

Malá macOS appka (SwiftUI, macOS 14+): vložíš odkaz z YouTube, X, Instagramu, Facebooku nebo Threads a ona ho stáhne.

Pořadí pokusů: yt-dlp (H.264 MP4 nebo MP3), pak gallery-dl (IG fotky, karusely), pak u Threads přímé vytažení videa z HTML.

## Instalace

    brew install yt-dlp ffmpeg gallery-dl
    ./build.sh
    open Stahovak.app

Soubory jdou do ~/Downloads/Stahovak (měnitelné dole v okně). Odkaz jde i přetáhnout do okna; při spuštění se sám vloží ze schránky, pokud je z podporovaného webu.

Instagram a Facebook často chtějí přihlášení: vyber v appce "Cookies z …" podle prohlížeče, kde jsi přihlášený. Safari vyžaduje pro appku Full Disk Access (Nastavení systému, Soukromí a zabezpečení).

Když něco přestane fungovat, většinou stačí tlačítko "Aktualizovat yt-dlp a gallery-dl".
