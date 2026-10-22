# UsageCore.psm1
# Pure logic for the Claude usage widget: credentials, API parsing, history math, formatting.
# No UI code here, so it can be tested without WPF (tests/run-tests.ps1).
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# The file is saved as UTF-8 with BOM so Windows PowerShell 5.1 reads the Greek strings correctly.

Set-StrictMode -Version 2.0

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:DayShort = @('Κυ', 'Δε', 'Τρ', 'Τε', 'Πε', 'Πα', 'Σα')
$script:DayLong = @('Κυριακή', 'Δευτέρα', 'Τρίτη', 'Τετάρτη', 'Πέμπτη', 'Παρασκευή', 'Σάββατο')
$script:HistoryHeader = 'ts,session,session_reset,week,week_reset'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

#region Generic helpers

function Get-JsonProp {
    # Null-safe property read for objects from ConvertFrom-Json (works under StrictMode).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return , $p.Value
}

function ConvertTo-Array {
    param($Value)
    if ($null -eq $Value) { return , @() }
    return , @($Value)
}

function ConvertTo-UsageNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $d = 0.0
        if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
        return $null
    }
    try { return [double]$Value } catch { return $null }
}

function ConvertTo-UsageDate {
    # Accepts ISO-8601 strings or [datetime] (PowerShell 7 ConvertFrom-Json turns ISO strings into DateTime)
    # and returns a [DateTimeOffset] or $null.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
        return [DateTimeOffset]$dt.ToUniversalTime()
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $out = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($s, $script:Inv, $styles, [ref]$out)) { return $out }
    return $null
}

function Get-RoundedMinute {
    # resets_at carries sub-second jitter (16:09:59.8, 16:10:00.2); limit windows reset on whole minutes.
    param($Date)
    if ($null -eq $Date) { return $null }
    $tpm = [TimeSpan]::TicksPerMinute
    $t = $Date.UtcTicks
    $rem = $t % $tpm
    $base = $t - $rem
    if ($rem -ge ($tpm / 2)) { $base += $tpm }
    return [DateTimeOffset]::new($base, [TimeSpan]::Zero)
}

function Format-IsoUtc {
    param($Date)
    if ($null -eq $Date) { return '' }
    return $Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv)
}

function Get-LocalMidnight {
    # Start of the local day that contains $Now, as a DateTimeOffset with the correct local offset (DST-safe).
    param([DateTimeOffset]$Now)
    $d = [datetime]::SpecifyKind($Now.ToLocalTime().Date, [DateTimeKind]::Local)
    return [DateTimeOffset]$d
}

#endregion

#region Credentials and plan

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude')
}

function Read-ClaudeCredential {
    # Reads Claude Code's OAuth credentials (read-only). The caller must never log or persist AccessToken.
    param([string]$Path = (Join-Path (Get-ClaudeConfigDir) '.credentials.json'))
    $r = @{ Ok = $false; Reason = ''; AccessToken = $null; ExpiresAt = $null; SubscriptionType = ''; RateLimitTier = ''; FileTime = $null }
    if (-not (Test-Path -LiteralPath $Path)) { $r.Reason = 'missing'; return $r }
    try {
        $r.FileTime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        $r.Reason = 'unreadable'
        return $r
    }
    $o = Get-JsonProp $json 'claudeAiOauth'
    $tok = Get-JsonProp $o 'accessToken'
    if (-not $tok) { $r.Reason = 'notoken'; return $r }
    $r.AccessToken = [string]$tok
    $exp = Get-JsonProp $o 'expiresAt'
    if ($null -ne $exp) {
        try { $r.ExpiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$exp) } catch { $r.ExpiresAt = $null }
    }
    $r.SubscriptionType = [string](Get-JsonProp $o 'subscriptionType')
    $r.RateLimitTier = [string](Get-JsonProp $o 'rateLimitTier')
    $r.Ok = $true
    return $r
}

