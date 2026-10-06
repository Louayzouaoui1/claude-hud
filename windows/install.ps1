# Installs Claude HUD for the current user. Safe to re-run (it updates in place).
#   1. builds dist\ if needed (uses the C# compiler built into Windows, nothing to download)
#   2. copies the app to %LOCALAPPDATA%\Programs\ClaudeHUD
#   3. wires the hooks + status line into ~/.claude/settings.json (backup: settings.json.bak-claudehud)
#   4. adds a Start menu shortcut and an entry in Settings > Apps (for uninstalling)
#   5. starts it (it also starts at sign-in; turn that off in its Settings)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeHUD'

function Step($t) { Write-Host "  - $t" -ForegroundColor Cyan }
Write-Host "Installing Claude HUD" -ForegroundColor White

$built = Join-Path $root 'dist\ClaudeHUD.exe'
$newest = Get-ChildItem "$root\src" -Recurse -Filter *.cs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not (Test-Path $built) -or (Get-Item $built).LastWriteTime -lt $newest.LastWriteTime) {
  Step 'Building'
  & (Join-Path $root 'build.ps1') | Out-Null
}

Step 'Copying the app'
Get-Process ClaudeHUD -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($f in 'ClaudeHUD.exe', 'hud-hook.exe', 'claudehud.ico') { Copy-Item (Join-Path $root "dist\$f") $dest -Force }
Copy-Item (Join-Path $root 'uninstall.ps1') $dest -Force

Step 'Connecting to Claude Code'
& (Join-Path $dest 'hud-hook.exe') install
if ($LASTEXITCODE) { throw 'Could not wire the hooks into ~/.claude/settings.json (see the message above).' }

Step 'Adding to the Start menu and Settings > Apps'
$exe = Join-Path $dest 'ClaudeHUD.exe'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude HUD.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $dest
$lnk.Description = 'Heads-up display for your Claude Code sessions'
$lnk.Save()
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeHUD'
New-Item -Force $key | Out-Null
$props = @{
  DisplayName = 'Claude HUD'; DisplayIcon = $exe; DisplayVersion = (Get-Date -Format 'yyyy.M.d'); Publisher = 'Claude HUD contributors'
  InstallLocation = $dest; NoModify = 1; NoRepair = 1
  UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dest\uninstall.ps1`""
}
foreach ($k in $props.Keys) { New-ItemProperty -Path $key -Name $k -Value $props[$k] -Force | Out-Null }

Step 'Starting'
Start-Process $exe

Write-Host ''
Write-Host 'Claude HUD is installed and running.' -ForegroundColor Green
Write-Host '  Hover the right edge of your screen, or press Ctrl+Alt+Space.'
Write-Host '  Restart any Claude Code sessions that were already open so they report to the HUD.'
