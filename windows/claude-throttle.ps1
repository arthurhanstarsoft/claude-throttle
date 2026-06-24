<#
  claude-throttle (Windows / PowerShell 5.1+ port)

  Stops Claude Code from freezing the machine when it runs many heavy commands in
  parallel. Mirrors the macOS/Linux bash tool:
    Layer 1 (throttle): a PreToolUse hook rewrites heavy commands to run through a
      wrapper that holds one of N concurrency slots (named mutexes); N scales with
      free RAM. Dev servers / background commands are not throttled.
    Layer 2 (watchdog): a Task-Scheduler background loop that suspends (and later
      resumes) the heaviest Claude descendant processes when free memory is low.

  Subcommands: hook | run | watchdog | status | doctor | install | uninstall | update | help
  Always invoke with: powershell -NoProfile -ExecutionPolicy Bypass -File claude-throttle.ps1 <cmd>
#>
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Stop'

# ---- paths (mirror the bash layout, all under $HOME) ------------------------
$CT_CONFIG_DIR  = Join-Path $HOME '.config\claude-throttle'
$CT_CONFIG_FILE = Join-Path $CT_CONFIG_DIR 'config.ps1'
$CT_STATE_DIR   = Join-Path $HOME '.local\state\claude-throttle'
$CT_THROTTLE_LOG = Join-Path $CT_STATE_DIR 'throttle.log'
$CT_WATCHDOG_LOG = Join-Path $CT_STATE_DIR 'watchdog.log'
$CT_WATCHDOG_PID = Join-Path $CT_STATE_DIR 'watchdog.pid'
$CT_PAUSED_LIST  = Join-Path $CT_STATE_DIR 'paused.list'
$CT_SOURCE_PATH  = Join-Path $CT_STATE_DIR 'source_path'
$CT_INSTALL_DIR  = Join-Path $HOME '.local\share\claude-throttle'
$CT_INSTALL_PS1  = Join-Path $CT_INSTALL_DIR 'windows\claude-throttle.ps1'
$CT_SETTINGS     = Join-Path $HOME '.claude\settings.json'
$CT_TASK_NAME    = 'claude-throttle-watchdog'

foreach ($d in @($CT_CONFIG_DIR, $CT_STATE_DIR)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---- config: defaults (env override), then dot-source the config file -------
function Def([string]$name, $default) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($null -ne $v -and $v -ne '') { return $v }
  return $default
}
$CT_ENABLED            = [int](Def 'CT_ENABLED' 1)
$CT_GATE_MODE          = [string](Def 'CT_GATE_MODE' 'heavy')
$CT_HEAVY_REGEX        = [string](Def 'CT_HEAVY_REGEX' '(pnpm|npm|yarn|bun|tsc|webpack|vite|jest|vitest|build|test|install|cargo|make|gradle|msbuild|dotnet|docker)')
$CT_LONGRUN_REGEX      = [string](Def 'CT_LONGRUN_REGEX' '(--watch|\s-w(\s|$)|\swatch(\s|$)|run (dev|start|serve)|\sdev(\s|$)|\sserve(\s|$)|nodemon|next dev|nuxt dev|ng serve|rails (s|server)|artisan serve|flask run|uvicorn|gunicorn|storybook|http-server|live-server)')
$CT_BYPASS_PERMISSIONS = [int](Def 'CT_BYPASS_PERMISSIONS' 0)
$CT_DYNAMIC            = [int](Def 'CT_DYNAMIC' 1)
$CT_MAX_CONCURRENCY    = [int](Def 'CT_MAX_CONCURRENCY' 6)
$CT_MIN_CONCURRENCY    = [int](Def 'CT_MIN_CONCURRENCY' 1)
$CT_MEM_PER_SLOT_MB    = [int](Def 'CT_MEM_PER_SLOT_MB' 1500)
$CT_FALLBACK_CONCURRENCY = [int](Def 'CT_FALLBACK_CONCURRENCY' 2)
$CT_ACQUIRE_TIMEOUT    = [int](Def 'CT_ACQUIRE_TIMEOUT' 300)
$CT_POLL               = [double](Def 'CT_POLL' 0.3)
$CT_PRESTART_WAIT      = [int](Def 'CT_PRESTART_WAIT' 1)
$CT_PRESTART_TIMEOUT   = [int](Def 'CT_PRESTART_TIMEOUT' 60)
$CT_PRIORITY_CLASS     = [string](Def 'CT_PRIORITY_CLASS' 'BelowNormal')
$CT_INNER_SHELL        = [string](Def 'CT_INNER_SHELL' '')
$CT_MEM_METRIC         = [string](Def 'CT_MEM_METRIC' 'available')
$CT_WATCHDOG_INTERVAL  = [int](Def 'CT_WATCHDOG_INTERVAL' 2)
$CT_CRIT_FREE_PCT      = [int](Def 'CT_CRIT_FREE_PCT' 10)
$CT_RESUME_FREE_PCT    = [int](Def 'CT_RESUME_FREE_PCT' 25)
$CT_CRIT_SUSTAIN       = [int](Def 'CT_CRIT_SUSTAIN' 2)
$CT_PAUSE_COUNT        = [int](Def 'CT_PAUSE_COUNT' 2)
$CT_MIN_PAUSE_RSS_MB   = [int](Def 'CT_MIN_PAUSE_RSS_MB' 150)
if (Test-Path $CT_CONFIG_FILE) { . $CT_CONFIG_FILE }   # overrides the above