function Get-PlanLabel {
    param([string]$SubscriptionType, [string]$RateLimitTier)
    if ($RateLimitTier -match 'max_(\d+)x') { return ('Max ' + $Matches[1] + 'x') }
    if ([string]::IsNullOrWhiteSpace($SubscriptionType)) { return '' }
    $s = $SubscriptionType.Trim()
    return ($s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1))
}

#endregion

#region API response

function New-UsageLimit {
    param([string]$Kind, [string]$Label, $Percent, $ResetsAt, [string]$Severity, $WindowHours)
    return @{
        Kind         = $Kind
        Label        = $Label
        Percent      = $(if ($null -eq $Percent) { 0.0 } else { [double]$Percent })
        ResetsAt     = $ResetsAt
        Severity     = $Severity
        WindowHours  = $WindowHours
        AllowancePct = $null
    }
}

function ConvertFrom-UsageResponse {
    # Normalizes the /api/oauth/usage JSON. Prefers the generic "limits" array and falls back to the
    # older five_hour / seven_day / seven_day_<model> fields.
    param([Parameter(Mandatory = $true)][string]$Json)
    $j = $Json | ConvertFrom-Json
    $model = @{
        Session       = $null
        Week          = $null
        Scoped        = @()
        Breakdown     = @()
        BreakdownAsOf = $null
        WeekStartedAt = $null
        Spend         = $null
    }

    $shares = @{}
    foreach ($s in (ConvertTo-Array (Get-JsonProp $j 'weekly_scoped_shares'))) {
        $idx = Get-JsonProp $s 'limit_index'
        if ($null -ne $idx) { $shares[[int]$idx] = ConvertTo-UsageNumber (Get-JsonProp $s 'allowance_percent_of_weekly') }
    }

    $i = -1
    foreach ($l in (ConvertTo-Array (Get-JsonProp $j 'limits'))) {
        $i++
        if ($null -eq $l) { continue }
        $kind = [string](Get-JsonProp $l 'kind')
        $pct = ConvertTo-UsageNumber (Get-JsonProp $l 'percent')
        $reset = Get-RoundedMinute (ConvertTo-UsageDate (Get-JsonProp $l 'resets_at'))
        $sev = [string](Get-JsonProp $l 'severity')
        if ($kind -eq 'session') {
            if ($null -eq $model.Session) { $model.Session = New-UsageLimit 'session' 'Session' $pct $reset $sev 5 }
        }
        elseif ($kind -eq 'weekly_all') {
            if ($null -eq $model.Week) { $model.Week = New-UsageLimit 'weekly_all' 'Εβδομάδα' $pct $reset $sev 168 }
        }
        else {
            $scope = Get-JsonProp $l 'scope'
            $name = [string](Get-JsonProp (Get-JsonProp $scope 'model') 'display_name')
            if (-not $name) { $name = [string](Get-JsonProp (Get-JsonProp $scope 'surface') 'display_name') }
            if (-not $name) { $name = $kind }
            $hours = $null
            if ($kind -like 'weekly*') { $hours = 168 }
            $entry = New-UsageLimit $kind $name $pct $reset $sev $hours
            if ($shares.ContainsKey($i)) { $entry.AllowancePct = $shares[$i] }
            $model.Scoped += $entry
        }
    }

    if ($null -eq $model.Session) {
        $fh = Get-JsonProp $j 'five_hour'
        if ($null -ne $fh) {
            $model.Session = New-UsageLimit 'session' 'Session' (ConvertTo-UsageNumber (Get-JsonProp $fh 'utilization')) (Get-RoundedMinute (ConvertTo-UsageDate (Get-JsonProp $fh 'resets_at'))) '' 5
        }
    }
    if ($null -eq $model.Week) {
        $sd = Get-JsonProp $j 'seven_day'
        if ($null -ne $sd) {
            $model.Week = New-UsageLimit 'weekly_all' 'Εβδομάδα' (ConvertTo-UsageNumber (Get-JsonProp $sd 'utilization')) (Get-RoundedMinute (ConvertTo-UsageDate (Get-JsonProp $sd 'resets_at'))) '' 168
        }
    }
    if ($model.Scoped.Count -eq 0) {
        foreach ($pair in @(@('seven_day_opus', 'Opus'), @('seven_day_sonnet', 'Sonnet'))) {
            $w = Get-JsonProp $j $pair[0]
            if ($null -ne $w) {
                $reset = Get-RoundedMinute (ConvertTo-UsageDate (Get-JsonProp $w 'resets_at'))
                if ($null -eq $reset -and $null -ne $model.Week) { $reset = $model.Week.ResetsAt }
                $model.Scoped += (New-UsageLimit $pair[0] $pair[1] (ConvertTo-UsageNumber (Get-JsonProp $w 'utilization')) $reset '' 168)
            }
        }
    }

    $bd = Get-JsonProp $j 'seven_day_breakdown'
    if ($null -ne $bd) {
        $model.BreakdownAsOf = ConvertTo-UsageDate (Get-JsonProp $bd 'as_of')
        $model.WeekStartedAt = Get-RoundedMinute (ConvertTo-UsageDate (Get-JsonProp $bd 'window_started_at'))
        foreach ($row in (ConvertTo-Array (Get-JsonProp $bd 'rows'))) {
            $p = ConvertTo-UsageNumber (Get-JsonProp $row 'percent')
            $model.Breakdown += @{
                Key     = [string](Get-JsonProp $row 'key')
                Label   = [string](Get-JsonProp $row 'display_name')
                Percent = $(if ($null -eq $p) { 0.0 } else { $p })
            }
        }
    }

    $sp = Get-JsonProp $j 'spend'
    if ($null -ne $sp -and (Get-JsonProp $sp 'enabled') -eq $true) {
        $used = Get-JsonProp $sp 'used'
        $model.Spend = @{
            Used     = ConvertFrom-UsageMoney $used
            Limit    = ConvertFrom-UsageMoney (Get-JsonProp $sp 'limit')
            Currency = [string](Get-JsonProp $used 'currency')
        }
    }
    return $model
}

