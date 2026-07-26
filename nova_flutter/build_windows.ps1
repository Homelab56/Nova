# Nova Windows Build Script
# Dit script installeert dependencies en bouwt de .exe

Write-Host "Bezig met ophalen van Flutter dependencies..." -ForegroundColor Cyan
flutter pub get

Write-Host "Bezig met bouwen van Windows executable (.exe)..." -ForegroundColor Cyan
flutter build windows

if ($lastExitCode -eq 0) {
    Write-Host "`nKlaar! Je kunt de app vinden in:" -ForegroundColor Green
    Write-Host "c:\Nova\nova_flutter\build\windows\x64\runner\Release\" -ForegroundColor Yellow
    Write-Host "`nKopieer de hele map 'Release' naar waar je maar wilt en start 'nova.exe'." -ForegroundColor Cyan
} else {
    Write-Host "`nEr is iets misgegaan bij het bouwen." -ForegroundColor Red
}