# ---- logging ----------------------------------------------------------------
function CtLog($file, $msg) {
  try {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $msg
    Add-Content -LiteralPath $file -Value $line -ErrorAction SilentlyContinue
  } catch {}
}
function CtTlog($m) { CtLog $CT_THROTTLE_LOG $m }
function CtWlog($m) { CtLog $CT_WATCHDOG_LOG $m }

function Ok($m)   { Write-Host ('  [+] ' + $m) -ForegroundColor Green }
function Bad($m)  { Write-Host ('  [x] ' + $m) -ForegroundColor Red }
function Warn($m) { Write-Host ('  [!] ' + $m) -ForegroundColor Yellow }

# ---- metrics ----------------------------------------------------------------
function Get-AvailableMB {
  try { return [int]((Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop).AvailableMBytes) }
  catch { return $null }
}
function Get-TotalMemMB {
  try { return [int][math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB) }
  catch { return $null }
}
function Get-FreePctFromOS {
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return [int][math]::Round($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
  } catch { return $null }
}
function Get-FreePct {
  if ($CT_MEM_METRIC -eq 'free') { return Get-FreePctFromOS }
  $av = Get-AvailableMB; $total = Get-TotalMemMB
  if ($null -ne $av -and $total) { return [int][math]::Round($av / $total * 100) }
  return Get-FreePctFromOS
}
function Get-FreeMB {
  if ($CT_MEM_METRIC -ne 'free') { $av = Get-AvailableMB; if ($null -ne $av) { return $av } }
  $p = Get-FreePct; $t = Get-TotalMemMB
  if ($null -ne $p -and $t) { return [int]($p * $t / 100) }
  return $null
}
function Get-Cores { $c = [int]$env:NUMBER_OF_PROCESSORS; if ($c -lt 1) { $c = 1 }; return $c }

function Get-EffectiveConcurrency {
  $maxc = $CT_MAX_CONCURRENCY; $minc = $CT_MIN_CONCURRENCY
  if ($CT_DYNAMIC -ne 1) { return $maxc }
  $free = Get-FreeMB
  if ($null -eq $free -or $CT_MEM_PER_SLOT_MB -le 0) { return $CT_FALLBACK_CONCURRENCY }
  $n = [int][math]::Round($free / $CT_MEM_PER_SLOT_MB)
  $cores = Get-Cores
  if ($n -gt $cores) { $n = $cores }
  if ($n -gt $maxc)  { $n = $maxc }
  if ($n -lt $minc)  { $n = $minc }
  return $n
}