function ConvertFrom-UsageMoney {
    param($Money)
    if ($null -eq $Money) { return $null }
    $minor = ConvertTo-UsageNumber (Get-JsonProp $Money 'amount_minor')
    if ($null -eq $minor) { return $null }
    $exp = ConvertTo-UsageNumber (Get-JsonProp $Money 'exponent')
    if ($null -eq $exp) { $exp = 2 }
    return ($minor / [math]::Pow(10, $exp))
}

function Get-UsageLevel {
    # 0 = normal, 1 = warning, 2 = critical. The worse of the API severity and our own thresholds.
    param([double]$Percent, [string]$Severity)
    $lvl = 0
    if ($Percent -ge 90) { $lvl = 2 } elseif ($Percent -ge 75) { $lvl = 1 }
    $s = ([string]$Severity).ToLowerInvariant()
    if ($s -match 'crit|exceed|block|reached') { $lvl = 2 }
    elseif ($s -and $s -ne 'normal' -and $s -ne 'ok' -and $s -ne 'none' -and $lvl -lt 1) { $lvl = 1 }
    return $lvl
}

function Get-WindowElapsedFraction {
    # Share of the limit window that has already passed (0..1): the "even pace" mark on a meter.
    param($ResetsAt, $WindowHours, [DateTimeOffset]$Now, $StartedAt)
    if ($null -eq $ResetsAt -or $null -eq $WindowHours -or [double]$WindowHours -le 0) { return $null }
    $start = $StartedAt
    if ($null -eq $start) { $start = $ResetsAt.AddHours(-[double]$WindowHours) }
    $total = ($ResetsAt - $start).TotalSeconds
    if ($total -le 0) { return $null }
    $f = ($Now - $start).TotalSeconds / $total
    return [math]::Min(1.0, [math]::Max(0.0, $f))
}

