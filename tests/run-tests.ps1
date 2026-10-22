<#
.SYNOPSIS
    Dependency-free tests for src/UsageCore.psm1 (no Pester needed).
    Runs on Windows PowerShell 5.1 and PowerShell 7+. Exit code 0 = all passed.
    Known app bugs are pinned with Assert-KnownBug (counted as xfail; an unexpected pass fails the run).
    CUW_SKIP_SNAPSHOT=1 skips the slow snapshot group (counted as skip; the MIN_PASS floor then fails).
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\run-tests.ps1
#>
# Coverage ratchet: the run fails when fewer assertions pass. CI (tests/check-ratchet.ps1) refuses a lower
# value than on origin/main unless the head commit has the trailer "Coverage-Floor-Lowered-By: owner".
$MIN_PASS = 340
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $root 'src') 'UsageCore.psm1') -Force -DisableNameChecking
$fixtures = Join-Path $PSScriptRoot 'fixtures'

$script:Pass = 0
$script:Fail = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($null -eq $Expected -and $null -eq $Actual) { $script:Pass++; return }
    if ($null -ne $Expected -and $null -ne $Actual -and ([string]$Expected) -ceq ([string]$Actual)) { $script:Pass++; return }
    $script:Fail++
    Write-Host ('FAIL {0}: expected <{1}> got <{2}>' -f $Name, $Expected, $Actual)
}
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++ } else { $script:Fail++; Write-Host ('FAIL ' + $Name) }
}
$script:XFail = 0
$script:Skip = 0
function Assert-KnownBug {
    # $Condition is the CORRECT behaviour. While the bug exists it is false (xfail); once fixed, this fails
    # so the marker gets removed together with the fix.
    param([bool]$Condition, [string]$Name, [string]$Bug)
    if ($Condition) { $script:Fail++; Write-Host ('FAIL {0}: passes now, remove the {1} marker' -f $Name, $Bug) }
    else { $script:XFail++; Write-Host ('XFAIL {0} ({1})' -f $Name, $Bug) }
}
function Skip-Test {
    param([string]$Name, [string]$Why)
    $script:Skip++
    Write-Host ('SKIP {0}: {1}' -f $Name, $Why)
}
function Invoke-Group {
    # An exception inside a group counts as one failure instead of aborting the whole run.
    param([string]$Name, [scriptblock]$Body)
    try { & $Body }
    catch { $script:Fail++; Write-Host ('FAIL {0}: threw {1}' -f $Name, $_.Exception.Message) }
}
function Test-Utf8Bom {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}
function U { param([string]$Iso) return [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture) }
function Hm { param($Dto) return $Dto.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm', [Globalization.CultureInfo]::InvariantCulture) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cuw-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)
try {
    # --- API parsing: live response shape (2026-10-20) ---
    $m = ConvertFrom-UsageResponse -Json ([IO.File]::ReadAllText((Join-Path $fixtures 'usage-2026-10-20.json')))
    Assert-Equal 6 $m.Session.Percent 'live: session percent'
    Assert-Equal '2026-10-20T16:10' (Hm $m.Session.ResetsAt) 'live: session reset'
    Assert-Equal 2 $m.Week.Percent 'live: week percent'
    Assert-Equal '2026-10-26T14:00' (Hm $m.Week.ResetsAt) 'live: week reset'
    Assert-Equal 1 @($m.Scoped).Count 'live: one scoped limit'
    Assert-Equal 'Fable' $m.Scoped[0].Label 'live: scoped label'
    Assert-Equal 50 $m.Scoped[0].AllowancePct 'live: scoped allowance'
    Assert-Equal 168 $m.Scoped[0].WindowHours 'live: scoped window'
    Assert-Equal 4 @($m.Breakdown).Count 'live: breakdown rows'
    Assert-Equal 'cowork' $m.Breakdown[2].Key 'live: breakdown key'
    Assert-Equal 80 $m.Breakdown[2].Percent 'live: breakdown percent'
    Assert-Equal '2026-10-19T14:00' (Hm $m.WeekStartedAt) 'live: week started'
    Assert-True ($null -eq $m.Spend) 'live: spend disabled'

    # --- API parsing: older shape without "limits" ---
    $l = ConvertFrom-UsageResponse -Json ([IO.File]::ReadAllText((Join-Path $fixtures 'usage-legacy.json')))
    Assert-Equal 41 $l.Session.Percent 'legacy: session'
    Assert-Equal 77 $l.Week.Percent 'legacy: week'
    Assert-Equal 1 @($l.Scoped).Count 'legacy: opus only'
    Assert-Equal 'Opus' $l.Scoped[0].Label 'legacy: opus label'
    Assert-Equal '2026-10-26T14:00' (Hm $l.Scoped[0].ResetsAt) 'legacy: opus reset falls back to week'

    # --- API parsing: empty / spend enabled ---
    $e = ConvertFrom-UsageResponse -Json '{}'
    Assert-True ($null -eq $e.Session -and $null -eq $e.Week) 'empty: no limits'
    Assert-Equal 0 @($e.Scoped).Count 'empty: no scoped'
    $sp = ConvertFrom-UsageResponse -Json '{"spend":{"enabled":true,"used":{"amount_minor":1234,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2}}}'
    Assert-Equal 12.34 $sp.Spend.Used 'spend: used'
    Assert-Equal 50 $sp.Spend.Limit 'spend: limit'
    Assert-Equal 'USD' $sp.Spend.Currency 'spend: currency'

    # --- Dates from PowerShell 7 ConvertFrom-Json arrive as [datetime] ---
    $dtU = [datetime]::SpecifyKind([datetime]'2026-10-20 16:10:00', [DateTimeKind]::Utc)
    Assert-Equal '2026-10-20T16:10' (Hm (ConvertTo-UsageDate $dtU)) 'date: utc datetime'
    $dtL = $dtU.ToLocalTime()
    Assert-Equal '2026-10-20T16:10' (Hm (ConvertTo-UsageDate $dtL)) 'date: local datetime'
    Assert-True ($null -eq (ConvertTo-UsageDate '')) 'date: empty string'
    Assert-True ($null -eq (ConvertTo-UsageDate 'not a date')) 'date: garbage'
    $iso = 'yyyy-MM-ddTHH:mm:ss.fff'
    Assert-Equal '2026-10-20T16:10:00.000' (Get-RoundedMinute (U '2026-10-20T16:09:59.8Z')).ToString($iso) 'round: jitter below'
    Assert-Equal '2026-10-20T16:10:00.000' (Get-RoundedMinute (U '2026-10-20T16:10:00.231508Z')).ToString($iso) 'round: jitter above'
    Assert-Equal '2026-10-20T16:10:00.000' (Get-RoundedMinute (U '2026-10-20T19:10:00.2+03:00')).ToString($iso) 'round: offset normalised to UTC'
    Assert-True ($null -eq (Get-RoundedMinute $null)) 'round: null'
    $jit = ConvertFrom-UsageResponse -Json '{"limits":[{"kind":"session","percent":15,"resets_at":"2026-10-20T16:09:59.612+00:00"}]}'
    Assert-Equal '2026-10-20T16:10:00.000' $jit.Session.ResetsAt.ToString($iso) 'round: parser rounds resets_at'

    # --- Credentials (fake token, temp file) ---
    $credPath = Join-Path $tmp 'creds.json'
    $exp = [DateTimeOffset]::UtcNow.AddHours(3)
    [IO.File]::WriteAllText($credPath, ('{"claudeAiOauth":{"accessToken":"test-token-not-real","refreshToken":"x","expiresAt":' + $exp.ToUnixTimeMilliseconds() + ',"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}'))
    $c = Read-ClaudeCredential -Path $credPath
    Assert-True $c.Ok 'cred: ok'
    Assert-Equal 'test-token-not-real' $c.AccessToken 'cred: token'
    Assert-Equal (Hm $exp) (Hm $c.ExpiresAt) 'cred: expiry'
    Assert-Equal 'Max 5x' (Get-PlanLabel $c.SubscriptionType $c.RateLimitTier) 'cred: plan label'
    Assert-Equal 'missing' (Read-ClaudeCredential -Path (Join-Path $tmp 'nope.json')).Reason 'cred: missing'
    [IO.File]::WriteAllText((Join-Path $tmp 'bad.json'), '{not json')
    Assert-Equal 'unreadable' (Read-ClaudeCredential -Path (Join-Path $tmp 'bad.json')).Reason 'cred: unreadable'
    [IO.File]::WriteAllText((Join-Path $tmp 'notok.json'), '{"claudeAiOauth":{}}')
    Assert-Equal 'notoken' (Read-ClaudeCredential -Path (Join-Path $tmp 'notok.json')).Reason 'cred: no token'
    Assert-Equal 'Max 20x' (Get-PlanLabel 'max' 'default_claude_max_20x') 'plan: 20x'
    Assert-Equal 'Pro' (Get-PlanLabel 'pro' '') 'plan: pro'
    Assert-Equal '' (Get-PlanLabel '' '') 'plan: unknown'

    # --- Window deltas ---
    $t0 = U '2026-10-14T10:00:00Z'
    Assert-Equal 4 (Get-WindowDelta 10 $t0.AddHours(3) 14 $t0) 'delta: increase'
    Assert-Equal 0 (Get-WindowDelta 14 $t0.AddHours(3) 12 $t0) 'delta: drop without reset'
    Assert-Equal 3 (Get-WindowDelta 80 $t0 3 $t0.AddMinutes(5)) 'delta: window rolled over'
    Assert-Equal 0 (Get-WindowDelta $null $null 5 $t0) 'delta: unknown previous'
    Assert-Equal 0 (Get-WindowDelta 5 $null $null $t0) 'delta: unknown current'

    # --- Increments, sums, buckets (fixed clock) ---
    $now = U '2026-10-14T12:30:00Z'
    $sr1 = U '2026-10-14T11:00:00Z'
    $sr2 = U '2026-10-14T16:00:00Z'
    $wr = U '2026-10-19T14:00:00Z'
    $samples = New-Object System.Collections.Generic.List[object]
    $samples.Add(@{ Ts = (U '2026-10-14T09:00:00Z'); Session = 10; SessionReset = $sr1; Week = 20; WeekReset = $wr })
    $samples.Add(@{ Ts = (U '2026-10-14T10:00:00Z'); Session = 30; SessionReset = $sr1; Week = 22; WeekReset = $wr })
    $samples.Add(@{ Ts = (U '2026-10-14T11:05:00Z'); Session = 5; SessionReset = $sr2; Week = 23; WeekReset = $wr })
    $samples.Add(@{ Ts = (U '2026-10-14T12:00:00Z'); Session = 9; SessionReset = $sr2; Week = 24; WeekReset = $wr })
    $samples.Add(@{ Ts = (U '2026-10-14T12:25:00Z'); Session = 12; SessionReset = $sr2; Week = 25; WeekReset = $wr })
    $inc = Get-UsageIncrements -Samples $samples
    Assert-Equal 4 $inc.Count 'inc: count'
    Assert-Equal 20 $inc[0].Session 'inc: session +20'
    Assert-Equal 5 $inc[1].Session 'inc: session after reset counts from zero'
    Assert-True ($inc[1].Gap) 'inc: 65 min apart is a gap'
    Assert-True ($inc[2].Gap) 'inc: 55 min apart is a gap (threshold 30)'
    Assert-True (-not $inc[3].Gap) 'inc: 25 min apart is not a gap'
    Assert-Equal 7 (Get-IncrementSum -Increments $inc -Since $now.AddHours(-1) -Field 'Session') 'sum: last hour session'
    Assert-Equal 5 (Get-IncrementSum -Increments $inc -Since (U '2026-10-14T00:00:00Z') -Field 'Week') 'sum: week since midnight utc'

    $hb = Get-HourlyBuckets -Increments $inc -Now $now -Hours 24
    Assert-Equal 24 $hb.Count 'hours: 24 buckets'
    Assert-Equal 7 ($hb[23].Session) 'hours: current hour holds 12:00 and 12:25'
    Assert-Equal 5 ($hb[22].Session) 'hours: 11:00 hour'
    Assert-Equal 20 ($hb[21].Session) 'hours: 10:00 hour'
    Assert-Equal 2 ($hb[23].Samples) 'hours: samples in current hour'
    Assert-True ($hb[22].HasGap) 'hours: gap flag'
    $db = Get-DailyBuckets -Increments $inc -Now $now -Days 7
    Assert-Equal 7 $db.Count 'days: 7 buckets'
    Assert-Equal 5 ($db[6].Week) 'days: today week total'
    Assert-Equal 4 ($db[6].Samples) 'days: today samples'

    # --- History file round trip and pruning ---
    $hp = Join-Path $tmp 'history.csv'
    foreach ($s in $samples) { Add-UsageHistorySample -Path $hp -Sample $s }
    $back = Read-UsageHistory -Path $hp
    Assert-Equal 5 $back.Count 'history: 5 rows back'
    Assert-Equal '2026-10-14T11:05' (Hm $back[2].Ts) 'history: timestamp'
    Assert-Equal 5 $back[2].Session 'history: session value'
    Assert-Equal '2026-10-14T16:00' (Hm $back[2].SessionReset) 'history: session reset'
    Assert-Equal 'ts,session,session_reset,week,week_reset' ([IO.File]::ReadAllLines($hp)[0]) 'history: header'
    $since = Read-UsageHistory -Path $hp -Since (U '2026-10-14T11:00:00Z')
    Assert-Equal 3 $since.Count 'history: since filter'
    Assert-Equal 3 (Compress-UsageHistory -Path $hp -KeepSince (U '2026-10-14T11:00:00Z')) 'history: prune keeps 3'
    Assert-Equal 4 ([IO.File]::ReadAllLines($hp)).Count 'history: file has header + 3'
    [IO.File]::AppendAllText($hp, "garbage line`n,,,`n")
    Assert-Equal 3 (Read-UsageHistory -Path $hp).Count 'history: bad lines skipped'
    $bytes = [IO.File]::ReadAllBytes($hp)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'history: no BOM'

    # --- Formatting (Greek UI) ---
    Assert-Equal 'τώρα' (Format-UsageSpan ([TimeSpan]::Zero)) 'span: zero'
    Assert-Equal '<1λ' (Format-UsageSpan ([TimeSpan]::FromSeconds(30))) 'span: seconds'
    Assert-Equal '12λ' (Format-UsageSpan ([TimeSpan]::FromMinutes(12.7))) 'span: minutes'
    Assert-Equal '4ω 46λ' (Format-UsageSpan (New-TimeSpan -Hours 4 -Minutes 46)) 'span: hours'
    Assert-Equal '6ημ 1ω' (Format-UsageSpan (New-TimeSpan -Days 6 -Hours 1 -Minutes 59)) 'span: days'
    Assert-Equal '—' (Format-UsagePercent $null) 'pct: null'
    Assert-Equal '0%' (Format-UsagePercent 0) 'pct: zero'
    Assert-Equal '<1%' (Format-UsagePercent 0.4) 'pct: below one'
    Assert-Equal '7%' (Format-UsagePercent 6.5) 'pct: rounds half up'
    Assert-Equal '0%' (Format-UsageDelta 0) 'delta fmt: zero'
    Assert-Equal '+<1%' (Format-UsageDelta 0.5) 'delta fmt: small'
    Assert-Equal '+3%' (Format-UsageDelta 3) 'delta fmt: three'

    $localNow = New-Object DateTimeOffset((New-Object DateTime(2026, 10, 14, 14, 0, 0, [DateTimeKind]::Local)))
    Assert-Equal '17:00' (Format-ResetTime $localNow.AddHours(3) $localNow) 'reset: same day'
    Assert-Equal 'αύριο 14:00' (Format-ResetTime $localNow.AddDays(1) $localNow) 'reset: tomorrow'
    $later = $localNow.AddDays(5)
    Assert-Equal ((Get-DayShort $later.DayOfWeek) + ' 19/10 14:00') (Format-ResetTime $later $localNow) 'reset: later'
    Assert-Equal 'Δε' (Get-DayShort ([DayOfWeek]::Monday)) 'day: monday short'
    Assert-Equal 'Τρίτη 20/10' (Format-LongDate (New-Object DateTime(2026, 10, 20))) 'day: long date'
    Assert-True ($null -eq (Format-ResetTime $null $localNow) -or (Format-ResetTime $null $localNow) -eq '') 'reset: null'

    # --- Levels, pace, allowance ---
    Assert-Equal 0 (Get-UsageLevel 50 'normal') 'level: normal'
    Assert-Equal 1 (Get-UsageLevel 80 'normal') 'level: warning by threshold'
    Assert-Equal 2 (Get-UsageLevel 95 '') 'level: critical by threshold'
    Assert-Equal 1 (Get-UsageLevel 10 'warning') 'level: warning by api'
    Assert-Equal 2 (Get-UsageLevel 10 'critical') 'level: critical by api'
    $rs = $now.AddHours(2.5)
    Assert-Equal 0.5 (Get-WindowElapsedFraction -ResetsAt $rs -WindowHours 5 -Now $now) 'pace: half of 5h'
    Assert-Equal 1 (Get-WindowElapsedFraction -ResetsAt $now.AddHours(-1) -WindowHours 5 -Now $now) 'pace: clamps at 1'
    Assert-True ($null -eq (Get-WindowElapsedFraction -ResetsAt $null -WindowHours 5 -Now $now)) 'pace: no reset'
    $wk = Get-WindowElapsedFraction -ResetsAt (U '2026-10-26T14:00:00Z') -WindowHours 168 -Now (U '2026-10-20T14:00:00Z') -StartedAt (U '2026-10-19T14:00:00Z')
    Assert-Equal ([math]::Round(1.0 / 7.0, 6)) ([math]::Round($wk, 6)) 'pace: one day of seven'
    Assert-Equal 24.5 (Get-DailyAllowance -WeekPercent 2 -ResetsAt $now.AddDays(4) -Now $now) 'allowance: 98 over 4 days'
    Assert-Equal 60 (Get-DailyAllowance -WeekPercent 40 -ResetsAt $now.AddHours(5) -Now $now) 'allowance: last day'
    Assert-True ($null -eq (Get-DailyAllowance -WeekPercent 40 -ResetsAt $now.AddHours(-1) -Now $now)) 'allowance: past reset'

    # --- Midnight and demo data ---
    $mid = Get-LocalMidnight $localNow
    Assert-Equal 0 $mid.ToLocalTime().Hour 'midnight: hour 0'
    Assert-Equal 14 $mid.ToLocalTime().Day 'midnight: same day'
    $demo = New-DemoState -Scenario 'normal' -Now $now
    Assert-True ($demo.Samples.Count -gt 2000) 'demo: a week of 5-minute samples'
    Assert-True ($null -ne $demo.Model.Session -and $null -ne $demo.Model.Week) 'demo: model has limits'
    $demoInc = Get-UsageIncrements -Samples $demo.Samples
    Assert-True ((Get-IncrementSum -Increments $demoInc -Since $now.AddDays(-7) -Field 'Week') -gt 0) 'demo: has weekly usage'
    $high = New-DemoState -Scenario 'high' -Now $now
    Assert-True ($high.Model.Week.Percent -gt $demo.Model.Week.Percent) 'demo: high uses more'
    Assert-Equal 0 (New-DemoState -Scenario 'empty' -Now $now).Samples.Count 'demo: empty has no history'
    $incI = [System.Collections.Generic.List[object]]::new()
    for ($k = 1; $k -lt $demo.Samples.Count; $k++) { $incI.Add((New-UsageIncrement -Prev $demo.Samples[$k - 1] -Cur $demo.Samples[$k])) }
    Assert-Equal $demoInc.Count $incI.Count 'incremental: same count as batch'
    Assert-Equal (Get-IncrementSum -Increments $demoInc -Since $now.AddDays(-7) -Field 'Week') (Get-IncrementSum -Increments $incI -Since $now.AddDays(-7) -Field 'Week') 'incremental: same weekly total as batch'
    $hbI = Get-HourlyBuckets -Increments $incI -Now $now -Hours 24
    $hbB = Get-HourlyBuckets -Increments $demoInc -Now $now -Hours 24
    Assert-Equal (($hbB | ForEach-Object { $_.Session }) -join ',') (($hbI | ForEach-Object { $_.Session }) -join ',') 'incremental: same hourly buckets'
    $empty = [System.Collections.Generic.List[object]]::new()
    Assert-Equal 0 (Get-IncrementSum -Increments $empty -Since $now.AddHours(-1) -Field 'Session') 'sum: empty list'
    Assert-Equal 24 (Get-HourlyBuckets -Increments $empty -Now $now -Hours 24).Count 'hours: empty list'

    # --- Notification area: tooltip text and ring ---
    $tn = U '2026-10-20T13:00:00Z'
    $tm = @{ Session = (New-UsageLimit 'session' 'Session' 16 $tn.AddHours(3) 'normal' 5); Week = (New-UsageLimit 'weekly_all' 'Εβδομάδα' 6 $tn.AddDays(6) 'normal' 168) }
    $warnSign = [string][char]0x26A0
    Assert-Equal ('Claude · Session 16% · reset {0} · Εβδ. 6%' -f (Format-ResetTime $tm.Session.ResetsAt $tn)) (Format-TrayText -Model $tm -Phase 'ok' -Now $tn) 'tray: normal text'
    $tt = Format-TrayText -Model $tm -Phase 'expired' -Now $tn
    Assert-True ($tt.StartsWith($warnSign + ' Claude · Session 16%') -and $tt.EndsWith(' · token έληξε')) 'tray: expired note with warning sign'
    Assert-Equal 'Claude · φόρτωση…' (Format-TrayText -Model $null -Phase 'init' -Now $tn) 'tray: no data yet'
    Assert-Equal ($warnSign + ' Claude · χωρίς σύνδεση') (Format-TrayText -Model $null -Phase 'offline' -Now $tn) 'tray: offline without data'
    $th = @{ Session = (New-UsageLimit 'session' 'Session' 100 $tn.AddDays(2) 'critical' 5); Week = (New-UsageLimit 'weekly_all' 'Εβδομάδα' 100 $tn.AddDays(6) 'critical' 168) }
    $tt = Format-TrayText -Model $th -Phase 'offline' -Now $tn
    Assert-True ($tt.Length -le 63) 'tray: long text fits 63 chars'
    Assert-Equal ($warnSign + ' Claude · Session 100% · Εβδ. 100% · χωρίς σύνδεση') $tt 'tray: reset dropped first when too long'
    Assert-True ((Format-TrayText -Model (New-DemoState -Scenario 'high' -Now $now).Model -Phase 'ok' -Now $now).Length -le 63) 'tray: demo high fits'
    $r = Get-TrayRing -Model $tm
    Assert-Equal 16 $r.Percent 'ring: higher of session and week'
    Assert-Equal 'Accent' $r.Color 'ring: normal colour'
    Assert-Equal 57.6 $r.Sweep 'ring: sweep'
    $r = Get-TrayRing -Model @{ Session = (New-UsageLimit 'session' 'Session' 30 $null '' 5); Week = (New-UsageLimit 'weekly_all' 'Εβδομάδα' 80 $null '' 168) }
    Assert-Equal 80 $r.Percent 'ring: week binds first'
    Assert-Equal '80|Warn' $r.Key 'ring: warning key'
    $r = Get-TrayRing -Model @{ Session = (New-UsageLimit 'session' 'Session' 130 $null '' 5); Week = $null }
    Assert-Equal 360 $r.Sweep 'ring: clamps at 100%'
    Assert-Equal 'Crit' $r.Color 'ring: critical colour'
    Assert-Equal 'none' (Get-TrayRing -Model $null).Key 'ring: no data'

    # --- Windows-only integration bits ---
    if ($env:windir) {
        $spec = Get-WidgetLaunchSpec -ScriptPath 'C:\x\ClaudeUsageWidget.ps1'
        Assert-True ($spec.FilePath -like '*\conhost.exe') 'launch: conhost'
        Assert-True ($spec.Arguments -like '--headless *-File "C:\x\ClaudeUsageWidget.ps1"') 'launch: args'
    }

    $widgetPath = Join-Path (Join-Path $root 'src') 'ClaudeUsageWidget.ps1'
    $widgetLines = [IO.File]::ReadAllLines($widgetPath, [Text.Encoding]::UTF8)

    # --- bom: every script is UTF-8 with BOM (5.1 reads BOM-less scripts as ANSI) ---
    Invoke-Group 'bom' {
        $scripts = @()
        foreach ($pair in @(@('src', '*.ps1'), @('src', '*.psm1'), @('.', '*.ps1'), @('tests', '*.ps1'))) {
            $scripts += @([IO.Directory]::GetFiles((Join-Path $root $pair[0]), $pair[1]))
        }
        Assert-True ($scripts.Count -ge 5) 'bom: found the scripts'
        foreach ($f in $scripts) { Assert-True (Test-Utf8Bom $f) ('bom: ' + $f.Substring($root.Length + 1)) }
    }

    # --- secret: the OAuth token is never logged, persisted or returned with other credential fields ---
    Invoke-Group 'secret' {
        $sinks = 'Write-Log|Write-Host|Write-Output|ConvertTo-Json|WriteAllText|AppendAllText|Out-File|Set-Content|Add-Content'
        $leaks = @($widgetLines | Where-Object { $_ -match 'AccessToken' -and $_ -match $sinks })
        Assert-Equal 0 $leaks.Count ('secret: token never logged ' + ($leaks -join ' | '))
        $bearer = -1
        for ($k = 0; $k -lt $widgetLines.Count; $k++) { if ($widgetLines[$k] -match "AuthenticationHeaderValue\('Bearer'") { $bearer = $k; break } }
        Assert-True ($bearer -ge 0) 'secret: bearer header line found'
        Assert-True ($bearer -ge 0 -and $widgetLines[$bearer + 1] -match '^\s*\$cred\.AccessToken\s*=\s*\$null\s*$') 'secret: token nulled after use'

        $credFixture = Join-Path $fixtures 'credentials-full.json'
        $fake = Get-JsonProp (Get-JsonProp ([IO.File]::ReadAllText($credFixture) | ConvertFrom-Json) 'claudeAiOauth') 'refreshToken'
        Assert-Equal 'test-refresh-token-not-real' $fake 'secret: fixture holds the fake refresh token'
        $credCopy = Join-Path $tmp 'credentials-full.json'
        [IO.File]::Copy($credFixture, $credCopy)
        [IO.File]::SetLastWriteTimeUtc($credCopy, [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc))
        $hashBefore = (Get-FileHash -LiteralPath $credCopy -Algorithm SHA256).Hash
        $timeBefore = [IO.File]::GetLastWriteTimeUtc($credCopy)
        $cf = Read-ClaudeCredential -Path $credCopy
        Assert-True $cf.Ok 'secret: full fixture reads ok'
        Assert-Equal 'AccessToken,ExpiresAt,FileTime,Ok,RateLimitTier,Reason,SubscriptionType' ((@($cf.Keys) | Sort-Object) -join ',') 'secret: credential fields'
        Assert-Equal 0 @($cf.Values | Where-Object { $null -ne $_ -and [string]$_ -eq $fake }).Count 'secret: refresh token not returned'
        Assert-Equal 0 @($cf.Values | Where-Object { $null -ne $_ -and [string]$_ -match 'user:inference' }).Count 'secret: scopes not returned'
        Assert-Equal $hashBefore (Get-FileHash -LiteralPath $credCopy -Algorithm SHA256).Hash 'secret: read-only content'
        Assert-Equal $timeBefore.Ticks ([IO.File]::GetLastWriteTimeUtc($credCopy)).Ticks 'secret: read-only mtime'
        Assert-Equal $timeBefore.Ticks $cf.FileTime.Ticks 'secret: FileTime is the file mtime'

        $soon = Join-Path $tmp 'soon.json'
        [IO.File]::WriteAllText($soon, '{"claudeAiOauth":{"accessToken":"test-token-not-real","expiresAt":"soon","subscriptionType":"pro"}}')
        $cs = Read-ClaudeCredential -Path $soon
        Assert-True $cs.Ok 'cred: bad expiresAt still ok'
        Assert-True ($null -eq $cs.ExpiresAt) 'cred: bad expiresAt -> null'
        Assert-Equal 'pro' $cs.SubscriptionType 'cred: bad expiresAt keeps plan'
    }

    # --- money: ConvertFrom-UsageMoney and spend parsing ---
    Invoke-Group 'money' {
        Assert-Equal 1234 (ConvertFrom-UsageMoney ('{"amount_minor":1234,"exponent":0}' | ConvertFrom-Json)) 'money: exponent 0'
        Assert-Equal 12.34 (ConvertFrom-UsageMoney ('{"amount_minor":1234}' | ConvertFrom-Json)) 'money: default exponent 2'
        Assert-True ($null -eq (ConvertFrom-UsageMoney ('{"exponent":2}' | ConvertFrom-Json))) 'money: no amount -> null'
        Assert-Equal 12.34 (ConvertFrom-UsageMoney ('{"amount_minor":"1234","exponent":2}' | ConvertFrom-Json)) 'money: amount as string'
        Assert-True ($null -eq (ConvertFrom-UsageMoney $null)) 'money: null'
        Assert-Equal 0.005 (ConvertFrom-UsageMoney ('{"amount_minor":5,"exponent":3}' | ConvertFrom-Json)) 'money: exponent 3'
        Assert-Equal 12.34 (ConvertFrom-UsageMoney @{ amount_minor = 1234; exponent = 2 }) 'money: hashtable input'
        $off = ConvertFrom-UsageResponse -Json '{"spend":{"enabled":false,"used":{"amount_minor":1234,"currency":"USD","exponent":2}}}'
        Assert-True ($null -eq $off.Spend) 'money: spend disabled -> null'
        $nc = ConvertFrom-UsageResponse -Json '{"spend":{"enabled":true,"used":{"amount_minor":100},"limit":{"amount_minor":500}}}'
        Assert-Equal '' $nc.Spend.Currency 'money: spend without currency -> empty'
        Assert-Equal 1 $nc.Spend.Used 'money: spend without currency used'
        Assert-Equal 5 $nc.Spend.Limit 'money: spend without currency limit'
        $nl = ConvertFrom-UsageResponse -Json '{"spend":{"enabled":true,"used":{"amount_minor":250,"currency":"EUR","exponent":2}}}'
        Assert-True ($null -eq $nl.Spend.Limit) 'money: spend without limit -> null limit'
    }

    # --- prune: Compress-UsageHistory retention edges ---
    Invoke-Group 'prune' {
        $keep = U '2026-10-14T11:00:00Z'
        $hdr = 'ts,session,session_reset,week,week_reset'
        $missing = Join-Path $tmp 'prune-missing.csv'
        Assert-Equal 0 (Compress-UsageHistory -Path $missing -KeepSince $keep) 'prune: missing file -> 0'
        Assert-True (-not (Test-Path -LiteralPath $missing)) 'prune: missing file not created'

        $old = Join-Path $tmp 'prune-old.csv'
        [IO.File]::WriteAllText($old, ($hdr + "`n2026-10-14T09:00:00Z,10,,20,`n2026-10-14T10:59:59Z,11,,21,`n"))
        Assert-Equal 0 (Compress-UsageHistory -Path $old -KeepSince $keep) 'prune: all old -> 0 kept'
        Assert-Equal $hdr (([IO.File]::ReadAllText($old)).TrimEnd("`n")) 'prune: all old -> header only'

        $edge = Join-Path $tmp 'prune-edge.csv'
        [IO.File]::WriteAllText($edge, ($hdr + "`n2026-10-14T10:00:00Z,1,,1,`n2026-10-14T11:00:00Z,2,,2,`n2026-10-14T12:00:00Z,3,,3,`n"))
        Assert-Equal 2 (Compress-UsageHistory -Path $edge -KeepSince $keep) 'prune: Ts == KeepSince kept'
        Assert-Equal '2026-10-14T11:00' (Hm (Read-UsageHistory -Path $edge)[0].Ts) 'prune: boundary row first'

        $mixed = Join-Path $tmp 'prune-mixed.csv'
        [IO.File]::WriteAllBytes($mixed, [byte[]](0xEF, 0xBB, 0xBF))
        [IO.File]::AppendAllText($mixed, ($hdr + "`n2026-10-14T09:00:00Z,1,,1,`ngarbage`n2026-10-14T12:00:00Z,5,2026-10-14T16:00:00Z,7,`nnot-a-date,1,,1,`n2026-10-14T12:05:00Z,6,,8,`n"))
        Assert-Equal 2 (Compress-UsageHistory -Path $mixed -KeepSince $keep) 'prune: malformed dropped, valid kept'
        $ml = [IO.File]::ReadAllLines($mixed)
        Assert-Equal 3 $ml.Count 'prune: header + 2 valid rows'
        Assert-Equal '2026-10-14T12:00:00Z,5,2026-10-14T16:00:00Z,7,' $ml[1] 'prune: valid row rewritten verbatim'
        Assert-True (@($ml | Where-Object { $_ -match 'garbage|not-a-date' }).Count -eq 0) 'prune: no malformed line left'
        Assert-True (-not (Test-Utf8Bom $mixed)) 'prune: rewritten file has no BOM'
        Assert-True (-not (Test-Path -LiteralPath ($mixed + '.tmp'))) 'prune: no temp file left'
    }

    # --- api edge: odd shapes from the usage endpoint (fixtures first) ---
    Invoke-Group 'api edge' {
        $ed = ConvertFrom-UsageResponse -Json ([IO.File]::ReadAllText((Join-Path $fixtures 'usage-edge-limits.json')))
        Assert-Equal 41 $ed.Session.Percent 'api edge: percent as string'
        Assert-True ($null -eq $ed.Session.ResetsAt) 'api edge: resets_at null -> null'
        Assert-Equal 130 $ed.Week.Percent 'api edge: 130 kept as reported (consumers clamp)'
        Assert-Equal 2 (Get-UsageLevel $ed.Week.Percent $ed.Week.Severity) 'api edge: 130 is critical'
        # Unknown kinds do not throw and do not touch session/week; they are shown as a scoped limit named by kind.
        Assert-Equal 1 @($ed.Scoped).Count 'api edge: unknown kind -> one scoped entry'
        Assert-Equal 'monthly_future_kind' $ed.Scoped[0].Label 'api edge: unknown kind labelled by kind'
        Assert-True ($null -eq $ed.Scoped[0].WindowHours) 'api edge: unknown kind has no window'
        Assert-Equal -5 $ed.Scoped[0].Percent 'api edge: -5 kept as reported'
        $lg = ConvertFrom-UsageResponse -Json ([IO.File]::ReadAllText((Join-Path $fixtures 'usage-legacy-edge.json')))
        Assert-Equal 41 $lg.Session.Percent 'api edge: utilization as string'
        Assert-True ($null -eq $lg.Session.ResetsAt) 'api edge: legacy resets_at null'
        Assert-Equal 130 $lg.Week.Percent 'api edge: utilization 130'
        Assert-Equal -5 $lg.Scoped[0].Percent 'api edge: utilization -5'
        Assert-Equal '2026-10-26T14:00' (Hm $lg.Scoped[0].ResetsAt) 'api edge: opus reset falls back to week'
        $rg = Get-TrayRing -Model @{ Session = $lg.Session; Week = $null }
        Assert-Equal 41 $rg.Percent 'api edge: ring from string percent'
        $rn = Get-TrayRing -Model @{ Session = (New-UsageLimit 'session' 'Session' -5 $null '' 5); Week = $null }
        Assert-Equal 0 $rn.Percent 'api edge: ring clamps -5 to 0'
        $nul = ConvertFrom-UsageResponse -Json '{"limits":[null,{"kind":"session","percent":null}]}'
        Assert-Equal 0 $nul.Session.Percent 'api edge: null entry skipped, null percent -> 0'
    }

    # --- history line: CSV row round trip ---
    Invoke-Group 'history line' {
        $hs = @{ Ts = (U '2026-10-14T12:00:00Z'); Session = 12.5; SessionReset = (U '2026-10-14T16:00:00Z'); Week = 3; WeekReset = (U '2026-10-19T14:00:00Z') }
        $line = ConvertTo-HistoryLine $hs
        Assert-Equal '2026-10-14T12:00:00Z,12.5,2026-10-14T16:00:00Z,3,2026-10-19T14:00:00Z' $line 'history line: format'
        $rt = ConvertFrom-HistoryLine $line
        Assert-Equal (Hm $hs.Ts) (Hm $rt.Ts) 'history line: ts round trip'
        Assert-Equal 12.5 $rt.Session 'history line: session round trip'
        Assert-Equal (Hm $hs.SessionReset) (Hm $rt.SessionReset) 'history line: session reset round trip'
        Assert-Equal 3 $rt.Week 'history line: week round trip'
        Assert-Equal (Hm $hs.WeekReset) (Hm $rt.WeekReset) 'history line: week reset round trip'
        $em = ConvertFrom-HistoryLine (ConvertTo-HistoryLine @{ Ts = (U '2026-10-14T12:00:00Z'); Session = $null; SessionReset = $null; Week = $null; WeekReset = $null })
        Assert-True ($null -ne $em) 'history line: empty fields parse'
        Assert-True ($null -eq $em.Session -and $null -eq $em.SessionReset -and $null -eq $em.Week -and $null -eq $em.WeekReset) 'history line: empty fields -> null'
        Assert-True ($null -eq (ConvertFrom-HistoryLine '2026-10-14T12:00:00Z,1,,2')) 'history line: 4 columns -> null'
        Assert-KnownBug ($null -eq (ConvertFrom-HistoryLine '2026-10-14T12:00:00Z,1,,2,,extra')) 'history line: 6 columns -> null' 'APP BUG CLAUDE-USAGE-WIDGET-T2'
        Assert-True ($null -eq (ConvertFrom-HistoryLine '')) 'history line: empty line -> null'
        Assert-Equal '0.33' (Format-HistoryNumber (1.0 / 3.0)) 'history line: two decimals'
        $ns = New-UsageSample -Model @{ Session = (New-UsageLimit 'session' 'Session' 7 $hs.SessionReset '' 5); Week = $null } -Ts $hs.Ts
        Assert-Equal 7 $ns.Session 'sample: session from model'
        Assert-True ($null -eq $ns.Week -and $null -eq $ns.WeekReset) 'sample: missing week -> null'
    }

    # --- json: null-safe property reads and number parsing ---
    Invoke-Group 'json' {
        $jo = '{"a":{"b":{"c":5}},"arr":[1,2],"one":[7],"z":0}' | ConvertFrom-Json
        Assert-True ($null -eq (Get-JsonProp $null 'a')) 'json: null object'
        Assert-True ($null -eq (Get-JsonProp $jo 'missing')) 'json: missing prop'
        Assert-Equal 5 (Get-JsonProp (Get-JsonProp (Get-JsonProp $jo 'a') 'b') 'c') 'json: nested prop'
        Assert-True ($null -eq (Get-JsonProp (Get-JsonProp $jo 'missing') 'b')) 'json: nested under missing'
        $arr = Get-JsonProp $jo 'arr'
        Assert-Equal 2 $arr.Count 'json: array prop'
        $one = Get-JsonProp $jo 'one'
        Assert-True ($one -is [array] -and $one.Count -eq 1) 'json: one-element array stays an array'
        Assert-Equal 0 (Get-JsonProp $jo 'z') 'json: zero is not null'
        Assert-Equal 3 (Get-JsonProp @{ k = 3 } 'k') 'json: hashtable prop'
        Assert-True ($null -eq (Get-JsonProp @{ k = 3 } 'x')) 'json: hashtable missing'
        Assert-True ($null -eq (ConvertTo-UsageNumber '')) 'json: number empty'
        Assert-True ($null -eq (ConvertTo-UsageNumber 'abc')) 'json: number garbage'
        Assert-True ($null -eq (ConvertTo-UsageNumber '1,5')) 'json: number with comma'
        Assert-Equal 1000 (ConvertTo-UsageNumber '1e3') 'json: number exponent'
        Assert-Equal 7 (ConvertTo-UsageNumber 7) 'json: number int'
        Assert-Equal 1.5 (ConvertTo-UsageNumber '1.5') 'json: number invariant decimal'
        Assert-True ($null -eq (ConvertTo-UsageNumber $null)) 'json: number null'
        Assert-True ($null -eq (ConvertTo-UsageNumber @{ a = 1 })) 'json: number from object'
        $a0 = ConvertTo-Array $null
        Assert-True ($a0 -is [array] -and $a0.Count -eq 0) 'json: array of null'
        $a1 = ConvertTo-Array 5
        Assert-True ($a1 -is [array] -and $a1.Count -eq 1) 'json: array of scalar'
        Assert-Equal '' (Format-IsoUtc $null) 'json: iso of null'
        $prevCfg = $env:CLAUDE_CONFIG_DIR
        try {
            $env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'cfg'
            Assert-Equal (Join-Path $tmp 'cfg') (Get-ClaudeConfigDir) 'config dir: env override'
        }
        finally { $env:CLAUDE_CONFIG_DIR = $prevCfg }
    }

    # --- retry: a 429 Retry-After delta is used as the next poll delay without an upper bound ---
    Invoke-Group 'retry' {
        $ra = -1
        $rl = -1
        for ($k = 0; $k -lt $widgetLines.Count; $k++) {
            if ($ra -lt 0 -and $widgetLines[$k] -match '\$resp\.Headers\.RetryAfter') { $ra = $k }
            if ($ra -ge 0 -and $widgetLines[$k] -match "Set-Failure 'ratelimited'") { $rl = $k; break }
        }
        Assert-True ($ra -ge 0 -and $rl -gt $ra) 'retry: Retry-After handling found'
        $block = ($widgetLines[$ra..$rl] -join "`n")
        Assert-KnownBug ($block -match 'Min\(|Clamp|-gt\s|-ge\s|-lt\s|-le\s') 'retry: Retry-After delay is capped' 'APP BUG CLAUDE-USAGE-WIDGET-T1'
    }

    # --- tray (P3): every demo scenario fits the 63-character tooltip and warns when a level is raised ---
    Invoke-Group 'tray' {
        $warn = [string][char]0x26A0
        foreach ($sc in @('normal', 'high', 'expired', 'offline', 'empty')) {
            $ds = New-DemoState -Scenario $sc -Now $now
            $phase = 'ok'
            if ($sc -eq 'expired' -or $sc -eq 'offline') { $phase = $sc }
            $txt = Format-TrayText -Model $ds.Model -Phase $phase -Now $now
            Assert-True ($txt.Length -le 63) ('tray: ' + $sc + ' fits 63')
            $lv = [math]::Max((Get-UsageLevel $ds.Model.Session.Percent $ds.Model.Session.Severity), (Get-UsageLevel $ds.Model.Week.Percent $ds.Model.Week.Severity))
            if ($lv -ge 1 -or $phase -ne 'ok') { Assert-True ($txt.StartsWith($warn)) ('tray: ' + $sc + ' keeps the warning sign') }
            else { Assert-True (-not $txt.StartsWith($warn)) ('tray: ' + $sc + ' no warning sign') }
        }
        $crit = @{ Session = (New-UsageLimit 'session' 'Session' 91 $now.AddHours(1) 'normal' 5); Week = $null }
        Assert-True ((Format-TrayText -Model $crit -Phase 'ok' -Now $now).StartsWith($warn)) 'tray: level 2 keeps the warning sign'
        $long = @{ Session = (New-UsageLimit 'session' 'Session' 100 $now.AddDays(3) 'critical' 5); Week = (New-UsageLimit 'weekly_all' 'Εβδομάδα' 100 $now.AddDays(6) 'critical' 168) }
        foreach ($ph in @('expired', 'unauthorized', 'nocreds', 'forbidden', 'offline', 'ratelimited', 'httperror')) {
            $tx = Format-TrayText -Model $long -Phase $ph -Now $now
            Assert-True ($tx.Length -le 63 -and $tx.StartsWith($warn)) ('tray: phase ' + $ph + ' fits and warns')
        }
    }

    # --- Windows-only: launch spec, shortcut paths, widget snapshots ---
    if ($env:windir) {
        Invoke-Group 'launch' {
            $abs = Join-Path $tmp 'app dir\ClaudeUsageWidget.ps1'
            $ls = Get-WidgetLaunchSpec -ScriptPath $abs
            Assert-True ($ls.Arguments -match ' -WindowStyle Hidden ') 'launch: hidden window'
            Assert-True ($ls.Arguments -match ' -STA ') 'launch: STA'
            Assert-True ($ls.Arguments.EndsWith('-File "' + $abs + '"')) 'launch: quoted absolute script path'
            $m2 = [regex]::Match($ls.Arguments, '-File "([^"]+)"')
            Assert-True ($m2.Success -and [IO.Path]::IsPathRooted($m2.Groups[1].Value)) 'launch: -File path is rooted'
            Assert-Equal (Join-Path $tmp 'app dir') $ls.WorkingDirectory 'launch: working directory'
            Assert-True ([IO.Path]::IsPathRooted($ls.FilePath) -and (Test-Path -LiteralPath $ls.FilePath)) 'launch: conhost exists'
            Assert-True ((Get-StartupShortcutPath).EndsWith('\Claude Usage Widget.lnk')) 'launch: startup shortcut name'
            Assert-True ((Get-StartMenuShortcutPath).EndsWith('\Claude Usage Widget.lnk')) 'launch: start menu shortcut name'
            $lnk = Join-Path $tmp 'test.lnk'
            New-WidgetShortcut -ShortcutPath $lnk -ScriptPath $abs
            $sh = New-Object -ComObject WScript.Shell
            try {
                $back = $sh.CreateShortcut($lnk)
                Assert-True ($ls.FilePath -ieq $back.TargetPath) 'launch: shortcut target'
                Assert-Equal $ls.Arguments $back.Arguments 'launch: shortcut arguments'
                Assert-Equal 7 $back.WindowStyle 'launch: shortcut starts minimized'
            }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
        }

        if ($env:CUW_SKIP_SNAPSHOT -eq '1') { Skip-Test 'snapshot' 'CUW_SKIP_SNAPSHOT=1' }
        else {
            Invoke-Group 'snapshot' {
                $prevApp = $env:LOCALAPPDATA
                $prevCfg = $env:CLAUDE_CONFIG_DIR
                try {
                    # A fake profile: the widget's data dir and Claude config dir both live under $tmp.
                    $env:LOCALAPPDATA = Join-Path $tmp 'appdata'
                    $env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'no-claude'
                    $dataDir = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
                    foreach ($demo in @('normal', 'high', 'expired', 'offline', 'empty')) {
                        $png = Join-Path $tmp ($demo + '.png')
                        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $widgetPath -Snapshot $png -Demo $demo -Theme light 2>&1
                        $code = $LASTEXITCODE
                        Assert-Equal 0 $code ('snapshot: ' + $demo + ' exit code ' + ($out -join ' '))
                        Assert-True ((Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 5120) ('snapshot: ' + $demo + ' png > 5 KB')
                        Assert-True ((@($out) -join "`n") -match 'SNAPSHOT_OK') ('snapshot: ' + $demo + ' reports ok')
                        foreach ($f in @('history.csv', 'settings.json', 'last.json', 'widget.log')) {
                            Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataDir $f))) ('snapshot: ' + $demo + ' writes no ' + $f)
                        }
                    }
                    Assert-True (-not (Test-Path -LiteralPath $env:CLAUDE_CONFIG_DIR)) 'snapshot: config dir untouched'
                }
                finally {
                    $env:LOCALAPPDATA = $prevApp
                    $env:CLAUDE_CONFIG_DIR = $prevCfg
                }
            }
        }
    }
    else { Skip-Test 'launch' 'not Windows'; Skip-Test 'snapshot' 'not Windows' }

    # --- map: every UsageCore function is listed in tests/TEST-MAP.txt ---
    Invoke-Group 'map' {
        $core = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'UsageCore.psm1'), [Text.Encoding]::UTF8)
        $fns = @([regex]::Matches($core, '(?m)^function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
        $mapped = @{}
        foreach ($ml in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'TEST-MAP.txt'), [Text.Encoding]::UTF8)) {
            if ($ml -match '^\s*([\w-]+)\s*->\s*(\S.*)$') { $mapped[$Matches[1]] = $Matches[2].Trim() }
        }
        Assert-True ($fns.Count -ge 40) 'map: found the module functions'
        foreach ($fn in $fns) { Assert-True ($mapped.ContainsKey($fn)) ('map: ' + $fn + ' listed in TEST-MAP.txt') }
        $stale = @($mapped.Keys | Where-Object { $fns -notcontains $_ })
        Assert-Equal 0 $stale.Count ('map: no stale names ' + ($stale -join ','))
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Pass -lt $MIN_PASS) {
    $script:Fail++
    Write-Host ('FAIL floor: pass={0} is below MIN_PASS={1}' -f $script:Pass, $MIN_PASS)
}
Write-Host ('TESTS pass={0} fail={1} xfail={2} skip={3}' -f $script:Pass, $script:Fail, $script:XFail, $script:Skip)
if ($script:Fail -gt 0) { exit 1 }
exit 0