# ---- process tree -----------------------------------------------------------
function Get-ClaudeAnchors {
  if ($env:CT_ANCHOR_OVERRIDE) {
    return @($env:CT_ANCHOR_OVERRIDE -split '\s+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
  }
  try { $procs = Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, CommandLine }
  catch { return @() }
  $procs | Where-Object {
    ($_.Name -eq 'claude.exe') -or
    ($_.CommandLine -and ($_.CommandLine -match '\bclaude\b') -and ($_.CommandLine -notmatch 'claude-throttle'))
  } | ForEach-Object { [int]$_.ProcessId }
}
function Get-ClaudeDescendants {
  $anchors = @(Get-ClaudeAnchors)
  if ($anchors.Count -eq 0) { return @() }
  try { $procs = Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId }
  catch { return @() }
  $byParent = @{}
  foreach ($p in $procs) {
    $k = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }
    [void]$byParent[$k].Add([int]$p.ProcessId)
  }
  $anchorSet = @{}; foreach ($a in $anchors) { $anchorSet[[int]$a] = $true }
  $queue = New-Object System.Collections.Queue
  foreach ($a in $anchors) { $queue.Enqueue([int]$a) }
  $seen = @{}; $result = New-Object System.Collections.ArrayList
  while ($queue.Count -gt 0) {
    $cur = $queue.Dequeue()
    if ($byParent.ContainsKey($cur)) {
      foreach ($child in $byParent[$cur]) {
        if ($seen.ContainsKey($child) -or $anchorSet.ContainsKey($child)) { continue }
        $seen[$child] = $true; [void]$result.Add($child); $queue.Enqueue($child)
      }
    }
  }
  return $result.ToArray()
}

# ---- suspend/resume (P/Invoke into ntdll) -----------------------------------
$script:CtProcSource = @'
using System;
using System.Runtime.InteropServices;
public static class CtProc {
    public const int PROCESS_SUSPEND_RESUME = 0x0800;
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("ntdll.dll")] public static extern uint NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] public static extern uint NtResumeProcess(IntPtr h);
    public static bool Suspend(int pid) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return NtSuspendProcess(h) == 0; } finally { CloseHandle(h); }
    }
    public static bool Resume(int pid) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return NtResumeProcess(h) == 0; } finally { CloseHandle(h); }
    }
}
'@
function Ensure-SuspendType {
  if (-not ([System.Management.Automation.PSTypeName]'CtProc').Type) {
    Add-Type -TypeDefinition $script:CtProcSource -Language CSharp
  }
}
function Suspend-Available {
  try { Ensure-SuspendType; return $true } catch { return $false }
}

# ============================================================================
# HOOK
# ============================================================================
function Cmd-Hook {
  try {
    if ($CT_ENABLED -ne 1) { return }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $obj = $raw | ConvertFrom-Json
    $cmd = $obj.tool_input.command
    if ([string]::IsNullOrEmpty($cmd)) { return }
    if (($cmd -match 'claude-throttle') -and ($cmd -match '\brun\b')) { return }  # idempotent
    if ($obj.tool_input.run_in_background -eq $true) { CtTlog "HOOK skip (background): $cmd"; return }
    if ($cmd -match $CT_LONGRUN_REGEX) { CtTlog "HOOK skip (long-running): $cmd"; return }
    if ($CT_GATE_MODE -eq 'heavy' -and ($cmd -notmatch $CT_HEAVY_REGEX)) { return }

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    $self = $CT_INSTALL_PS1
    if (-not (Test-Path $self)) { $self = $PSCommandPath }
    $wrapped = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" run --b64 {1}' -f $self, $b64

    $out = [ordered]@{ hookSpecificOutput = [ordered]@{
        hookEventName = 'PreToolUse'
        updatedInput  = [ordered]@{ command = $wrapped }
      } }
    if ($CT_BYPASS_PERMISSIONS -eq 1) { $out.hookSpecificOutput.permissionDecision = 'allow' }
    ($out | ConvertTo-Json -Compress -Depth 6)
    CtTlog "HOOK wrapped: $cmd"
  } catch { return }   # FAIL-OPEN: emit nothing, run original unchanged
}