function Get-DailyAllowance {
    # Weekly percent still available per remaining day until the weekly reset.
    param([double]$WeekPercent, $ResetsAt, [DateTimeOffset]$Now)
    if ($null -eq $ResetsAt) { return $null }
    $daysLeft = ($ResetsAt - $Now).TotalDays
    if ($daysLeft -le 0) { return $null }
    $remaining = [math]::Max(0.0, 100.0 - $WeekPercent)
    if ($daysLeft -lt 1) { return $remaining }
    return ($remaining / $daysLeft)
}

#endregion

#region Polling

function Get-RateLimitDelay {
    # Delay before the next poll after HTTP 429. Retry-After (delta wins over an absolute date) is honoured but
    # clamped to [1, 60] minutes so a huge or hostile value cannot park polling; without it the back-off is
    # 10 min per consecutive failure, capped at 60.
    param([int]$Failures, $RetryAfterDelta = $null, $RetryAfterDate = $null, [DateTimeOffset]$Now)
    if ($null -ne $RetryAfterDelta) { $mins = ([TimeSpan]$RetryAfterDelta).TotalMinutes }
    elseif ($null -ne $RetryAfterDate) { $mins = ([DateTimeOffset]$RetryAfterDate - $Now).TotalMinutes }
    else { $mins = 10.0 * ($Failures + 1) }
    return [TimeSpan]::FromMinutes([math]::Min(60.0, [math]::Max(1.0, $mins)))
}

#endregion

#region History

function New-UsageSample {
    param($Model, [DateTimeOffset]$Ts)
    $s = @{ Ts = $Ts; Session = $null; SessionReset = $null; Week = $null; WeekReset = $null }
    if ($null -ne $Model.Session) { $s.Session = $Model.Session.Percent; $s.SessionReset = $Model.Session.ResetsAt }
    if ($null -ne $Model.Week) { $s.Week = $Model.Week.Percent; $s.WeekReset = $Model.Week.ResetsAt }
    return $s
}

function Format-HistoryNumber {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([double]$Value).ToString('0.##', $script:Inv)
}

function ConvertTo-HistoryLine {
    param($Sample)
    return ('{0},{1},{2},{3},{4}' -f (Format-IsoUtc $Sample.Ts), (Format-HistoryNumber $Sample.Session),
        (Format-IsoUtc $Sample.SessionReset), (Format-HistoryNumber $Sample.Week), (Format-IsoUtc $Sample.WeekReset))
}

function ConvertFrom-HistoryLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $p = $Line.Trim().Split(',')
    if ($p.Count -ne 5) { return $null }
    $ts = ConvertTo-UsageDate $p[0]
    if ($null -eq $ts) { return $null }
    return @{
        Ts           = $ts
        Session      = (ConvertTo-UsageNumber $p[1])
        SessionReset = (ConvertTo-UsageDate $p[2])
        Week         = (ConvertTo-UsageNumber $p[3])
        WeekReset    = (ConvertTo-UsageDate $p[4])
    }
}

function Read-UsageHistory {
    # Returns a chronologically sorted List of samples, optionally only those at or after $Since.
    param([string]$Path, $Since)
    $list = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return , $list }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ($line.StartsWith('ts,')) { continue }
        $s = ConvertFrom-HistoryLine $line
        if ($null -eq $s) { continue }
        if ($null -ne $Since -and $s.Ts -lt $Since) { continue }
        $rows.Add($s)
    }
    foreach ($s in @($rows | Sort-Object { $_.Ts })) { $list.Add($s) }
    return , $list
}

function Add-UsageHistorySample {
    param([string]$Path, $Sample)
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.File]::WriteAllText($Path, $script:HistoryHeader + "`n", $script:Utf8NoBom)
    }
    [IO.File]::AppendAllText($Path, (ConvertTo-HistoryLine $Sample) + "`n", $script:Utf8NoBom)
}

