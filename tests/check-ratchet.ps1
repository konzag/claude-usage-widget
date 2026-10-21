<#
.SYNOPSIS
    Coverage ratchet for the test suite (TEST-STANDARD v1, test-map variant): MIN_PASS in tests/run-tests.ps1
    may not go down and the UNTESTED count in tests/TEST-MAP.txt may not grow compared with the base ref,
    unless the head commit carries the trailer "Coverage-Floor-Lowered-By: owner". Exit code 0 = ok.
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\check-ratchet.ps1 -BaseRef origin/main
#>
param([string]$BaseRef = 'origin/main')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot

function Get-MinPass {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?m)^\$MIN_PASS\s*=\s*(\d+)\s*$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}
function Get-UntestedCount {
    param([string]$Text)
    return ([regex]::Matches($Text, '(?m)^\s*[\w-]+\s*->\s*UNTESTED\s*$')).Count
}
function Get-BaseFile {
    # File content at the base ref, or $null when it does not exist there.
    param([string]$RelPath)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -C $root show ($BaseRef + ':' + $RelPath) 2>$null }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (@($out) -join "`n")
}

$headMin = Get-MinPass ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-tests.ps1')))
$headUntested = Get-UntestedCount ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TEST-MAP.txt')))
$baseRun = Get-BaseFile 'tests/run-tests.ps1'
$baseMap = Get-BaseFile 'tests/TEST-MAP.txt'
$baseMin = 0
if ($null -ne $baseRun) { $baseMin = Get-MinPass $baseRun }
$baseUntested = $null
if ($null -ne $baseMap) { $baseUntested = Get-UntestedCount $baseMap }

$body = (& git -C $root log -1 --format=%B) -join "`n"
$override = $body -match '(?m)^Coverage-Floor-Lowered-By:\s*owner\s*$'

$problems = @()
if ($headMin -lt $baseMin) { $problems += ('MIN_PASS went down: {0} -> {1}' -f $baseMin, $headMin) }
if ($null -ne $baseUntested -and $headUntested -gt $baseUntested) { $problems += ('UNTESTED grew: {0} -> {1}' -f $baseUntested, $headUntested) }
if ($headMin -le 0) { $problems += 'MIN_PASS is not set in tests/run-tests.ps1' }

Write-Host ('RATCHET base={0} MIN_PASS {1} -> {2}, UNTESTED {3} -> {4}' -f $BaseRef, $baseMin, $headMin, $(if ($null -eq $baseUntested) { 'n/a' } else { $baseUntested }), $headUntested)
if ($problems.Count -eq 0) { Write-Host 'RATCHET OK'; exit 0 }
foreach ($p in $problems) { Write-Host ('RATCHET ' + $p) }
if ($override) { Write-Host 'RATCHET OK (lowered by owner trailer)'; exit 0 }
Write-Host 'RATCHET FAIL (add the trailer "Coverage-Floor-Lowered-By: owner" only with the owner''s approval)'
exit 1
