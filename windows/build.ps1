# Builds dist\ClaudeHUD.exe and dist\hud-hook.exe with the C# compiler that ships with Windows
# (.NET Framework 4.8). Nothing to install.
#   -Platform x64|x86|arm64 forces one CPU (for testing); the default AnyCPU build runs natively on all three.
param([string]$Platform = 'anycpu', [string]$Out = 'dist')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Framework64 on 64-bit Windows (x64 and ARM64), Framework on 32-bit. Output is AnyCPU: one exe that runs
# natively on x64, x86 and ARM64 (.NET Framework 4.8.1 is native on ARM64).
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
if (-not (Test-Path "$fw\csc.exe")) { $fw = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319" }
$csc = "$fw\csc.exe"
$wpf = "$fw\WPF"
if (-not (Test-Path $csc)) { throw ".NET Framework 4.x compiler not found at $csc" }
$out = Join-Path $root $Out
New-Item -ItemType Directory -Force $out | Out-Null

# App icon: a glowing capsule (the HUD's edge handle), as a PNG-compressed .ico.
$ico = Join-Path $out 'claudehud.ico'
Add-Type -AssemblyName System.Drawing
$sizes = 16, 32, 48, 256
$pngs = foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $r = New-Object System.Drawing.RectangleF ([single]($s * 0.06)), ([single]($s * 0.06)), ([single]($s * 0.88)), ([single]($s * 0.88))
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $r, ([System.Drawing.Color]::FromArgb(255, 30, 34, 44)), ([System.Drawing.Color]::FromArgb(255, 8, 9, 12)), 90
  $g.FillEllipse($bg, $r)
  $w = [single]($s * 0.16); $h = [single]($s * 0.56)
  $cap = New-Object System.Drawing.RectangleF ([single](($s - $w) / 2)), ([single](($s - $h) / 2)), $w, $h
  $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $cap, ([System.Drawing.Color]::FromArgb(255, 102, 242, 242)), ([System.Drawing.Color]::FromArgb(255, 115, 184, 255)), 90
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($cap.X, $cap.Y, $w, $w, 180, 180)
  $path.AddArc($cap.X, $cap.Bottom - $w, $w, $w, 0, 180)
  $path.CloseFigure()
  $g.FillPath($grad, $path)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  , $ms.ToArray()
}
$fs = [System.IO.File]::Create($ico)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $d = if ($s -ge 256) { 0 } else { $s }
  $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()

# A running exe can't be overwritten but can be renamed: move locked outputs aside.
foreach ($exe in "$out\hud-hook.exe", "$out\ClaudeHUD.exe") {
  if (Test-Path $exe) {
    try { Remove-Item $exe -Force -ErrorAction Stop }
    catch { Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue; Move-Item $exe "$exe.old" -Force }
  }
}

$shared = @(Get-ChildItem "$root\src\Shared\*.cs" | ForEach-Object FullName)
$hook = @(Get-ChildItem "$root\src\Hook\*.cs" | ForEach-Object FullName)
$app = @(Get-ChildItem "$root\src\App\*.cs" | ForEach-Object FullName)

& $csc /nologo /target:exe /optimize+ /platform:$Platform /warn:0 "/out:$out\hud-hook.exe" /r:System.Core.dll $shared $hook
if ($LASTEXITCODE) { throw "hud-hook.exe failed to build" }

& $csc /nologo /target:winexe /optimize+ /platform:$Platform /warn:0 "/out:$out\ClaudeHUD.exe" "/win32icon:$ico" `
  "/r:$wpf\PresentationFramework.dll" "/r:$wpf\PresentationCore.dll" "/r:$wpf\WindowsBase.dll" `
  /r:System.Xaml.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll $shared $app
if ($LASTEXITCODE) { throw "ClaudeHUD.exe failed to build" }

Write-Host "Built $out\ClaudeHUD.exe and $out\hud-hook.exe"