function Compress-UsageHistory {
    # Drops samples older than $KeepSince. Rewrites the file only when something was dropped.
    param([string]$Path, [DateTimeOffset]$KeepSince)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $all = Read-UsageHistory -Path $Path
    $keep = @($all | Where-Object { $_.Ts -ge $KeepSince })
    if ($keep.Count -eq $all.Count) { return $all.Count }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($script:HistoryHeader + "`n")
    foreach ($s in $keep) { [void]$sb.Append((ConvertTo-HistoryLine $s) + "`n") }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $sb.ToString(), $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $keep.Count
}

function Get-WindowDelta {
    # How much of a limit was used between two samples. A window that reset in between counts from zero.
    param($PrevValue, $PrevReset, $CurValue, [DateTimeOffset]$CurTs)
    if ($null -eq $CurValue -or $null -eq $PrevValue) { return 0.0 }
    $cur = [double]$CurValue
    if ($null -ne $PrevReset -and $CurTs -ge $PrevReset) { return [math]::Max(0.0, $cur) }
    return [math]::Max(0.0, $cur - [double]$PrevValue)
}

function New-UsageIncrement {
    # Usage between two consecutive samples, attributed to the later sample's time.
    # Gap = the samples were far apart (PC off / widget closed), so the time attribution is approximate.
    param($Prev, $Cur, [double]$GapMinutes = 30)
    return @{
        Ts      = $Cur.Ts
        Session = (Get-WindowDelta -PrevValue $Prev.Session -PrevReset $Prev.SessionReset -CurValue $Cur.Session -CurTs $Cur.Ts)
        Week    = (Get-WindowDelta -PrevValue $Prev.Week -PrevReset $Prev.WeekReset -CurValue $Cur.Week -CurTs $Cur.Ts)
        Gap     = (($Cur.Ts - $Prev.Ts).TotalMinutes -gt $GapMinutes)
    }
}

function Get-UsageIncrements {
    # All increments of a chronological sample list (start-up and pruning only; the widget appends
    # one New-UsageIncrement per new sample).
    param($Samples, [double]$GapMinutes = 30)
    $out = [System.Collections.Generic.List[object]]::new()
    $prev = $null
    foreach ($s in $Samples) {
        if ($null -ne $prev) { $out.Add((New-UsageIncrement -Prev $prev -Cur $s -GapMinutes $GapMinutes)) }
        $prev = $s
    }
    return , $out
}

function Get-IncrementSum {
    # Increments are chronological: scan back from the newest and stop at $Since (cost = window, not history).
    param($Increments, [DateTimeOffset]$Since, [string]$Field)
    $t = 0.0
    for ($i = $Increments.Count - 1; $i -ge 0; $i--) {
        $inc = $Increments[$i]
        if ($inc.Ts -le $Since) { break }
        $t += [double]$inc[$Field]
    }
    return $t
}

function Get-HourlyBuckets {
    # The last $Hours clock hours, oldest first; the last bucket is the current hour.
    param($Increments, [DateTimeOffset]$Now, [int]$Hours = 24)
    $l = $Now.ToLocalTime()
    $cur = New-Object DateTimeOffset($l.Year, $l.Month, $l.Day, $l.Hour, 0, 0, $l.Offset)
    $first = $cur.AddHours( - ($Hours - 1))
    $buckets = [System.Collections.Generic.List[object]]::new()
    for ($k = 0; $k -lt $Hours; $k++) {
        $start = $first.AddHours($k)
        $buckets.Add(@{ Start = $start; End = $start.AddHours(1); Session = 0.0; Week = 0.0; Samples = 0; HasGap = $false })
    }
    for ($i = $Increments.Count - 1; $i -ge 0; $i--) {
        $inc = $Increments[$i]
        if ($inc.Ts -lt $first) { break }
        $idx = [int][math]::Floor(($inc.Ts - $first).TotalHours)
        if ($idx -lt 0 -or $idx -ge $Hours) { continue }
        $b = $buckets[$idx]
        $b.Session += [double]$inc.Session
        $b.Week += [double]$inc.Week
        $b.Samples++
        if ($inc.Gap) { $b.HasGap = $true }
    }
    return , $buckets
}

