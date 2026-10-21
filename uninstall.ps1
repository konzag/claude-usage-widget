<#
.SYNOPSIS
    Removes the Claude usage widget for the current user.

.DESCRIPTION
    Stops the widget, removes the Startup and Start Menu shortcuts and the program files in
    %LOCALAPPDATA%\ClaudeUsageWidget. Settings, history and log stay unless -Purge is given.
    Claude Code's credentials are never touched.

.PARAMETER Purge
    Also delete settings.json, history.csv, last.json and the logs (the whole folder).
#>
[CmdletBinding()]
param([switch]$Purge)

$ErrorActionPreference = 'Stop'
$dst = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
$fail = 0
Import-Module (Join-Path (Join-Path $PSScriptRoot 'src') 'UsageCore.psm1') -Force -DisableNameChecking

foreach ($p in (Get-WidgetProcess)) {
    Stop-Process -Id $p.ProcessId -Force
    Write-Host ('INFO stopped widget (pid {0})' -f $p.ProcessId)
}
Start-Sleep -Milliseconds 500
if (@(Get-WidgetProcess).Count -eq 0) { Write-Host 'PASS no widget running' } else { Write-Host 'FAIL widget still running'; $fail++ }

foreach ($lnk in @((Get-StartupShortcutPath), (Get-StartMenuShortcutPath))) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    if (Test-Path -LiteralPath $lnk) { Write-Host ('FAIL still present: {0}' -f $lnk); $fail++ } else { Write-Host ('PASS removed {0}' -f $lnk) }
}

if (Test-Path -LiteralPath $dst) {
    if ($Purge) {
        Remove-Item -LiteralPath $dst -Recurse -Force
        if (Test-Path -LiteralPath $dst) { Write-Host 'FAIL data folder still present'; $fail++ } else { Write-Host ('PASS removed {0}' -f $dst) }
    }
    else {
        foreach ($f in @('ClaudeUsageWidget.ps1', 'UsageCore.psm1')) {
            $fp = Join-Path $dst $f
            if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force }
        }
        Write-Host ('PASS program files removed; data kept in {0} (use -Purge to delete it)' -f $dst)
    }
}

if ($fail -gt 0) { Write-Host ('UNINSTALL FAIL ({0})' -f $fail); exit 1 }
Write-Host 'UNINSTALL OK'
exit 0
