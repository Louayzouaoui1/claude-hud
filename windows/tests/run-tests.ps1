# End-to-end tests for Claude HUD on Windows. Runs against a throwaway fake home (CLAUDE_HUD_HOME), so your
# real ~/.claude, registry and settings are never touched. Drives the real UI through UI Automation + mouse.
#   powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
param([switch]$KeepHome, [string]$Build = 'dist')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $repo $Build
$hook = Join-Path $dist 'hud-hook.exe'
$app = Join-Path $dist 'ClaudeHUD.exe'
$h = Join-Path $env:TEMP ("claudehud-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$c = Join-Path $h '.claude'
$hud = Join-Path $c 'hud'
New-Item -ItemType Directory -Force $hud | Out-Null
$env:CLAUDE_HUD_HOME = $h

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class M {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  public static void Click(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(120); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
}
'@
[M]::SetProcessDPIAware() | Out-Null

$script:pass = 0; $script:fail = 0; $script:failures = @()
function Check($name, [bool]$ok, $detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; $script:failures += $name; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor White }

function Run($mode, $stdin, [int]$timeoutMs = 10000) {
  $psi = New-Object Diagnostics.ProcessStartInfo $hook, $mode
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync()
  if ($null -ne $stdin) { $b = [Text.Encoding]::UTF8.GetBytes($stdin); $p.StandardInput.BaseStream.Write($b, 0, $b.Length) }
  $p.StandardInput.Close()
  $done = $p.WaitForExit($timeoutMs)
  if (-not $done) { $p.Kill(); return @{ Code = -1; Out = ''; Timeout = $true } }
  return @{ Code = $p.ExitCode; Out = $out.Result; Timeout = $false }
}

function StartPerm($json) {
  $psi = New-Object Diagnostics.ProcessStartInfo $hook, 'perm'
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync()
  $b = [Text.Encoding]::UTF8.GetBytes($json); $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
  return @{ P = $p; Out = $out }
}
function WaitPerm($r, [int]$ms = 10000) { if ($r.P.WaitForExit($ms)) { return $r.Out.Result } $r.P.Kill(); return $null }

function Ev($o) { Run 'event' ($o | ConvertTo-Json -Compress -Depth 8) | Out-Null }
function JsonOk($s) { try { $null = $s | ConvertFrom-Json; $true } catch { $false } }

# MARK: UI Automation helpers
function HudRoot() {
  $p = Get-Process ClaudeHUD -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $script:appPid }
  if (-not $p) { return $null }
  $cond = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $script:appPid
  return [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $cond)
}
function Find($text, [int]$ms = 6000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    foreach ($w in (HudRoot)) {
      $cond = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty), $text
      $e = $w.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
      if ($e) { return $e }
    }
    Start-Sleep -Milliseconds 200
  }
  return $null
}
function Edits() {
  $all = @()
  foreach ($w in (HudRoot)) {
    $cond = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ControlTypeProperty), ([Windows.Automation.ControlType]::Edit)
    $all += @($w.FindAll([Windows.Automation.TreeScope]::Descendants, $cond))
  }
  return $all
}
# Text shown in a (read-only) text box, like a prompt's command.
function FindValue($text, [int]$ms = 6000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    foreach ($e in (Edits)) {
      try { if ($e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -eq $text) { return $e } } catch { }
    }
    Start-Sleep -Milliseconds 200
  }
  return $null
}
function GoneValue($text, [int]$ms = 6000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) { if (-not (FindValue $text 300)) { return $true }; Start-Sleep -Milliseconds 200 }
  return $false
}
function ClickText($text) {
  if (-not (Find $text)) { return $false }
  Start-Sleep -Milliseconds 450   # let a toast finish sliding in
  for ($try = 0; $try -lt 5; $try++) {
    $e = Find $text 2000          # re-find: a rebuild may have replaced the element
    if (-not $e) { return $false }
    $r = $e.Current.BoundingRectangle
    if ([double]::IsNaN($r.X) -or $r.Width -le 0) { Start-Sleep -Milliseconds 200; continue }
    [M]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 250
    [M]::SetCursorPos(200, 200) | Out-Null   # off the HUD so it can settle
    return $true
  }
  return $false
}
function Gone($text, [int]$ms = 6000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) { if (-not (Find $text 300)) { return $true }; Start-Sleep -Milliseconds 200 }
  return $false
}