function Get-DailyBuckets {
    # The last $Days local calendar days, oldest first; the last bucket is today.
    param($Increments, [DateTimeOffset]$Now, [int]$Days = 7)
    $today = $Now.ToLocalTime().Date
    $first = $today.AddDays( - ($Days - 1))
    $buckets = [System.Collections.Generic.List[object]]::new()
    for ($k = 0; $k -lt $Days; $k++) {
        $buckets.Add(@{ Date = $first.AddDays($k); Session = 0.0; Week = 0.0; Samples = 0; HasGap = $false })
    }
    for ($i = $Increments.Count - 1; $i -ge 0; $i--) {
        $inc = $Increments[$i]
        $idx = ($inc.Ts.ToLocalTime().Date - $first).Days
        if ($idx -lt 0) { break }
        if ($idx -ge $Days) { continue }
        $b = $buckets[$idx]
        $b.Session += [double]$inc.Session
        $b.Week += [double]$inc.Week
        $b.Samples++
        if ($inc.Gap) { $b.HasGap = $true }
    }
    return , $buckets
}

#endregion

#region Formatting (Greek UI)

function Get-DayShort { param([DayOfWeek]$Day) return $script:DayShort[[int]$Day] }
function Get-DayLong { param([DayOfWeek]$Day) return $script:DayLong[[int]$Day] }

function Format-UsagePercent {
    param($Value)
    if ($null -eq $Value) { return '—' }
    $v = [double]$Value
    if ($v -gt 0 -and $v -lt 1) { return '<1%' }
    return ('{0}%' -f [int][math]::Round($v, [MidpointRounding]::AwayFromZero))
}

function Format-UsageDelta {
    param([double]$Value)
    if ($Value -le 0) { return '0%' }
    if ($Value -lt 1) { return '+<1%' }
    return ('+{0}%' -f [int][math]::Round($Value, [MidpointRounding]::AwayFromZero))
}

function Format-UsageSpan {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -le 0) { return 'τώρα' }
    if ($Span.TotalMinutes -lt 1) { return '<1λ' }
    if ($Span.TotalHours -lt 1) { return ('{0}λ' -f [int][math]::Floor($Span.TotalMinutes)) }
    if ($Span.TotalDays -lt 1) { return ('{0}ω {1}λ' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes) }
    return ('{0}ημ {1}ω' -f [int][math]::Floor($Span.TotalDays), $Span.Hours)
}

function Format-ResetTime {
    # 19:10 (today), "αύριο 09:00", or "Δε 26/10 16:00".
    param($ResetsAt, [DateTimeOffset]$Now)
    if ($null -eq $ResetsAt) { return '' }
    $l = $ResetsAt.ToLocalTime()
    $n = $Now.ToLocalTime()
    $hm = $l.ToString('HH:mm', $script:Inv)
    if ($l.Date -eq $n.Date) { return $hm }
    if ($l.Date -eq $n.Date.AddDays(1)) { return ('αύριο ' + $hm) }
    return ('{0} {1} {2}' -f (Get-DayShort $l.DayOfWeek), $l.ToString('dd/MM', $script:Inv), $hm)
}

function Format-LongDate {
    # "Τρίτη 20/10"
    param([datetime]$Date)
    return ('{0} {1}' -f (Get-DayLong $Date.DayOfWeek), $Date.ToString('dd/MM', $script:Inv))
}

#endregion

#region Notification area (tray icon shown while the widget is minimized)

$script:TrayNotes = @{
    expired = 'token έληξε'; unauthorized = 'token 401'; nocreds = 'χωρίς login'; forbidden = '403'
    offline = 'χωρίς σύνδεση'; ratelimited = '429'; httperror = 'σφάλμα'
}

