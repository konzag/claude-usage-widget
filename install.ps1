<#
.SYNOPSIS
    Installs or updates the Claude usage widget for the current user from this repo checkout.

.DESCRIPTION
    1. Stops a running widget.
    2. Copies src\ to %LOCALAPPDATA%\ClaudeUsageWidget (settings, history and log there are kept).
    3. Verifies the copy by SHA-256.
    4. Creates the Start Menu shortcut and (unless -NoAutostart) the Startup shortcut.
    5. Starts the widget (unless -NoStart) and checks that it is running.
    Re-run after `git pull` to update. Every step prints PASS or FAIL; exit code 0 = all passed.

.PARAMETER NoAutostart
    Do not start with Windows (removes an existing Startup shortcut).

.PARAMETER NoStart
    Install only; do not start the widget now.
#>
[CmdletBinding()]
param(
    [switch]$NoAutostart,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$dst = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
$files = @('ClaudeUsageWidget.ps1', 'UsageCore.psm1')
$fail = 0

Import-Module (Join-Path $src 'UsageCore.psm1') -Force -DisableNameChecking

# 1. Stop a running widget (it holds no locks on the files, but it must reload the new code)
$running = Get-WidgetProcess
foreach ($p in $running) {
    Stop-Process -Id $p.ProcessId -Force
    Write-Host ('INFO stopped running widget (pid {0})' -f $p.ProcessId)
}
if ($running.Count -gt 0) { Start-Sleep -Milliseconds 800 }

# 2. Copy program files
[void][IO.Directory]::CreateDirectory($dst)
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dst $f) -Force
}

# 3. Verify the copy
foreach ($f in $files) {
    $a = (Get-FileHash -LiteralPath (Join-Path $src $f) -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath (Join-Path $dst $f) -Algorithm SHA256).Hash
    if ($a -eq $b) { Write-Host ('PASS copied {0} ({1})' -f $f, $a.Substring(0, 12)) }
    else { Write-Host ('FAIL copy mismatch for {0}' -f $f); $fail++ }
}
if ($fail -gt 0) { Write-Host 'FAIL install aborted'; exit 1 }

# 4. Shortcuts
$target = Join-Path $dst 'ClaudeUsageWidget.ps1'
$menuLnk = Get-StartMenuShortcutPath
New-WidgetShortcut -ShortcutPath $menuLnk -ScriptPath $target
if (Test-Path -LiteralPath $menuLnk) { Write-Host ('PASS Start Menu shortcut: {0}' -f $menuLnk) } else { Write-Host 'FAIL Start Menu shortcut'; $fail++ }

$startLnk = Get-StartupShortcutPath
if ($NoAutostart) {
    if (Test-Path -LiteralPath $startLnk) { Remove-Item -LiteralPath $startLnk -Force }
    Write-Host 'PASS autostart off'
}
else {
    New-WidgetShortcut -ShortcutPath $startLnk -ScriptPath $target
    if (Test-Path -LiteralPath $startLnk) { Write-Host ('PASS autostart shortcut: {0}' -f $startLnk) } else { Write-Host 'FAIL autostart shortcut'; $fail++ }
}

# 5. Start and check
if (-not $NoStart) {
    $spec = Get-WidgetLaunchSpec -ScriptPath $target
    Start-Process -FilePath $spec.FilePath -ArgumentList $spec.Arguments -WorkingDirectory $spec.WorkingDirectory
    $ok = $null
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
        Start-Sleep -Milliseconds 500
        $ok = @(Get-WidgetProcess) | Select-Object -First 1
    }
    if ($ok) { Write-Host ('PASS widget running (pid {0})' -f $ok.ProcessId) }
    else { Write-Host ('FAIL widget is not running; see {0}' -f (Join-Path $dst 'widget.log')); $fail++ }
}

if ($fail -gt 0) { Write-Host ('INSTALL FAIL ({0})' -f $fail); exit 1 }
Write-Host 'INSTALL OK'
exit 0