$script:started = Get-Date
try {
  # ------------------------------------------------------------------ hooks, no app
  Section 'Event hook'
  $r = Run 'event' ''
  Check 'empty stdin exits 0 silently' ($r.Code -eq 0 -and $r.Out -eq '')
  $r = Run 'event' 'not json {{{'
  Check 'garbage stdin exits 0 silently' ($r.Code -eq 0 -and $r.Out -eq '')
  $big = 'x' * 1500000
  Ev @{ session_id = 'big'; hook_event_name = 'PreToolUse'; cwd = 'C:\w'; tool_name = 'Write'; tool_input = @{ file_path = $big } }
  $last = Get-Content (Join-Path $hud 'events.jsonl') -Tail 1
  Check '1.5 MB tool input: one valid line, detail cut to 160' ((JsonOk $last) -and (($last | ConvertFrom-Json).x.Length -eq 160))
  Ev @{ session_id = 'uni'; hook_event_name = 'PreToolUse'; cwd = 'C:\w'; tool_name = 'Bash'; tool_input = @{ command = 'echo "héllo ✓ 日本 \ end"' } }
  $last = Get-Content (Join-Path $hud 'events.jsonl') -Tail 1 -Encoding UTF8
  Check 'unicode, quotes and backslashes survive' (($last | ConvertFrom-Json).x -eq 'echo "héllo ✓ 日本 \ end"')
  Ev @{ session_id = 'num'; hook_event_name = 'PreToolUse'; cwd = 'C:\w'; tool_name = 'X'; tool_input = @{ command = @{ nested = 1 } } }
  Check 'non-string tool input is stringified' ((((Get-Content (Join-Path $hud 'events.jsonl') -Tail 1) | ConvertFrom-Json).x) -eq '{"nested":1}')

  $before = (Get-Content (Join-Path $hud 'events.jsonl')).Count
  $procs = 1..40 | ForEach-Object {
    $psi = New-Object Diagnostics.ProcessStartInfo $hook, 'event'
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write((@{ session_id = "par$_"; hook_event_name = 'PostToolUse'; cwd = 'C:\w'; tool_input = @{ command = ('y' * 150) } } | ConvertTo-Json -Compress))
    $p.StandardInput.Close(); $p
  }
  $procs | ForEach-Object { $_.WaitForExit(15000) | Out-Null }
  $lines = Get-Content (Join-Path $hud 'events.jsonl')
  $new = $lines[$before..($lines.Count - 1)]
  Check '40 hooks at once: 40 intact lines' ($new.Count -eq 40 -and @($new | Where-Object { -not (JsonOk $_) }).Count -eq 0) "got $($new.Count)"

  Section 'Status line hook'
  $r = Run 'statusline' '{"model":{"display_name":"Sonnet 5"},"workspace":{"current_dir":"C:\\proj\\web"}}'
  Check 'prints model and folder' ($r.Out.Trim() -eq 'Sonnet 5 · web')
  Check 'no rate_limits: no limits.json' (-not (Test-Path (Join-Path $hud 'limits.json')))
  $r = Run 'statusline' '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/x/api/"},"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":1900000000},"seven_day":{"used_percentage":9,"resets_at":1900000000}}}'
  Check 'prints limits' ($r.Out.Trim() -eq 'Opus · api · 5h 42% · wk 9%') $r.Out
  Check 'writes limits.json' (Test-Path (Join-Path $hud 'limits.json'))
  $r = Run 'statusline' 'garbage'
  Check 'garbage: exit 0, no output' ($r.Code -eq 0 -and $r.Out -eq '')

  Section 'Permission hook without the app'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Run 'perm' '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}'
  Check 'returns at once with no answer (normal dialog)' ($r.Code -eq 0 -and $r.Out -eq '' -and $sw.ElapsedMilliseconds -lt 3000) "$($sw.ElapsedMilliseconds) ms"
  Check 'leaves no request behind' (@(Get-ChildItem (Join-Path $hud 'req') -ErrorAction SilentlyContinue).Count -eq 0)

  Section 'Install / uninstall'
  $s = Join-Path $c 'settings.json'
  Remove-Item $s -ErrorAction SilentlyContinue
  $r = Run 'install' $null
  $j = Get-Content $s -Raw | ConvertFrom-Json
  Check 'no settings.json: creates one' ($r.Code -eq 0 -and $j.hooks.PreToolUse -and $j.hooks.PermissionRequest[0].hooks[0].timeout -eq 600)
  Check 'adds the status line when there is none' ($j.statusLine.command -like '*hud-hook.exe statusline')
  Check 'copies hud-hook.exe into ~/.claude/hud' (Test-Path (Join-Path $hud 'hud-hook.exe'))
  [IO.File]::WriteAllText($s, "$([char]0xFEFF){`"env`":{`"A`":`"1`"},`"hooks`":{`"Stop`":[{`"hooks`":[{`"type`":`"command`",`"command`":`"echo mine`"}]}]},`"statusLine`":{`"type`":`"command`",`"command`":`"my-status`"}}")
  Run 'install' $null | Out-Null
  Run 'install' $null | Out-Null
  $j = Get-Content $s -Raw | ConvertFrom-Json
  $ours = @($j.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*claude/hud/*' }).Count
  Check 'BOM settings parse; re-running adds no duplicates (10 entries)' ($ours -eq 10) "found $ours"
  Check 'keeps your own hooks, env and status line' ($j.env.A -eq '1' -and $j.hooks.Stop[0].hooks[0].command -eq 'echo mine' -and $j.statusLine.command -eq 'my-status')
  Check 'backup written' (Test-Path "$s.bak-claudehud")
  Check 'hook command needs no quoting (no spaces)' (-not ($j.hooks.PreToolUse[0].hooks[0].command -replace ' event$', '').Contains(' '))
  $broken = '{ "hooks": { oops'
  Set-Content $s $broken -NoNewline
  $r = Run 'install' $null
  Check 'invalid settings.json: refuses, leaves the file alone' ($r.Code -ne 0 -and (Get-Content $s -Raw) -eq $broken)
  Set-Content $s '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'
  Run 'install' $null | Out-Null
  Run 'uninstall' $null | Out-Null
  $j = Get-Content $s -Raw | ConvertFrom-Json
  Check 'uninstall removes ours and keeps yours' ($j.hooks.Stop.Count -eq 1 -and $j.hooks.Stop[0].hooks[0].command -eq 'echo mine' -and -not $j.statusLine -and -not $j.hooks.PreToolUse)
  Remove-Item $s

  # ------------------------------------------------------------------ the app
  Section 'App'
  '{"sounds":false,"welcomed":false,"hotkey":4,"menuBar":false,"fetchLimits":false,"edgeGlow":true}' | Set-Content -Encoding utf8 (Join-Path $hud 'prefs.json')
  Add-Content (Join-Path $hud 'events.jsonl') "garbage line`n{`"half`":"
  'not json' | Set-Content (Join-Path $hud 'limits.json')
  New-Item -ItemType Directory -Force (Join-Path $c 'projects\p') | Out-Null
  "garbage`n{`"type`":`"assistant`",`"message`":{`"id`":1}}`n" | Set-Content (Join-Path $c 'projects\p\t.jsonl')
  # A leftover test instance would hold the single-instance lock and make this launch exit.
  $stray = @(Get-Process ClaudeHUD -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$repo\dist*" })
  $stray | Stop-Process -Force
  $stray | ForEach-Object { $_.WaitForExit(5000) | Out-Null }
  $proc = Start-Process $app -PassThru
  $script:appPid = $proc.Id
  Start-Sleep 3
  Check 'starts despite garbage events, limits and transcripts' (-not $proc.HasExited)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not ((Get-Content (Join-Path $hud 'prefs.json') -Raw) -match '"welcomed":\s*true') -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 200 }
  Check 'shows the welcome on first run (and only once)' ((Get-Content (Join-Path $hud 'prefs.json') -Raw) -match '"welcomed":\s*true')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path $s) -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 200 }
  Check 'self-repair: wires the hooks on launch' ((Test-Path $s) -and ((Get-Content $s -Raw) -like '*hud-hook.exe perm*'))
  $p2 = Start-Process $app -PassThru; Start-Sleep 2
  Check 'a second launch exits (single instance)' ($p2.HasExited)
  [M]::SetCursorPos(200, 200) | Out-Null

  # Measured before any UI Automation call: an automation client makes WPF do extra accessibility work.
  Section 'Resources (idle, after start-up warm-up)'
  Start-Sleep 35
  # Lowest of three 5 s samples: steady-state cost, not one-off spikes (JIT, first scans).
  $samples = foreach ($i in 1..3) {
    $proc.Refresh(); $cpu0 = $proc.TotalProcessorTime
    Start-Sleep 5
    $proc.Refresh(); ($proc.TotalProcessorTime - $cpu0).TotalSeconds / 5 * 100
  }
  $cpu = ($samples | Measure-Object -Minimum).Minimum
  $mem = $proc.WorkingSet64 / 1MB
  $limit = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -and $Build -ne 'dist') { 14 } else { 6 }   # x64/x86 builds run emulated on ARM64; steady state is ~2% native
  Check ("idle CPU under {0}% of one core ({1:N1}%)" -f $limit, $cpu) ($cpu -lt $limit)
  Check ("memory under 220 MB ({0:N0} MB)" -f $mem) ($mem -lt 220)

  function Req($sid, $tool, $toolInput, $extra = @{}) {
    $o = @{ session_id = $sid; tool_name = $tool; tool_input = $toolInput; cwd = 'C:\work\api'; transcript_path = '' } + $extra
    StartPerm ($o | ConvertTo-Json -Compress -Depth 10)
  }

  Section 'Permission prompts answered from the HUD'
  $r = Req 'p-allow' 'Bash' @{ command = 'npm run build' }
  Check 'prompt shows up' ([bool](FindValue 'npm run build')) (((Edits) | % { try { $_.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { '?' } }) -join ' | ')
  Check 'click Allow' (ClickText 'Allow')
  $out = WaitPerm $r
  Check 'Claude gets allow' ($out -like '*"behavior":"allow"*' -and $out -like '*PermissionRequest*') $out
  Check 'prompt leaves the HUD' (GoneValue 'npm run build')

  $r = Req 'p-deny' 'Bash' @{ command = 'rm -rf /' }
  ClickText 'Deny' | Out-Null
  $out = WaitPerm $r
  Check 'Deny → deny' ($out -like '*"behavior":"deny"*') $out

  $r = Req 'p-always' 'Bash' @{ command = 'npm ci' } @{ permission_suggestions = @(@{ type = 'addRules'; rules = @(@{ toolName = 'Bash'; ruleContent = 'npm ci:*' }) }) }
  Check 'shows what Always means' ([bool](Find 'Always = don''t ask again for Bash(npm ci:*)'))
  ClickText 'Always' | Out-Null
  $out = WaitPerm $r
  Check 'Always → allow + updatedPermissions' ($out -like '*updatedPermissions*npm ci:*') $out

  $r = Req 'p-editor' 'Write' @{ file_path = 'C:\work\api\x.ts' }
  $clicked = (ClickText 'VS Code') -or (ClickText 'Cursor') -or (ClickText 'Terminal')
  Check 'shows the answer-in-editor button' $clicked
  $out = WaitPerm $r
  Check 'editor button → no answer (Claude shows its own dialog)' ($out -eq '') "[$out]"
  $log = Get-Content (Join-Path $hud 'actions.log') -Raw -ErrorAction SilentlyContinue
  Check 'and opens that session in the editor' ($log -match '(open \w[\w-]*://anthropic\.claude-code/open\?session=p-editor)|(focus )') $log
  Start-Sleep 1

  $r = Req 'p-killed' 'Bash' @{ command = 'sleep 999' }
  Check 'prompt shows' ([bool](FindValue 'sleep 999'))
  $r.P.Kill()
  Check 'hook killed → prompt disappears' (GoneValue 'sleep 999' 5000)

  Section 'Questions from Claude (AskUserQuestion)'
  $q1 = @{ questions = @(@{ question = 'Which database should I use?'; header = 'Database'; multiSelect = $false;
                            options = @(@{ label = 'Postgres'; description = 'Relational' }, @{ label = 'SQLite'; description = 'File based' }) }) }
  $r = Req 'q-one' 'AskUserQuestion' $q1
  Check 'question pops up' ([bool](Find 'Claude has a question'))
  Check 'shows the question text' ([bool](Find 'Which database should I use?'))
  ClickText 'SQLite' | Out-Null
  $out = WaitPerm $r
  $o = $out | ConvertFrom-Json
  Check 'one click answers: answers + original questions sent back' ($o.hookSpecificOutput.decision.updatedInput.answers.'Which database should I use?' -eq 'SQLite' -and $o.hookSpecificOutput.decision.updatedInput.questions.Count -eq 1) $out

  $q2 = @{ questions = @(
      @{ question = 'Which features?'; header = 'Features'; multiSelect = $true; options = @(@{ label = 'Auth'; description = '' }, @{ label = 'Billing'; description = '' }, @{ label = 'Search'; description = '' }) },
      @{ question = 'Ship when?'; header = 'Timing'; multiSelect = $false; options = @(@{ label = 'Today'; description = '' }, @{ label = 'Next week'; description = '' }) }) }
  $r = Req 'q-multi' 'AskUserQuestion' $q2
  Check 'two questions pop up' ([bool](Find 'Claude has 2 questions'))
  ClickText '☐ Auth' | Out-Null
  ClickText '☐ Search' | Out-Null
  Check 'multi-select ticks stay ticked' ([bool](Find '☑ Auth') -and [bool](Find '☑ Search'))
  ClickText 'Send answers' | Out-Null
  Start-Sleep 1
  Check 'unanswered question blocks sending' (-not $r.P.HasExited)
  $edits = @(Edits)
  $vp = $edits[-1].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
  $vp.SetValue('After the demo')
  ClickText 'Send answers' | Out-Null
  $out = WaitPerm $r
  if (-not $out) { $out = '{}' }
  $a = ($out | ConvertFrom-Json).hookSpecificOutput.decision.updatedInput.answers
  Check 'multi + typed "Other" answers' ($a.'Which features?' -eq 'Auth, Search' -and $a.'Ship when?' -eq 'After the demo') "$out (edits: $($edits.Count))"

  $r = Req 'q-skip' 'AskUserQuestion' $q1
  ClickText 'Skip' | Out-Null
  $out = WaitPerm $r
  Check 'Skip → deny' ($out -like '*"behavior":"deny"*') $out

  Section 'Errors from Anthropic (payment, access, recovery)'
  $tdir = Join-Path $c 'projects\C--work-billing'
  New-Item -ItemType Directory -Force $tdir | Out-Null
  $tx = Join-Path $tdir 'bill-1.jsonl'
  function Now() { [DateTime]::UtcNow.ToString('o') }
  Add-Content -Encoding utf8 $tx ('{"type":"user","timestamp":"' + (Now) + '","message":{"role":"user","content":"fix the build"}}')
  Ev @{ session_id = 'bill-1'; hook_event_name = 'UserPromptSubmit'; cwd = 'C:\work\billing'; transcript_path = $tx }
  Add-Content -Encoding utf8 $tx ('{"type":"assistant","timestamp":"' + (Now) + '","message":{"id":"e1","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}]},"error":"billing_error","isApiErrorMessage":true,"apiErrorStatus":400}')
  Check 'payment error pops up' ([bool](Find 'Payment needed · billing' 12000))
  Check 'with a billing button' (ClickText 'Open billing')
  $log = Get-Content (Join-Path $hud 'actions.log') -Raw
  Check 'billing button opens the API console billing page' ($log -like '*link https://console.anthropic.com/settings/billing*')
  Add-Content -Encoding utf8 $tx ('{"type":"assistant","timestamp":"' + (Now) + '","message":{"id":"m2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"Build fixed."}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}')
  Check 'next real reply → "Payment went through"' ([bool](Find 'Payment went through' 12000))

  $tx2 = Join-Path $tdir 'org-1.jsonl'
  Ev @{ session_id = 'org-1'; hook_event_name = 'UserPromptSubmit'; cwd = 'C:\work\billing'; transcript_path = $tx2 }
  Add-Content -Encoding utf8 $tx2 ('{"type":"assistant","timestamp":"' + (Now) + '","message":{"id":"e2","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"}]},"error":"oauth_org_not_allowed","isApiErrorMessage":true,"apiErrorStatus":403,"apiErrorCode":"oauth_not_allowed_for_organization"}')
  Check 'org access disabled → "Access blocked"' ([bool](Find 'Access blocked · billing' 12000))
  Add-Content -Encoding utf8 $tx2 ('{"type":"system","subtype":"local_command","content":"<local-command-stderr>Error during compaction: Your organization has disabled Claude subscription access for Claude Code</local-command-stderr>","timestamp":"' + (Now) + '","commandOutcome":{"kind":"failed"}}')
  Start-Sleep 6
  Check 'the same problem again does not re-alert' (@(Find 'Access blocked · billing' 500).Count -le 1)
  Section 'Sessions'
  $dummy = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 600' -WindowStyle Hidden -PassThru
  $line = @{ s = 'live-1'; e = 'Stop'; c = 'C:\work\shop'; ts = [double]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds; p = $dummy.Id; x = '' } | ConvertTo-Json -Compress
  Add-Content (Join-Path $hud 'events.jsonl') $line
  Check 'finished session toasts "Your turn"' ([bool](Find 'YOUR TURN'))
  $dummy.Kill()
  Check 'claude process gone → "Session ended"' ([bool](Find 'Session ended' 5000))

  Section 'Drawer'
  $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  [M]::SetCursorPos($b.Right - 1, [int]($b.Top + $b.Height / 2)) | Out-Null
  Check 'hovering the screen edge opens the drawer' ([bool](Find '5-HOUR' 4000) -or [bool](Find ([string]::Join([char]0x200A, '5-HOUR'.ToCharArray())) 1000))
  [M]::SetCursorPos(200, 200) | Out-Null
  Start-Sleep 1.5
  Check 'leaving closes it' (Gone 'C L A U D E' 3000)

  Section 'Health'
  Check 'still running after the whole run' (-not (Get-Process -Id $script:appPid).HasExited)
  $err = Join-Path $env:APPDATA 'ClaudeHUD\error.log'
  Check 'no errors logged' (-not (Test-Path $err) -or (Get-Item $err).LastWriteTime -lt $script:started)
} finally {
  if ($script:appPid) { Stop-Process -Id $script:appPid -Force -ErrorAction SilentlyContinue }
  Get-Process hud-hook -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dist*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\CLAUDE_HUD_HOME
  if (-not $KeepHome) { Remove-Item -Recurse -Force $h -ErrorAction SilentlyContinue }
}

Write-Host "`n$script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; exit 1 }