# ============================================================================
# RUN (the wrapper that holds a slot)
# ============================================================================
function Decode-Payload($rest) {
  $a = @($rest)
  if ($a.Count -ge 2 -and $a[0] -eq '--b64') {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($a[1]))
  }
  if ($a.Count -ge 1 -and $a[0] -eq '--') {
    if ($a.Count -ge 2) { return ($a[1..($a.Count - 1)] -join ' ') } else { return '' }
  }
  return ($a -join ' ')
}
function Resolve-InnerShell {
  if ($CT_INNER_SHELL -eq 'cmd')  { return @{ exe = $env:ComSpec; bash = $false } }
  if ($CT_INNER_SHELL -eq 'bash') {
    $b = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($b) { return @{ exe = $b.Source; bash = $true } }
  }
  if ([string]::IsNullOrEmpty($CT_INNER_SHELL)) {
    $b = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($b) { return @{ exe = $b.Source; bash = $true } }
  }
  return @{ exe = $env:ComSpec; bash = $false }
}
function Invoke-Original([string]$orig) {
  # Write the command to a temp script and run it — sidesteps all quoting.
  $sh = Resolve-InnerShell
  $base = Join-Path $env:TEMP ('ct-' + [guid]::NewGuid().ToString('N'))
  $tmp = $null
  try {
    $enc = New-Object System.Text.UTF8Encoding $false
    if ($sh.bash) {
      $tmp = "$base.sh"
      [IO.File]::WriteAllText($tmp, ($orig -replace "`r`n", "`n"), $enc)
      $args = '"{0}"' -f $tmp
    } else {
      $tmp = "$base.cmd"
      [IO.File]::WriteAllText($tmp, "@echo off`r`n$orig`r`n", $enc)
      $args = '/c "{0}"' -f $tmp
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $sh.exe
    $p.StartInfo.Arguments = $args
    $p.StartInfo.UseShellExecute = $false
    [void]$p.Start()
    if ($CT_PRIORITY_CLASS) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$CT_PRIORITY_CLASS } catch {} }
    $p.WaitForExit()
    return $p.ExitCode
  } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue } }
}
function Cmd-Run($rest) {
  $orig = Decode-Payload $rest
  if ([string]::IsNullOrEmpty($orig)) { CtTlog 'RUN empty'; return 0 }
  if ($CT_ENABLED -ne 1) { return (Invoke-Original $orig) }

  if ($CT_PRESTART_WAIT -eq 1) {
    $dl = (Get-Date).AddSeconds($CT_PRESTART_TIMEOUT)
    while ((Get-Date) -lt $dl) {
      $f = Get-FreePct
      if ($null -eq $f -or $f -ge $CT_RESUME_FREE_PCT) { break }
      Start-Sleep -Milliseconds 500
    }
  }

  # Acquire a slot. Any error during acquisition (before the command has run) is
  # fail-open: run the command unthrottled. We never re-run after the command has
  # started, so there's no double-execution risk.
  $held = $null
  try {
    $acqDl = (Get-Date).AddSeconds($CT_ACQUIRE_TIMEOUT)
    while ($true) {
      $N = Get-EffectiveConcurrency
      for ($i = 1; $i -le $N; $i++) {
        $m = New-Object System.Threading.Mutex($false, "Local\claude-throttle-slot-$i")
        $got = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $held = $m; break } else { $m.Dispose() }
      }
      if ($held) { break }
      if ((Get-Date) -ge $acqDl) { CtTlog "SLOT_TIMEOUT_FALLBACK running unthrottled: $orig"; break }
      Start-Sleep -Seconds ($CT_POLL + (Get-Random -Minimum 0 -Maximum 300) / 1000.0)
    }
  } catch {
    CtTlog "RUN acquire error, running unthrottled: $_"
    return (Invoke-Original $orig)
  }
  if (-not $held) { return (Invoke-Original $orig) }   # timed out -> unthrottled
  try {
    $rc = Invoke-Original $orig
    CtTlog "RAN rc=$rc: $orig"
    return $rc
  } finally {
    try { $held.ReleaseMutex() } catch {}
    $held.Dispose()
  }
}

# ============================================================================
# WATCHDOG
# ============================================================================
$script:WD_EXCLUDE = @('System','Idle','Registry','smss','csrss','wininit','winlogon',
  'services','lsass','lsm','svchost','dwm','explorer','fontdrvhost','sihost','ctfmon',
  'RuntimeBroker','WindowsTerminal','OpenConsole','conhost')

function Get-PausableTargets {
  $desc = @(Get-ClaudeDescendants)
  if ($desc.Count -eq 0) { return @() }
  $descSet = @{}; foreach ($d in $desc) { $descSet[[int]$d] = $true }
  $floorBytes = [long]$CT_MIN_PAUSE_RSS_MB * 1MB
  $anchors = @{}; foreach ($a in (Get-ClaudeAnchors)) { $anchors[[int]$a] = $true }
  try { $procs = Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, WorkingSetSize }
  catch { return @() }
  $out = foreach ($p in $procs) {
    $pid2 = [int]$p.ProcessId
    if (-not $descSet.ContainsKey($pid2)) { continue }
    if ($pid2 -eq $PID -or $anchors.ContainsKey($pid2)) { continue }
    $nm = ($p.Name -replace '\.exe$', '')
    if ($script:WD_EXCLUDE -contains $nm) { continue }
    if ([long]$p.WorkingSetSize -lt $floorBytes) { continue }
    [pscustomobject]@{ Pid = $pid2; Rss = [long]$p.WorkingSetSize; Name = $p.Name }
  }
  return @($out | Sort-Object Rss -Descending)
}