function Format-TrayText {
    # Tooltip of the tray icon. NotifyIcon.Text takes at most 63 characters on .NET Framework, so the
    # session reset time is dropped first and the text is cut only as a last resort.
    param($Model, [string]$Phase, [DateTimeOffset]$Now)
    $note = ''
    if ($Phase -and $script:TrayNotes.ContainsKey($Phase)) { $note = $script:TrayNotes[$Phase] }
    $alert = [bool]$note
    $sess = ''
    $reset = ''
    $week = ''
    if ($null -ne $Model) {
        $s = $Model.Session
        if ($null -ne $s) {
            $sess = 'Session ' + (Format-UsagePercent $s.Percent)
            if ($null -ne $s.ResetsAt -and $s.ResetsAt -gt $Now) { $reset = 'reset ' + (Format-ResetTime $s.ResetsAt $Now) }
            if ((Get-UsageLevel -Percent $s.Percent -Severity $s.Severity) -gt 0) { $alert = $true }
        }
        $wk = $Model.Week
        if ($null -ne $wk) {
            $week = 'Εβδ. ' + (Format-UsagePercent $wk.Percent)
            if ((Get-UsageLevel -Percent $wk.Percent -Severity $wk.Severity) -gt 0) { $alert = $true }
        }
    }
    $head = 'Claude'
    if ($alert) { $head = ([string][char]0x26A0) + ' Claude' }
    $text = ''
    foreach ($withReset in @($true, $false)) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add($head)
        if ($sess) { $parts.Add($sess) }
        if ($withReset -and $reset) { $parts.Add($reset) }
        if ($week) { $parts.Add($week) }
        if ($note) { $parts.Add($note) }
        if ($parts.Count -eq 1) { $parts.Add('φόρτωση…') }
        $text = $parts -join ' · '
        if ($text.Length -le 63) { return $text }
    }
    return ($text.Substring(0, 62) + '…')
}

function Get-TrayRing {
    # Ring of the tray icon: the higher of the session and weekly percentages (the limit that binds first),
    # coloured by the worse level. Key changes only when the drawn icon would change.
    param($Model)
    $pct = $null
    $lvl = 0
    if ($null -ne $Model) {
        foreach ($lim in @($Model.Session, $Model.Week)) {
            if ($null -eq $lim) { continue }
            $p = [double]$lim.Percent
            if ($null -eq $pct -or $p -gt $pct) { $pct = $p }
            $lv = Get-UsageLevel -Percent $p -Severity $lim.Severity
            if ($lv -gt $lvl) { $lvl = $lv }
        }
    }
    if ($null -eq $pct) { return @{ Percent = $null; Sweep = 0.0; Color = 'Accent'; Key = 'none' } }
    $pct = [math]::Min(100.0, [math]::Max(0.0, $pct))
    $color = @('Accent', 'Warn', 'Crit')[$lvl]
    return @{
        Percent = $pct
        Sweep   = [math]::Round(3.6 * $pct, 1)
        Color   = $color
        Key     = ('{0}|{1}' -f [int][math]::Round($pct, [MidpointRounding]::AwayFromZero), $color)
    }
}

#endregion

#region Demo data (screenshots and UI tests; never written to history)

