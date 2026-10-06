# Removes Claude HUD: the app, its hooks (your other hooks and status line are kept), shortcuts and settings.
$ErrorActionPreference = 'Continue'
Set-Location $env:TEMP
$dest = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeHUD'
$hud = Join-Path $env:USERPROFILE '.claude\hud'

Get-Process ClaudeHUD -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($h in (Join-Path $hud 'hud-hook.exe'), (Join-Path $dest 'hud-hook.exe')) {
  if (Test-Path $h) { & $h uninstall; break }
}
Start-Sleep -Milliseconds 300
Remove-Item -Recurse -Force $hud -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude HUD.lnk') -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'ClaudeHUD') -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name ClaudeHUD -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeHUD' -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
Write-Host 'Claude HUD removed.' -ForegroundColor Green