function Resume-AllPaused {
  if (Test-Path $CT_PAUSED_LIST) {
    foreach ($line in (Get-Content $CT_PAUSED_LIST -ErrorAction SilentlyContinue)) {
      if ($line) { [CtProc]::Resume([int]$line) | Out-Null }
    }
  }
}
function Paused-Count {
  if (Test-Path $CT_PAUSED_LIST) { return @(Get-Content $CT_PAUSED_LIST | Where-Object { $_ }).Count }
  return 0
}

function Cmd-Watchdog {
  if (-not (Suspend-Available)) { CtWlog 'suspend API unavailable (Add-Type/Constrained Language Mode?) — exiting'; return 0 }

  $singleton = New-Object System.Threading.Mutex($false, 'Local\claude-throttle-watchdog')
  $owned = $false
  try { $owned = $singleton.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { CtWlog 'another watchdog is already running; exiting'; return 0 }
  Set-Content -LiteralPath $CT_WATCHDOG_PID -Value $PID

  Resume-AllPaused                       # resume leftovers from a crashed run
  Set-Content -LiteralPath $CT_PAUSED_LIST -Value ''

  CtWlog ("watchdog started os=windows (crit_free={0}% resume_free={1}% interval={2}s metric={3})" -f `
    $CT_CRIT_FREE_PCT, $CT_RESUME_FREE_PCT, $CT_WATCHDOG_INTERVAL, $CT_MEM_METRIC)

  $state = 'NORMAL'; $sustained = 0
  try {
    while ($true) {
      $free = Get-FreePct

      # reconcile paused.list: if claude is gone, resume all; else drop dead pids
      if ((Paused-Count) -gt 0) {
        if ((Get-ClaudeAnchors).Count -eq 0) {
          Resume-AllPaused; Set-Content -LiteralPath $CT_PAUSED_LIST -Value ''
          $state = 'NORMAL'; $sustained = 0; CtWlog 'claude gone; resumed all and reset'
        } else {
          $alive = @(Get-Content $CT_PAUSED_LIST | Where-Object { $_ -and (Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue) })
          Set-Content -LiteralPath $CT_PAUSED_LIST -Value $alive
        }
      }

      if ($null -eq $free) { Start-Sleep -Seconds $CT_WATCHDOG_INTERVAL; continue }

      if ($state -eq 'NORMAL') {
        if ($free -le $CT_CRIT_FREE_PCT) {
          $sustained++
          if ($sustained -ge $CT_CRIT_SUSTAIN) {
            $targets = @(Get-PausableTargets | Select-Object -First $CT_PAUSE_COUNT)
            $any = $false
            foreach ($t in $targets) {
              if ([CtProc]::Suspend($t.Pid)) {
                Add-Content -LiteralPath $CT_PAUSED_LIST -Value $t.Pid
                CtWlog ("PAUSED pid={0} rss={1} name={2} (free={3}%)" -f $t.Pid, $t.Rss, $t.Name, $free)
                $any = $true
              }
            }
            if ($any) { $state = 'THROTTLED' } else { CtWlog "CRITICAL free=$free% but no pausable target found" }
            $sustained = 0
          }
        } else { $sustained = 0 }
      } else {
        if ($free -ge $CT_RESUME_FREE_PCT) {
          if ((Paused-Count) -gt 0) {
            $lines = @(Get-Content $CT_PAUSED_LIST | Where-Object { $_ })
            [array]::Reverse($lines)
            foreach ($p in $lines) { [CtProc]::Resume([int]$p) | Out-Null; CtWlog "RESUMED pid=$p (free=$free%)" }
          }
          Set-Content -LiteralPath $CT_PAUSED_LIST -Value ''
          $state = 'NORMAL'; $sustained = 0
        }
      }
      Start-Sleep -Seconds $CT_WATCHDOG_INTERVAL
    }
  } finally {
    Resume-AllPaused
    Set-Content -LiteralPath $CT_PAUSED_LIST -Value ''
    Remove-Item -LiteralPath $CT_WATCHDOG_PID -ErrorAction SilentlyContinue
  }
}

# ============================================================================
# settings.json hook merge (native JSON, UTF-8 no BOM)
# ============================================================================
function Write-JsonNoBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}
function Hook-Installed {
  if (-not (Test-Path $CT_SETTINGS)) { return $false }
  try { $j = Get-Content -Raw $CT_SETTINGS | ConvertFrom-Json } catch { return $false }
  if (-not $j.hooks -or -not $j.hooks.PreToolUse) { return $false }
  foreach ($entry in @($j.hooks.PreToolUse)) {
    foreach ($h in @($entry.hooks)) {
      if ($h.command -and ($h.command -match 'claude-throttle.*hook')) { return $true }
    }
  }
  return $false
}
function Install-Hook {
  $hookCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" hook' -f $CT_INSTALL_PS1
  New-Item -ItemType Directory -Force -Path (Split-Path $CT_SETTINGS) | Out-Null
  if (-not (Test-Path $CT_SETTINGS)) { Write-JsonNoBom $CT_SETTINGS '{}' }
  if (Hook-Installed) { Warn "hook already present in $CT_SETTINGS, leaving as-is"; return }
  Copy-Item $CT_SETTINGS "$CT_SETTINGS.bak" -Force; Ok "backed up settings to $CT_SETTINGS.bak"
  $j = Get-Content -Raw $CT_SETTINGS | ConvertFrom-Json
  if (-not $j.PSObject.Properties['hooks']) { $j | Add-Member hooks ([pscustomobject]@{}) }
  if (-not $j.hooks.PSObject.Properties['PreToolUse']) { $j.hooks | Add-Member PreToolUse @() }
  $entry = [pscustomobject]@{
    matcher = 'Bash'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 10 })
  }
  $j.hooks.PreToolUse = @($j.hooks.PreToolUse) + $entry
  Write-JsonNoBom $CT_SETTINGS ($j | ConvertTo-Json -Depth 12)
  Ok "added PreToolUse hook to $CT_SETTINGS"
}
function Remove-Hook {
  if (-not (Test-Path $CT_SETTINGS)) { return }
  try { $j = Get-Content -Raw $CT_SETTINGS | ConvertFrom-Json } catch { Warn "could not parse $CT_SETTINGS"; return }
  if (-not $j.hooks -or -not $j.hooks.PreToolUse) { return }
  Copy-Item $CT_SETTINGS "$CT_SETTINGS.bak" -Force
  $kept = @(@($j.hooks.PreToolUse) | Where-Object {
      $isOurs = $false
      foreach ($h in @($_.hooks)) { if ($h.command -and ($h.command -match 'claude-throttle.*hook')) { $isOurs = $true } }
      -not $isOurs
    })
  if ($kept.Count -eq 0) { $j.hooks.PSObject.Properties.Remove('PreToolUse') }
  else { $j.hooks.PreToolUse = $kept }
  if (-not $j.hooks.PSObject.Properties['PreToolUse']) { $j.PSObject.Properties.Remove('hooks') }
  Write-JsonNoBom $CT_SETTINGS ($j | ConvertTo-Json -Depth 12)
  Ok "removed hook from $CT_SETTINGS"
}

# ============================================================================
# scheduled task (watchdog at logon)
# ============================================================================
function Task-Register {
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" watchdog' -f $CT_INSTALL_PS1
  $action  = New-ScheduledTaskAction -Execute $ps -Argument $args
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $CT_TASK_NAME -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
  Ok "registered scheduled task '$CT_TASK_NAME'"
  try { Start-ScheduledTask -TaskName $CT_TASK_NAME; Ok 'started watchdog task' }
  catch { Warn 'could not start task now; it will start at next logon' }
}
function Task-Unregister {
  try { Stop-ScheduledTask -TaskName $CT_TASK_NAME -ErrorAction SilentlyContinue } catch {}
  try { Unregister-ScheduledTask -TaskName $CT_TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue; Ok "removed scheduled task" } catch {}
  if (Test-Path $CT_WATCHDOG_PID) {
    try { Stop-Process -Id ([int](Get-Content $CT_WATCHDOG_PID)) -ErrorAction SilentlyContinue } catch {}
  }
}
function Task-State {
  try { return (Get-ScheduledTask -TaskName $CT_TASK_NAME -ErrorAction Stop).State } catch { return $null }
}
function Watchdog-Running {
  if (-not (Test-Path $CT_WATCHDOG_PID)) { return $false }
  try { return [bool](Get-Process -Id ([int](Get-Content $CT_WATCHDOG_PID)) -ErrorAction SilentlyContinue) } catch { return $false }
}

# ============================================================================
# status / doctor
# ============================================================================
function Cmd-Status {
  if ($CT_DYNAMIC -eq 1) {
    Write-Host ("enabled={0} gate={1} concurrency=dynamic now={2} (range {3}..{4})" -f `
      $CT_ENABLED, $CT_GATE_MODE, (Get-EffectiveConcurrency), $CT_MIN_CONCURRENCY, $CT_MAX_CONCURRENCY)
  } else {
    Write-Host ("enabled={0} gate={1} concurrency=fixed:{2}" -f $CT_ENABLED, $CT_GATE_MODE, $CT_MAX_CONCURRENCY)
  }
  Write-Host ("free_mem={0}% (~{1}MB) metric={2}" -f (Get-FreePct), (Get-FreeMB), $CT_MEM_METRIC)
  if (Watchdog-Running) { Write-Host ("watchdog: RUNNING (pid {0})" -f (Get-Content $CT_WATCHDOG_PID)) }
  else { Write-Host ("watchdog: stopped (task state: {0})" -f (Task-State)) }
  $paused = 0; if (Test-Path $CT_PAUSED_LIST) { $paused = @(Get-Content $CT_PAUSED_LIST | Where-Object { $_ }).Count }
  Write-Host "currently paused: $paused process(es)"
  Write-Host ("claude descendants: {0}" -f (@(Get-ClaudeDescendants)).Count)
}