function New-DemoState {
    param([string]$Scenario = 'normal', [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $intensity = 1.0
    if ($Scenario -eq 'high') { $intensity = 2.3 }
    $rnd = New-Object System.Random(7)
    $nowUtc = $Now.ToUniversalTime()
    $weekReset = (New-Object DateTimeOffset($nowUtc.Year, $nowUtc.Month, $nowUtc.Day, $nowUtc.Hour, 0, 0, [TimeSpan]::Zero)).AddDays(3).AddHours(5)
    $t = (New-Object DateTimeOffset($nowUtc.Year, $nowUtc.Month, $nowUtc.Day, $nowUtc.Hour, 0, 0, [TimeSpan]::Zero)).AddDays(-7)
    $samples = [System.Collections.Generic.List[object]]::new()
    $session = 0.0; $sessionReset = $null; $week = 0.0; $prevWe = $null
    while ($t -le $nowUtc) {
        $we = $weekReset
        while ($we.AddDays(-7) -gt $t) { $we = $we.AddDays(-7) }
        if ($null -ne $prevWe -and $we -ne $prevWe) { $week = 0.0 }
        $prevWe = $we
        if ($null -ne $sessionReset -and $t -ge $sessionReset) { $session = 0.0; $sessionReset = $null }
        $h = $t.ToLocalTime().Hour
        $p = 0.02
        if ($h -ge 9 -and $h -lt 13) { $p = 0.5 } elseif ($h -ge 15 -and $h -lt 19) { $p = 0.6 } elseif ($h -ge 21 -and $h -lt 24) { $p = 0.4 }
        if ($rnd.NextDouble() -lt $p -and $session -lt 100) {
            $u = $rnd.NextDouble() * 1.4 * $intensity
            if ($null -eq $sessionReset) { $sessionReset = $t.AddHours(5) }
            $session = [math]::Min(100.0, $session + $u)
            $week = [math]::Min(100.0, $week + $u * 0.22)
        }
        $samples.Add(@{ Ts = $t; Session = [math]::Round($session); SessionReset = $sessionReset; Week = [math]::Round($week); WeekReset = $we })
        $t = $t.AddMinutes(5)
    }
    $last = $samples[$samples.Count - 1]
    $scopedPct = [math]::Round([math]::Min(100, $last.Week * 0.3))
    $model = @{
        Session       = (New-UsageLimit 'session' 'Session' $last.Session $last.SessionReset 'normal' 5)
        Week          = (New-UsageLimit 'weekly_all' 'Εβδομάδα' $last.Week $last.WeekReset 'normal' 168)
        Scoped        = @((New-UsageLimit 'weekly_scoped' 'Fable' $scopedPct $last.WeekReset 'normal' 168))
        Breakdown     = @(
            @{ Key = 'claude_code'; Label = 'Claude Code'; Percent = 46.0 },
            @{ Key = 'chat'; Label = 'Chats'; Percent = 12.0 },
            @{ Key = 'cowork'; Label = 'Cowork'; Percent = 42.0 },
            @{ Key = 'other'; Label = 'Other'; Percent = 0.0 })
        BreakdownAsOf = $nowUtc
        WeekStartedAt = $last.WeekReset.AddDays(-7)
        Spend         = $null
    }
    $model.Scoped[0].AllowancePct = 50.0
    if ($Scenario -eq 'empty') { $samples = [System.Collections.Generic.List[object]]::new() }
    return @{ Model = $model; Samples = $samples }
}

#endregion

#region Windows integration (shortcuts, processes)

function Get-WidgetLaunchSpec {
    # conhost --headless keeps the console hidden even when Windows Terminal is the default terminal.
    param([string]$ScriptPath)
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:windir 'System32\conhost.exe'
    $argLine = ('--headless "{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $ps, $ScriptPath)
    return @{ FilePath = $conhost; Arguments = $argLine; WorkingDirectory = (Split-Path -Parent $ScriptPath); Icon = ('{0},0' -f $ps) }
}

function New-WidgetShortcut {
    param([string]$ShortcutPath, [string]$ScriptPath)
    $spec = Get-WidgetLaunchSpec -ScriptPath $ScriptPath
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($ShortcutPath)
        $lnk.TargetPath = $spec.FilePath
        $lnk.Arguments = $spec.Arguments
        $lnk.WorkingDirectory = $spec.WorkingDirectory
        $lnk.IconLocation = $spec.Icon
        $lnk.Description = 'Claude usage widget'
        $lnk.WindowStyle = 7
        $lnk.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-StartupShortcutPath { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk') }
function Get-StartMenuShortcutPath { return (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Usage Widget.lnk') }

function Get-WidgetProcess {
    # Running widget instances (excluding snapshot runs and the current process).
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue)
    return , @($procs | Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and
            $_.CommandLine -match '-File\s+"?[^"]*ClaudeUsageWidget\.ps1' -and
            $_.CommandLine -notmatch '-Snapshot'
        })
}

#endregion

Export-ModuleMember -Function *
