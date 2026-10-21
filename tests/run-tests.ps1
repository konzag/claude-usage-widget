<#
.SYNOPSIS
    Dependency-free tests for src/UsageCore.psm1 (no Pester needed).
    Runs on Windows PowerShell 5.1 and PowerShell 7+. Exit code 0 = all passed.
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\run-tests.ps1
#>
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
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('TESTS pass={0} fail={1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