function Cmd-Doctor {
  Write-Host 'claude-throttle doctor'
  Write-Host '  os:     windows'
  Write-Host "  root:   $PSScriptRoot"
  Write-Host "  config: $CT_CONFIG_FILE"
  Write-Host "  state:  $CT_STATE_DIR"
  Write-Host ''
  Write-Host 'Environment:'
  Write-Host ("  PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
  Write-Host ("  LanguageMode: {0}" -f $ExecutionContext.SessionState.LanguageMode)
  if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { Warn 'not FullLanguage — Add-Type/suspend may be blocked (watchdog degraded; hook still works)' }
  if (Suspend-Available) { Ok 'process suspend/resume available (NtSuspendProcess)' } else { Bad 'suspend API unavailable — watchdog cannot pause processes' }
  $sh = Resolve-InnerShell
  Write-Host ("  inner shell: {0}" -f $sh.exe)
  Write-Host ''
  Write-Host 'Configuration:'
  if ($CT_DYNAMIC -eq 1) {
    Write-Host ("  enabled={0} gate={1} concurrency=dynamic[{2}..{3}] now={4} priority={5}" -f `
      $CT_ENABLED, $CT_GATE_MODE, $CT_MIN_CONCURRENCY, $CT_MAX_CONCURRENCY, (Get-EffectiveConcurrency), $CT_PRIORITY_CLASS)
    Write-Host ("  (~1 slot per {0}MB free RAM, capped at {1} cores)" -f $CT_MEM_PER_SLOT_MB, (Get-Cores))
  } else {
    Write-Host ("  enabled={0} gate={1} concurrency=fixed:{2}" -f $CT_ENABLED, $CT_GATE_MODE, $CT_MAX_CONCURRENCY)
  }
  Write-Host ("  watchdog: interval={0}s crit_free={1}% resume_free={2}% pause_count={3} rss_floor={4}MB metric={5}" -f `
    $CT_WATCHDOG_INTERVAL, $CT_CRIT_FREE_PCT, $CT_RESUME_FREE_PCT, $CT_PAUSE_COUNT, $CT_MIN_PAUSE_RSS_MB, $CT_MEM_METRIC)
  if (Test-Path $CT_CONFIG_FILE) { Ok 'config file present' } else { Warn 'no config file — using built-in defaults' }
  Write-Host ''
  Write-Host 'Installation:'
  if (Test-Path $CT_INSTALL_PS1) { Ok "installed at $CT_INSTALL_PS1" } else { Warn 'not installed (run: install)' }
  if (Hook-Installed) { Ok "PreToolUse hook installed in $CT_SETTINGS" } else { Warn 'hook NOT installed (run: install)' }
  $ts = Task-State; if ($ts) { Ok "scheduled task present (state: $ts)" } else { Warn 'scheduled task not registered' }
  if (Watchdog-Running) { Ok ("watchdog running (pid {0})" -f (Get-Content $CT_WATCHDOG_PID)) } else { Warn 'watchdog not running' }
  Write-Host ''
  Write-Host 'Live metrics:'
  Write-Host ("  free memory: {0}% (~{1}MB)   cores: {2}" -f (Get-FreePct), (Get-FreeMB), (Get-Cores))
}

# ============================================================================
# install / uninstall / update
# ============================================================================
function Cmd-Install {
  Write-Host 'Installing claude-throttle (os: windows)…'
  $srcDir = Split-Path $PSCommandPath -Parent      # the windows/ folder of the checkout
  if (-not (Test-Path $CT_CONFIG_FILE)) {
    Copy-Item (Join-Path $srcDir 'config.example.ps1') $CT_CONFIG_FILE; Ok "wrote $CT_CONFIG_FILE"
  } else { Warn "config already exists, keeping it: $CT_CONFIG_FILE" }

  $destWin = Join-Path $CT_INSTALL_DIR 'windows'
  if ((Resolve-Path $srcDir).Path -ne (Resolve-Path -LiteralPath $destWin -ErrorAction SilentlyContinue).Path) {
    if (Test-Path $destWin) { Remove-Item -Recurse -Force $destWin }
    New-Item -ItemType Directory -Force -Path $destWin | Out-Null
    Copy-Item (Join-Path $srcDir '*') $destWin -Recurse -Force
    Ok "copied tool to $destWin"
    Set-Content -LiteralPath $CT_SOURCE_PATH -Value $srcDir
  } else { Warn 'running from install dir already; refreshing in place' }

  Install-Hook
  Task-Register
  Start-Sleep -Seconds 2
  Write-Host ''
  Cmd-Doctor
  Write-Host ''
  Write-Host 'Done. Restart Claude Code so it picks up the new hook.'
}
function Cmd-Uninstall {
  Write-Host 'Uninstalling claude-throttle (os: windows)…'
  Task-Unregister
  Remove-Hook
  if (Test-Path $CT_INSTALL_DIR) { Remove-Item -Recurse -Force $CT_INSTALL_DIR; Ok "removed $CT_INSTALL_DIR" }
  Warn "kept config ($CT_CONFIG_DIR) and logs ($CT_STATE_DIR) — delete manually if desired"
  Write-Host 'Done. Restart Claude Code.'
}
function Cmd-Update {
  $srcDir = Split-Path $PSCommandPath -Parent
  $destWin = Join-Path $CT_INSTALL_DIR 'windows'
  if ((Resolve-Path $srcDir).Path -ne (Resolve-Path -LiteralPath $destWin -ErrorAction SilentlyContinue).Path) {
    Write-Host "Updating claude-throttle from $srcDir …"; Cmd-Install; return
  }
  $src = $null; if (Test-Path $CT_SOURCE_PATH) { $src = (Get-Content $CT_SOURCE_PATH -Raw).Trim() }
  if ($src -and (Test-Path (Join-Path $src 'claude-throttle.ps1'))) {
    Write-Host "Updating claude-throttle from $src …"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'claude-throttle.ps1') install
    return
  }
  Bad "Can't find your source repo to update from."
  Write-Host "Run windows\install.ps1 from your checkout once; after that 'update' works anywhere."
}

function Cmd-Help {
  Get-Content $PSCommandPath | Where-Object { $_ -match '^\s*Subcommands:' } | ForEach-Object { $_.Trim() }
  Write-Host 'Usage: powershell -NoProfile -ExecutionPolicy Bypass -File claude-throttle.ps1 <command>'
  Write-Host 'Commands: hook | run | watchdog | status | doctor | install | uninstall | update | help'
}

# ============================================================================
# dispatch
# ============================================================================
switch ($Command) {
  'hook'      { Cmd-Hook }
  'run'       { exit (Cmd-Run $Rest) }
  'watchdog'  { Cmd-Watchdog }
  'status'    { Cmd-Status }
  'doctor'    { Cmd-Doctor }
  'install'   { Cmd-Install }
  'uninstall' { Cmd-Uninstall }
  'update'    { Cmd-Update }
  default     { Cmd-Help }
}
