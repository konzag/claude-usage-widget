<#
.SYNOPSIS
    Floating desktop widget for Windows 11 that shows Claude plan usage: the 5-hour session, the weekly
    limit (plus per-model weekly limits), and hourly / daily history.

.DESCRIPTION
    Data source: https://api.anthropic.com/api/oauth/usage, the endpoint behind Claude Code's /usage.
    Auth: the Claude Code OAuth access token in %USERPROFILE%\.claude\.credentials.json, read-only.
    The token is never logged, written to disk, or sent anywhere except api.anthropic.com.
    The widget never refreshes or rewrites credentials: Claude Code does that; the widget resumes on its own
    as soon as the credentials file changes.
    Data files (settings, history, last response, log) live in %LOCALAPPDATA%\ClaudeUsageWidget.

.PARAMETER Snapshot
    Render the widget to this PNG path and exit (docs and visual checks). Writes no history or settings.

.PARAMETER Demo
    Use built-in demo data instead of the API: normal, high, expired, offline, empty. Writes nothing.

.PARAMETER Theme
    Force light or dark (or auto) for this run; the saved setting is used otherwise.

.PARAMETER Chart
    Start the history chart on this tab for this run: hours (24 h) or days (7 days).

.PARAMETER Compact
    Start in compact view for this run.

.PARAMETER Expanded
    Start in expanded view for this run.

.PARAMETER Scale
    Snapshot scale factor (default 2).

.EXAMPLE
    powershell.exe -NoProfile -STA -File .\ClaudeUsageWidget.ps1 -Snapshot .\shot.png -Demo high
#>
[CmdletBinding()]
param(
    [string]$Snapshot,
    [ValidateSet('normal', 'high', 'expired', 'offline', 'empty')][string]$Demo,
    [ValidateSet('auto', 'light', 'dark')][string]$Theme,
    [ValidateSet('hours', 'days')][string]$Chart,
    [switch]$Compact,
    [switch]$Expanded,
    [double]$Scale = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

#region Paths, state

$script:AppVersion = '1.0.0'
$script:ScriptPath = $PSCommandPath
$script:AppDir = Split-Path -Parent $PSCommandPath
$script:DataDir = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
[void][IO.Directory]::CreateDirectory($script:DataDir)
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:HistoryPath = Join-Path $script:DataDir 'history.csv'
$script:LastPath = Join-Path $script:DataDir 'last.json'
$script:LogPath = Join-Path $script:DataDir 'widget.log'
$script:UsageUrl = 'https://api.anthropic.com/api/oauth/usage'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DemoMode = [bool]$Demo
$script:ReadOnly = [bool]$Snapshot -or [bool]$Demo
$script:ThemeOverride = $Theme

Import-Module (Join-Path $script:AppDir 'UsageCore.psm1') -Force -DisableNameChecking
$script:CredPath = Join-Path (Get-ClaudeConfigDir) '.credentials.json'

$script:Model = $null
$script:ModelAt = $null
$script:PlanLabel = ''
$script:Samples = [System.Collections.Generic.List[object]]::new()
$script:Increments = [System.Collections.Generic.List[object]]::new()
$script:FetchTask = $null
$script:FetchStarted = [DateTimeOffset]::UtcNow
$script:CredFileTime = $null
$script:TickCount = 0
$script:PositionReady = $false
$script:LastPruneDate = (Get-Date).Date
$script:ThemeName = 'light'
$script:Brush = @{}
$script:State = @{ Phase = 'init'; Detail = ''; Failures = 0; NextPollAt = [DateTimeOffset]::UtcNow }
$script:Mutex = $null
$script:Timer = $null

function Write-Log {
    param([string]$Message)
    if ($script:ReadOnly) { return }
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 262144)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.1') -Force
        }
        $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8NoBom)
    }
    catch { }
}

#endregion

#region Single instance, assemblies, native helper

if (-not $script:ReadOnly) {
    $createdNew = $false
    $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\ClaudeUsageWidget', [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log 'another instance is already running; exiting'
        exit 0
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Net.Http

if (-not ('CuwNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CuwNative {
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr value);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr minimum, IntPtr maximum);
    // Tool window: no Alt+Tab entry, no taskbar button.
    public static void HideFromAltTab(IntPtr hwnd) {
        long ex = GetWindowLongPtr(hwnd, -20).ToInt64();
        ex = (ex | 0x80L) & ~0x40000L;
        SetWindowLongPtr(hwnd, -20, new IntPtr(ex));
    }
    // Hand idle pages back to Windows (PowerShell + WPF keep a large start-up working set).
    public static void TrimWorkingSet() {
        SetProcessWorkingSetSize(GetCurrentProcess(), new IntPtr(-1), new IntPtr(-1));
    }
}
'@
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(20)

#endregion

#region Settings

$script:Settings = [ordered]@{
    pollMinutes = 5
    topmost     = $true
    compact     = $false
    chart       = 'hours'
    theme       = 'auto'
    left        = $null
    top         = $null
    bottom      = $null
    anchor      = 'bottom'
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    try {
        $j = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($k in @($script:Settings.Keys)) {
            $v = Get-JsonProp $j $k
            if ($null -ne $v) { $script:Settings[$k] = $v }
        }
    }
    catch { Write-Log ('settings unreadable, using defaults: ' + $_.Exception.Message) }
    if ([double]$script:Settings.pollMinutes -lt 1) { $script:Settings.pollMinutes = 1 }
}

function Save-Settings {
    if ($script:ReadOnly) { return }
    try { [IO.File]::WriteAllText($script:SettingsPath, ($script:Settings | ConvertTo-Json), $script:Utf8NoBom) }
    catch { Write-Log ('settings save failed: ' + $_.Exception.Message) }
}

#endregion

#region Theme

$script:Palettes = @{
    light = @{
        Surface = '#FCFCFB'; Hairline = '#1F0B0B0B'; Ink = '#0B0B0B'; Ink2 = '#52514E'; Muted = '#6B6963'
        Baseline = '#C3C2B7'; Pill = '#ECEBE6'; Hover = '#F1F0EC'
        Accent = '#2A78D6'; AccentTrack = '#CDE2FB'; AccentSoft = '#86B6EF'
        Warn = '#FAB219'; WarnTrack = '#FCEBC2'; Crit = '#D03B3B'; CritTrack = '#F6D4D4'
        S1 = '#2A78D6'; S2 = '#EB6834'; S3 = '#1BAF7A'; SOther = '#B9B7B0'
    }
    dark  = @{
        Surface = '#1A1A19'; Hairline = '#24FFFFFF'; Ink = '#F0EFEC'; Ink2 = '#C3C2B7'; Muted = '#A3A198'
        Baseline = '#45453F'; Pill = '#2E2E2B'; Hover = '#262624'
        Accent = '#3987E5'; AccentTrack = '#0D366B'; AccentSoft = '#1C5CAB'
        Warn = '#FAB219'; WarnTrack = '#4A3B12'; Crit = '#D03B3B'; CritTrack = '#4C1F1F'
        S1 = '#3987E5'; S2 = '#D95926'; S3 = '#199E70'; SOther = '#5C5B57'
    }
}

function New-Brush {
    # ::new() instead of New-Object: New-Object returns a PSObject wrapper, and that wrapper leaks into
    # object-typed slots (ResourceDictionary values, ItemCollection.Add), where WPF rejects it.
    param([string]$Hex)
    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $b = [System.Windows.Media.SolidColorBrush]::new($c)
    $b.Freeze()
    return $b
}

function Get-EffectiveTheme {
    $t = [string]$script:Settings.theme
    if ($script:ThemeOverride) { $t = $script:ThemeOverride }
    if ($t -eq 'light' -or $t -eq 'dark') { return $t }
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme'
        if ([int]$v -eq 0) { return 'dark' }
    }
    catch { }
    return 'light'
}

function Set-Theme {
    $name = Get-EffectiveTheme
    $script:ThemeName = $name
    $p = $script:Palettes[$name]
    $script:Brush = @{}
    foreach ($k in $p.Keys) {
        $script:Brush[$k] = New-Brush $p[$k]
        $script:Window.Resources[$k] = $script:Brush[$k].psobject.BaseObject
    }
    $fx = $script:Card.Effect
    if ($null -ne $fx) {
        if ($name -eq 'dark') { $fx.Opacity = 0.45 } else { $fx.Opacity = 0.16 }
    }
}

function Set-ThemeSetting {
    param([string]$Value)
    $script:Settings.theme = $Value
    $script:ThemeOverride = ''
    Save-Settings
    Set-Theme
    Update-View
}

#endregion

#region Window

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" Width="324" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12">
    <Grid x:Name="Shell" Background="Transparent">
        <Border x:Name="Card" Margin="12" CornerRadius="10" BorderThickness="1" Padding="14,11,14,11"
                Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Hairline}">
            <Border.Effect>
                <DropShadowEffect BlurRadius="18" ShadowDepth="3" Direction="270" Opacity="0.16" Color="Black"/>
            </Border.Effect>
            <StackPanel x:Name="Body" Width="270">
                <Grid x:Name="Header">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Claude usage" FontWeight="SemiBold" FontSize="12.5" Foreground="{DynamicResource Ink}"/>
                        <TextBlock x:Name="PlanText" Margin="7,0,0,0" FontSize="11.5" VerticalAlignment="Center" Foreground="{DynamicResource Ink2}"/>
                    </StackPanel>
                    <Border x:Name="RefreshButton" Grid.Column="1" Background="Transparent" Cursor="Hand" Padding="6,2,6,2" CornerRadius="4">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock x:Name="RefreshGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Text="&#xE72C;" VerticalAlignment="Center" Foreground="{DynamicResource Ink2}"/>
                            <TextBlock x:Name="UpdatedText" Margin="5,0,0,0" FontSize="11" VerticalAlignment="Center" Foreground="{DynamicResource Ink2}"/>
                        </StackPanel>
                    </Border>
                    <Border x:Name="ToggleButton" Grid.Column="2" Background="Transparent" Cursor="Hand" Padding="6,2,5,2" Margin="2,0,0,0" CornerRadius="4">
                        <TextBlock x:Name="ToggleGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Text="&#xE70E;" VerticalAlignment="Center" Foreground="{DynamicResource Ink2}"/>
                    </Border>
                </Grid>
                <StackPanel x:Name="MainPanel" Margin="0,10,0,0"/>
                <StackPanel x:Name="DetailPanel"/>
                <TextBlock x:Name="StatusText" Margin="0,4,0,2" FontSize="11" TextWrapping="Wrap" Visibility="Collapsed" Foreground="{DynamicResource Ink2}"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'Shell', 'Card', 'PlanText', 'RefreshButton', 'RefreshGlyph', 'UpdatedText', 'ToggleButton', 'ToggleGlyph', 'MainPanel', 'DetailPanel', 'StatusText') {
    Set-Variable -Scope Script -Name $n -Value $script:Window.FindName($n)
}

#endregion

#region Element helpers

$script:W = 270.0

function New-Thickness {
    param([double]$Left, [double]$Top, [double]$Right, [double]$Bottom)
    return (New-Object System.Windows.Thickness($Left, $Top, $Right, $Bottom))
}

function New-Text {
    param([string]$Text, [double]$Size, $Fg, [string]$Weight = 'Normal')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = $Fg
    if ($Weight -eq 'SemiBold') { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    return $t
}

function New-Rect {
    param([double]$Width, [double]$Height, $Fill, [double]$Radius = 0)
    $r = New-Object System.Windows.Shapes.Rectangle
    $r.Width = $Width
    $r.Height = $Height
    $r.Fill = $Fill
    $r.RadiusX = $Radius
    $r.RadiusY = $Radius
    return $r
}

function Set-Pos {
    param($Element, [double]$X, [double]$Y)
    [System.Windows.Controls.Canvas]::SetLeft($Element, $X)
    [System.Windows.Controls.Canvas]::SetTop($Element, $Y)
}

function Set-Tip {
    param($Element, [string]$Text)
    if (-not $Text) { return }
    $Element.ToolTip = $Text
    [System.Windows.Controls.ToolTipService]::SetShowDuration($Element, 30000)
    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($Element, 250)
}

function New-StarColumn {
    $c = New-Object System.Windows.Controls.ColumnDefinition
    $c.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    return $c
}

function New-AutoColumn {
    $c = New-Object System.Windows.Controls.ColumnDefinition
    $c.Width = [System.Windows.GridLength]::Auto
    return $c
}

function Get-SeriesBrush {
    param([string]$Key)
    switch ($Key) {
        'claude_code' { return $script:Brush.S1 }
        'chat' { return $script:Brush.S2 }
        'cowork' { return $script:Brush.S3 }
        default { return $script:Brush.SOther }
    }
}

function Get-SurfaceLabel {
    param($Row)
    if ($Row.Key -eq 'other') { return 'Άλλα' }
    if ($Row.Label) { return $Row.Label }
    return $Row.Key
}

#endregion

#region Blocks

function New-MeterBlock {
    # Label + value row, a meter (fill = severity, track = lighter step of the same ramp) with an
    # "even pace" tick, and an optional subline.
    param([string]$Label, $Limit, [string]$Subline, [string]$Tip, $Elapsed, [double]$BarHeight = 6, [double]$BottomMargin = 10, [double]$LabelSize = 12)
    $W = $script:W
    $pct = [double]$Limit.Percent
    $lvl = Get-UsageLevel -Percent $pct -Severity $Limit.Severity
    $fillBrush = $script:Brush.Accent
    $trackBrush = $script:Brush.AccentTrack
    if ($lvl -eq 1) { $fillBrush = $script:Brush.Warn; $trackBrush = $script:Brush.WarnTrack }
    if ($lvl -eq 2) { $fillBrush = $script:Brush.Crit; $trackBrush = $script:Brush.CritTrack }

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thickness 0 0 0 $BottomMargin
    $sp.Background = [System.Windows.Media.Brushes]::Transparent

    $row = New-Object System.Windows.Controls.Grid
    $row.ColumnDefinitions.Add((New-StarColumn))
    $row.ColumnDefinitions.Add((New-AutoColumn))
    $lt = New-Text $Label $LabelSize $script:Brush.Ink
    $lt.VerticalAlignment = 'Bottom'
    $valText = Format-UsagePercent $pct
    if ($lvl -gt 0) { $valText = ([string][char]0x26A0) + ' ' + $valText }
    $vt = New-Text $valText ($LabelSize + 1.5) $script:Brush.Ink 'SemiBold'
    $vt.VerticalAlignment = 'Bottom'
    [System.Windows.Controls.Grid]::SetColumn($vt, 1)
    [void]$row.Children.Add($lt)
    [void]$row.Children.Add($vt)
    [void]$sp.Children.Add($row)

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W
    $cv.Height = $BarHeight + 4
    $cv.Margin = New-Thickness 0 3 0 3
    $track = New-Rect $W $BarHeight $trackBrush ($BarHeight / 2)
    Set-Pos $track 0 2
    [void]$cv.Children.Add($track)
    $fw = [math]::Round($W * [math]::Min(100.0, [math]::Max(0.0, $pct)) / 100.0)
    if ($pct -gt 0 -and $fw -lt $BarHeight) { $fw = $BarHeight }
    if ($fw -gt 0) {
        $fill = New-Rect $fw $BarHeight $fillBrush ($BarHeight / 2)
        Set-Pos $fill 0 2
        [void]$cv.Children.Add($fill)
    }
    if ($null -ne $Elapsed) {
        $x = [math]::Round($W * [double]$Elapsed) - 1
        $x = [math]::Min($W - 2, [math]::Max(0, $x))
        $ring = New-Rect 4 ($BarHeight + 4) $script:Brush.Surface 0
        Set-Pos $ring ($x - 1) 0
        [void]$cv.Children.Add($ring)
        $tick = New-Rect 2 ($BarHeight + 4) $script:Brush.Ink2 1
        Set-Pos $tick $x 0
        [void]$cv.Children.Add($tick)
    }
    [void]$sp.Children.Add($cv)
    if ($Subline) { [void]$sp.Children.Add((New-Text $Subline 11 $script:Brush.Ink2)) }
    Set-Tip $sp $Tip
    return $sp
}

function New-BreakdownBlock {
    # Part-to-whole of this week's usage by surface: stacked bar with 2px surface gaps + legend with values.
    param($Rows, $AsOf)
    $W = $script:W
    $visible = @($Rows | Where-Object { [double]$_.Percent -gt 0 })
    if ($visible.Count -eq 0) { return $null }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thickness 0 2 0 10
    $sp.Background = [System.Windows.Media.Brushes]::Transparent
    [void]$sp.Children.Add((New-Text 'Κατανομή εβδομάδας' 11 $script:Brush.Ink2))
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W
    $cv.Height = 6
    $cv.Margin = New-Thickness 0 5 0 5
    $gap = 2.0
    $total = 0.0
    foreach ($r in $visible) { $total += [double]$r.Percent }
    $avail = $W - $gap * ($visible.Count - 1)
    $x = 0.0
    for ($i = 0; $i -lt $visible.Count; $i++) {
        # PowerShell variable names are case-insensitive: never name a local $w next to $W.
        $r = $visible[$i]
        $segW = $avail * [double]$r.Percent / $total
        if ($i -eq $visible.Count - 1) { $segW = $W - $x }
        $segW = [math]::Max(2.0, $segW)
        $seg = New-Rect $segW 6 (Get-SeriesBrush $r.Key) 2
        Set-Tip $seg ('{0}: {1} της χρήσης αυτής της εβδομάδας' -f (Get-SurfaceLabel $r), (Format-UsagePercent $r.Percent))
        Set-Pos $seg $x 0
        [void]$cv.Children.Add($seg)
        $x += $segW + $gap
    }
    [void]$sp.Children.Add($cv)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($r in $visible) {
        $item = New-Object System.Windows.Controls.StackPanel
        $item.Orientation = 'Horizontal'
        $item.Margin = New-Thickness 0 0 12 0
        $sw = New-Rect 8 8 (Get-SeriesBrush $r.Key) 2
        $sw.VerticalAlignment = 'Center'
        $sw.Margin = New-Thickness 0 1 5 0
        [void]$item.Children.Add($sw)
        [void]$item.Children.Add((New-Text (Get-SurfaceLabel $r) 11 $script:Brush.Ink2))
        [void]$item.Children.Add((New-Text (' ' + (Format-UsagePercent $r.Percent)) 11 $script:Brush.Ink 'SemiBold'))
        [void]$wrap.Children.Add($item)
    }
    [void]$sp.Children.Add($wrap)
    if ($null -ne $AsOf) {
        Set-Tip $sp ('Μερίδιο κάθε επιφάνειας στη χρήση της τρέχουσας εβδομάδας (ενημ. {0})' -f $AsOf.ToLocalTime().ToString('HH:mm'))
    }
    return $sp
}

function New-TilesBlock {
    param($Tiles)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Thickness 0 2 0 10
    for ($i = 0; $i -lt $Tiles.Count; $i++) {
        $g.ColumnDefinitions.Add((New-StarColumn))
        $t = $Tiles[$i]
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Background = [System.Windows.Media.Brushes]::Transparent
        [void]$sp.Children.Add((New-Text $t.Label 11 $script:Brush.Ink2))
        [void]$sp.Children.Add((New-Text $t.Value 17 $script:Brush.Ink 'SemiBold'))
        $sub = New-Text $t.Sub 10.5 $script:Brush.Muted
        $sub.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($sub)
        Set-Tip $sp $t.Tip
        [System.Windows.Controls.Grid]::SetColumn($sp, $i)
        [void]$g.Children.Add($sp)
    }
    return $g
}

function New-Tab {
    param([string]$Text, [string]$Value, [string]$Current)
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $b.Padding = New-Thickness 7 1 7 2
    $b.Margin = New-Thickness 2 0 0 0
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $sel = ($Value -eq $Current)
    if ($sel) {
        $b.Background = $script:Brush.Pill
        $b.Child = New-Text $Text 11 $script:Brush.Ink 'SemiBold'
    }
    else {
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $b.Child = New-Text $Text 11 $script:Brush.Ink2
    }
    $b.Tag = $Value
    $b.Add_MouseLeftButtonDown({
            param($s, $e)
            $e.Handled = $true
            try {
                $script:Settings.chart = [string]$s.Tag
                Save-Settings
                Update-View
            }
            catch { Write-Log ('tab click: ' + $_.Exception.Message) }
        })
    return $b
}

function Get-HourTip {
    param($Bucket)
    $s = $Bucket.Start.ToLocalTime()
    $e = $Bucket.End.ToLocalTime()
    $t = '{0}–{1}' -f $s.ToString('HH:mm'), $e.ToString('HH:mm')
    if ($Bucket.Samples -eq 0) { return ($t + "`nχωρίς δεδομένα (το widget δεν έτρεχε)") }
    $t += "`nSession: " + (Format-UsageDelta $Bucket.Session)
    $t += "`nΕβδομάδα: " + (Format-UsageDelta $Bucket.Week)
    if ($Bucket.HasGap) { $t += "`n(περιλαμβάνει χρήση από διάστημα που το widget ήταν κλειστό)" }
    return $t
}

function Get-DayTip {
    param($Bucket)
    $t = Format-LongDate $Bucket.Date
    if ($Bucket.Samples -eq 0) { return ($t + "`nχωρίς δεδομένα (το widget δεν έτρεχε)") }
    $t += "`nΕβδομάδα: " + (Format-UsageDelta $Bucket.Week)
    $t += "`nSession (άθροισμα): " + (Format-UsageDelta $Bucket.Session)
    if ($Bucket.HasGap) { $t += "`n(περιλαμβάνει χρήση από διάστημα που το widget ήταν κλειστό)" }
    return $t
}

function Add-CenteredLabel {
    # Measures the text so it centres exactly; a halo in the surface colour keeps it legible over lines.
    param($Canvas, [string]$Text, [double]$CenterX, [double]$Top, $Fg, [string]$Weight = 'Normal', [bool]$Halo = $false)
    $lab = New-Text $Text 10 $Fg $Weight
    $lab.FontFamily = $script:Window.FontFamily
    if ($Halo) {
        $lab.Background = $script:Brush.Surface
        $lab.Padding = New-Thickness 2 0 2 0
    }
    $lab.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $labW = $lab.DesiredSize.Width
    $left = [math]::Min($script:W - $labW, [math]::Max(0, $CenterX - $labW / 2))
    Set-Pos $lab $left $Top
    [void]$Canvas.Children.Add($lab)
}

function New-ChartBlock {
    # Single-series column chart (no legend: the caption names it). Current period in the accent,
    # earlier periods in the lighter step; per-slot hover targets carry the values.
    param([string]$Mode, $HourBuckets, $DayBuckets)
    $W = $script:W
    $plotH = 38.0
    $topPad = 14.0
    $axisH = 14.0
    $sp = New-Object System.Windows.Controls.StackPanel

    $hdr = New-Object System.Windows.Controls.Grid
    $hdr.ColumnDefinitions.Add((New-StarColumn))
    $hdr.ColumnDefinitions.Add((New-AutoColumn))
    $capText = 'ανά ώρα · % του 5ώρου'
    if ($Mode -eq 'days') { $capText = 'ανά ημέρα · % εβδ. · ― μέσος ρυθμός' }
    $cap = New-Text $capText 11 $script:Brush.Ink2
    $cap.VerticalAlignment = 'Center'
    [void]$hdr.Children.Add($cap)
    $tabs = New-Object System.Windows.Controls.StackPanel
    $tabs.Orientation = 'Horizontal'
    [void]$tabs.Children.Add((New-Tab '24ω' 'hours' $Mode))
    [void]$tabs.Children.Add((New-Tab '7ημ' 'days' $Mode))
    [System.Windows.Controls.Grid]::SetColumn($tabs, 1)
    [void]$hdr.Children.Add($tabs)
    [void]$sp.Children.Add($hdr)

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W
    $cv.Height = $topPad + $plotH + $axisH
    $cv.Margin = New-Thickness 0 2 0 0
    $baseY = $topPad + $plotH
    $base = New-Rect $W 1 $script:Brush.Baseline 0
    Set-Pos $base 0 $baseY
    [void]$cv.Children.Add($base)

    # No @() here: Windows PowerShell 5.1 fails on @() over some generic lists ("Argument types do not match").
    if ($Mode -eq 'days') { $buckets = $DayBuckets; $field = 'Week'; $barW = 20.0 }
    else { $buckets = $HourBuckets; $field = 'Session'; $barW = 7.0 }
    $n = $buckets.Count
    $slot = $W / $n
    $maxV = 0.0
    $maxI = -1
    $hasData = $false
    for ($i = 0; $i -lt $n; $i++) {
        $v = [double]$buckets[$i][$field]
        if ($v -ge $maxV -and $v -gt 0) { $maxV = $v; $maxI = $i }
        if ($buckets[$i].Samples -gt 0) { $hasData = $true }
    }
    $yMin = 5.0
    if ($Mode -eq 'days') { $yMin = 15.0 }
    $yMax = [math]::Max($yMin, $maxV * 1.15)

    if ($Mode -eq 'days') {
        $refY = [math]::Round($baseY - $plotH * (100.0 / 7.0) / $yMax)
        $ref = New-Rect $W 1 $script:Brush.Muted 0
        $ref.Opacity = 0.6
        Set-Pos $ref 0 $refY
        Set-Tip $ref 'Μέσος ρυθμός: 100% / 7 ημέρες ≈ 14% ανά ημέρα'
        [void]$cv.Children.Add($ref)
    }

    for ($i = 0; $i -lt $n; $i++) {
        $b = $buckets[$i]
        $v = [double]$b[$field]
        $x0 = $i * $slot
        $cx = $x0 + $slot / 2
        $isCur = ($i -eq $n - 1)
        if ($v -gt 0) {
            $h = [math]::Max(2.0, [math]::Round($plotH * [math]::Min($v, $yMax) / $yMax))
            $bar = New-Object System.Windows.Controls.Border
            $bar.Width = $barW
            $bar.Height = $h
            $bar.CornerRadius = New-Object System.Windows.CornerRadius(2, 2, 0, 0)
            if ($isCur) { $bar.Background = $script:Brush.Accent } else { $bar.Background = $script:Brush.AccentSoft }
            Set-Pos $bar ($cx - $barW / 2) ($baseY - $h)
            [void]$cv.Children.Add($bar)
            if ($i -eq $maxI -or ($Mode -eq 'days' -and $isCur)) {
                Add-CenteredLabel $cv (Format-UsageDelta $v) $cx ($baseY - $h - 13) $script:Brush.Ink2 'Normal' $true
            }
        }
        $hit = New-Object System.Windows.Controls.Border
        $hit.Width = $slot
        $hit.Height = $baseY
        $hit.Background = [System.Windows.Media.Brushes]::Transparent
        if ($Mode -eq 'days') { Set-Tip $hit (Get-DayTip $b) } else { Set-Tip $hit (Get-HourTip $b) }
        Set-Pos $hit $x0 0
        [void]$cv.Children.Add($hit)

        if ($Mode -eq 'days') {
            $fg = $script:Brush.Muted
            $wt = 'Normal'
            if ($isCur) { $fg = $script:Brush.Ink; $wt = 'SemiBold' }
            Add-CenteredLabel $cv (Get-DayShort $b.Date.DayOfWeek) $cx ($baseY + 2) $fg $wt
        }
        else {
            $lh = $b.Start.ToLocalTime().Hour
            if ($lh % 6 -eq 0) { Add-CenteredLabel $cv ($lh.ToString('00')) $cx ($baseY + 2) $script:Brush.Muted }
        }
    }

    if (-not $hasData) {
        $empty = New-Text 'Το ιστορικό γεμίζει όσο τρέχει το widget' 11 $script:Brush.Muted
        $empty.Width = $W
        $empty.TextAlignment = 'Center'
        Set-Pos $empty 0 ($topPad + $plotH / 2 - 8)
        [void]$cv.Children.Add($empty)
    }
    [void]$sp.Children.Add($cv)
    return $sp
}

#endregion

#region View

function Get-StatusMessage {
    $p = $script:State.Phase
    $next = ''
    if ($null -ne $script:State.NextPollAt -and $script:State.NextPollAt -lt [DateTimeOffset]::MaxValue) {
        $next = Format-UsageSpan ($script:State.NextPollAt - [DateTimeOffset]::UtcNow)
    }
    $warn = [string][char]0x26A0
    switch ($p) {
        'expired' { return ($warn + ' Το token του Claude Code έληξε. Ανανεώνεται μόλις χρησιμοποιήσεις το Claude Code· το widget συνεχίζει μόνο του.') }
        'unauthorized' { return ($warn + ' Το token απορρίφθηκε (401). Άνοιξε το Claude Code ή κάνε /login· το widget συνεχίζει μόνο του.') }
        'nocreds' { return ($warn + ' Δεν βρέθηκε σύνδεση Claude Code (.claude\.credentials.json). Κάνε login στο Claude Code.') }
        'forbidden' { return ($warn + ' Δεν επιτρέπεται (403): ο λογαριασμός δεν δίνει πρόσβαση στο usage.') }
        'offline' { return ('{0} Χωρίς σύνδεση με το api.anthropic.com · νέα δοκιμή σε {1}' -f $warn, $next) }
        'ratelimited' { return ('{0} Πολλά αιτήματα (429) · νέα δοκιμή σε {1}' -f $warn, $next) }
        'httperror' { return ('{0} Σφάλμα ({1}) · νέα δοκιμή σε {2}' -f $warn, $script:State.Detail, $next) }
    }
    return ''
}

function Update-View {
    $now = [DateTimeOffset]::Now
    $m = $script:Model
    $compact = [bool]$script:Settings.compact
    $script:MainPanel.Children.Clear()
    $script:DetailPanel.Children.Clear()
    $script:PlanText.Text = $script:PlanLabel

    if ($null -ne $script:FetchTask) { $script:UpdatedText.Text = '…' }
    elseif ($null -ne $script:ModelAt) { $script:UpdatedText.Text = $script:ModelAt.ToLocalTime().ToString('HH:mm') }
    else { $script:UpdatedText.Text = '' }
    $updTip = 'Ανανέωση τώρα'
    if ($null -ne $script:ModelAt) { $updTip = ('Τελευταία ενημέρωση {0} · κλικ για ανανέωση' -f $script:ModelAt.ToLocalTime().ToString('HH:mm:ss')) }
    Set-Tip $script:RefreshButton $updTip
    if ($compact) {
        $script:ToggleGlyph.Text = [string][char]0xE70D
        Set-Tip $script:ToggleButton 'Περισσότερα'
    }
    else {
        $script:ToggleGlyph.Text = [string][char]0xE70E
        Set-Tip $script:ToggleButton 'Λιγότερα'
    }

    $status = Get-StatusMessage
    $stale = $false
    if ($null -ne $script:ModelAt) {
        $ageMin = ([DateTimeOffset]::UtcNow - $script:ModelAt).TotalMinutes
        if ($script:State.Phase -ne 'ok' -and $script:State.Phase -ne 'init') { $stale = $true }
        if ($ageMin -gt (2.5 * [double]$script:Settings.pollMinutes + 1)) {
            $stale = $true
            if (-not $status) { $status = ('Τελευταία ενημέρωση πριν {0}' -f (Format-UsageSpan ([TimeSpan]::FromMinutes($ageMin)))) }
        }
    }

    if ($null -eq $m) {
        $msg = 'Φόρτωση…'
        if ($status) { $msg = '' }
        if ($msg) { [void]$script:MainPanel.Children.Add((New-Text $msg 12 $script:Brush.Ink2)) }
    }
    else {
        $sess = $m.Session
        $week = $m.Week
        if ($null -ne $sess) {
            $sub = 'καμία ενεργή session'
            $el = $null
            $resetText = '—'
            if ($null -ne $sess.ResetsAt) {
                $resetText = Format-ResetTime $sess.ResetsAt $now
                if ($sess.ResetsAt -gt $now) {
                    $sub = 'reset σε {0} · {1}' -f (Format-UsageSpan ($sess.ResetsAt - $now)), $resetText
                    $el = Get-WindowElapsedFraction -ResetsAt $sess.ResetsAt -WindowHours 5 -Now $now
                }
                else { $sub = 'έγινε reset · αναμένεται ανανέωση' }
            }
            $tip = "Όριο session 5 ωρών: {0} χρησιμοποιήθηκε.`nReset: {1}." -f (Format-UsagePercent $sess.Percent), $resetText
            if ($null -ne $el) { $tip += ("`nΗ κάθετη γραμμή = πόσο από το 5ωρο πέρασε ({0})." -f (Format-UsagePercent (100 * $el))) }
            [void]$script:MainPanel.Children.Add((New-MeterBlock 'Session · 5 ώρες' $sess $sub $tip $el))
        }
        if ($null -ne $week) {
            $sub = ''
            $el = $null
            $tip = 'Εβδομαδιαίο όριο (όλα τα μοντέλα): ' + (Format-UsagePercent $week.Percent) + '.'
            if ($null -ne $week.ResetsAt) {
                $rl = $week.ResetsAt.ToLocalTime()
                if ($week.ResetsAt -gt $now) {
                    $sub = 'reset {0} · σε {1}' -f (Format-ResetTime $week.ResetsAt $now), (Format-UsageSpan ($week.ResetsAt - $now))
                    $el = Get-WindowElapsedFraction -ResetsAt $week.ResetsAt -WindowHours 168 -Now $now -StartedAt $m.WeekStartedAt
                }
                else { $sub = 'έγινε reset · αναμένεται ανανέωση' }
                $tip += ("`nReset: {0} {1}." -f (Format-LongDate $rl.Date), $rl.ToString('HH:mm'))
                if ($null -ne $el) { $tip += ("`nΜε σταθερό ρυθμό θα ήσουν στο {0} (η κάθετη γραμμή)." -f (Format-UsagePercent (100 * $el))) }
            }
            [void]$script:MainPanel.Children.Add((New-MeterBlock 'Εβδομάδα' $week $sub $tip $el))
        }

        $lastHour = Get-IncrementSum -Increments $script:Increments -Since $now.AddHours(-1) -Field 'Session'
        $midnight = Get-LocalMidnight $now
        $today = Get-IncrementSum -Increments $script:Increments -Since $midnight -Field 'Week'
        $allow = $null
        if ($null -ne $week) { $allow = Get-DailyAllowance -WeekPercent $week.Percent -ResetsAt $week.ResetsAt -Now $now }
        $allowText = '—'
        if ($null -ne $allow) { $allowText = Format-UsagePercent $allow }
        $histStart = $null
        if ($script:Samples.Count -gt 0) { $histStart = $script:Samples[0].Ts }

        if ($compact) {
            $line = 'Τελ. ώρα {0} · Σήμερα {1} · {2}/ημ. διαθέσιμο' -f (Format-UsageDelta $lastHour), (Format-UsageDelta $today), $allowText
            $lt = New-Text $line 11 $script:Brush.Ink2
            $lt.Margin = New-Thickness 0 -2 0 0
            [void]$script:MainPanel.Children.Add($lt)
        }
        else {
            foreach ($sc in @($m.Scoped)) {
                $sub = ''
                if ($null -ne $sc.AllowancePct) { $sub = 'έως {0} του εβδομαδιαίου ορίου' -f (Format-UsagePercent $sc.AllowancePct) }
                $el = $null
                if ($null -ne $sc.ResetsAt -and $null -ne $sc.WindowHours -and $sc.ResetsAt -gt $now) {
                    $el = Get-WindowElapsedFraction -ResetsAt $sc.ResetsAt -WindowHours $sc.WindowHours -Now $now -StartedAt $m.WeekStartedAt
                }
                $tip = 'Ξεχωριστό όριο για {0}: {1} χρησιμοποιήθηκε (μετράει και στο συνολικό εβδομαδιαίο).' -f $sc.Label, (Format-UsagePercent $sc.Percent)
                [void]$script:DetailPanel.Children.Add((New-MeterBlock ('Εβδομάδα · ' + $sc.Label) $sc $sub $tip $el 4 10 11.5))
            }
            $bd = New-BreakdownBlock -Rows $m.Breakdown -AsOf $m.BreakdownAsOf
            if ($null -ne $bd) { [void]$script:DetailPanel.Children.Add($bd) }
            if ($null -ne $m.Spend) {
                $cur = $m.Spend.Currency
                $txt = 'Credits: {0:0.00} {1}' -f $m.Spend.Used, $cur
                if ($null -ne $m.Spend.Limit) { $txt = 'Credits: {0:0.00} / {1:0.00} {2}' -f $m.Spend.Used, $m.Spend.Limit, $cur }
                $st = New-Text $txt 11 $script:Brush.Ink2
                $st.Margin = New-Thickness 0 -4 0 10
                [void]$script:DetailPanel.Children.Add($st)
            }
            $todaySub = 'της εβδομάδας'
            if ($null -ne $histStart -and $histStart -gt $midnight) { $todaySub = 'εβδ. · από ' + $histStart.ToLocalTime().ToString('HH:mm') }
            $allowTip = 'Ό,τι μένει από το εβδομαδιαίο όριο, μοιρασμένο στις ημέρες ως το reset.'
            if ($null -ne $week -and $null -ne $allow -and $null -ne $week.ResetsAt) {
                $allowTip = '(100% − {0}) / {1:0.0} ημέρες ως το reset' -f (Format-UsagePercent $week.Percent), [math]::Max(0.0, ($week.ResetsAt - $now).TotalDays)
            }
            $tiles = @(
                @{ Label = 'Τελ. ώρα'; Value = (Format-UsageDelta $lastHour); Sub = 'του 5ώρου'; Tip = 'Πόσο από το όριο session (5 ωρών) καταναλώθηκε τα τελευταία 60 λεπτά.' },
                @{ Label = 'Σήμερα'; Value = (Format-UsageDelta $today); Sub = $todaySub; Tip = 'Πόσο από το εβδομαδιαίο όριο καταναλώθηκε από τα μεσάνυχτα.' },
                @{ Label = 'Διαθέσιμο'; Value = $allowText; Sub = 'ανά ημέρα'; Tip = $allowTip }
            )
            [void]$script:DetailPanel.Children.Add((New-TilesBlock $tiles))
            $mode = [string]$script:Settings.chart
            if ($mode -ne 'days') { $mode = 'hours' }
            $hb = Get-HourlyBuckets -Increments $script:Increments -Now $now -Hours 24
            $db = Get-DailyBuckets -Increments $script:Increments -Now $now -Days 7
            [void]$script:DetailPanel.Children.Add((New-ChartBlock -Mode $mode -HourBuckets $hb -DayBuckets $db))
        }
    }

    $op = 1.0
    if ($stale) { $op = 0.55 }
    $script:MainPanel.Opacity = $op
    $script:DetailPanel.Opacity = $op
    if ($status) {
        $script:StatusText.Text = $status
        $script:StatusText.Visibility = 'Visible'
    }
    else {
        $script:StatusText.Text = ''
        $script:StatusText.Visibility = 'Collapsed'
    }
}

#endregion

#region Fetch

function Set-Failure {
    param([string]$Phase, [string]$Detail = '', $Delay = $null)
    $script:State.Phase = $Phase
    $script:State.Detail = $Detail
    $script:State.Failures = [int]$script:State.Failures + 1
    if ($null -eq $Delay) {
        $mins = [math]::Min(30.0, [math]::Pow(2, [math]::Min(5, $script:State.Failures - 1)))
        $Delay = [TimeSpan]::FromMinutes($mins)
    }
    $script:State.NextPollAt = [DateTimeOffset]::UtcNow.Add([TimeSpan]$Delay)
}

function Start-UsageFetch {
    $cred = Read-ClaudeCredential -Path $script:CredPath
    $script:CredFileTime = $cred.FileTime
    if (-not $cred.Ok) {
        if ($script:State.Phase -ne 'nocreds') { Write-Log ('credentials not usable: ' + $cred.Reason) }
        Set-Failure 'nocreds' $cred.Reason ([TimeSpan]::FromMinutes(5))
        return
    }
    $script:PlanLabel = Get-PlanLabel $cred.SubscriptionType $cred.RateLimitTier
    if ($null -ne $cred.ExpiresAt -and $cred.ExpiresAt -le [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        $cred.AccessToken = $null
        if ($script:State.Phase -ne 'expired') { Write-Log ('access token expired at ' + (Format-IsoUtc $cred.ExpiresAt) + '; waiting for Claude Code to refresh it') }
        Set-Failure 'expired' '' ([TimeSpan]::FromMinutes(5))
        return
    }
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $script:UsageUrl)
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $cred.AccessToken)
    $cred.AccessToken = $null
    [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
    [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json')
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', ('claude-usage-widget/' + $script:AppVersion))
    $script:FetchStarted = [DateTimeOffset]::UtcNow
    $script:FetchTask = $script:Http.SendAsync($req)
}

function Complete-UsageFetch {
    $t = $script:FetchTask
    $script:FetchTask = $null
    if ($t.IsFaulted -or $t.IsCanceled) {
        $msg = 'timeout'
        if ($t.IsFaulted -and $null -ne $t.Exception) { $msg = $t.Exception.GetBaseException().Message }
        Write-Log ('fetch failed: ' + $msg)
        Set-Failure 'offline' $msg
        return
    }
    $resp = $t.Result
    try {
        $code = [int]$resp.StatusCode
        $body = $resp.Content.ReadAsStringAsync().Result
        if ($code -eq 200) {
            $model = ConvertFrom-UsageResponse -Json $body
            $nowUtc = [DateTimeOffset]::UtcNow
            $script:Model = $model
            $script:ModelAt = $nowUtc
            if (-not $script:ReadOnly) {
                [IO.File]::WriteAllText($script:LastPath, $body, $script:Utf8NoBom)
                $sample = New-UsageSample -Model $model -Ts $nowUtc
                Add-UsageHistorySample -Path $script:HistoryPath -Sample $sample
                $script:Samples.Add($sample)
                $script:Increments = Get-UsageIncrements -Samples $script:Samples
            }
            if ($script:State.Phase -ne 'ok') { Write-Log 'usage fetch ok' }
            $script:State.Phase = 'ok'
            $script:State.Detail = ''
            $script:State.Failures = 0
            $script:State.NextPollAt = $nowUtc.AddMinutes([double]$script:Settings.pollMinutes)
        }
        elseif ($code -eq 401) {
            Write-Log 'HTTP 401 from usage endpoint'
            Set-Failure 'unauthorized' '401' ([TimeSpan]::FromMinutes(15))
        }
        elseif ($code -eq 403) {
            Write-Log 'HTTP 403 from usage endpoint'
            Set-Failure 'forbidden' '403' ([TimeSpan]::FromMinutes(30))
        }
        elseif ($code -eq 429) {
            $delay = [TimeSpan]::FromMinutes([math]::Min(60, 10 * ([int]$script:State.Failures + 1)))
            $ra = $resp.Headers.RetryAfter
            if ($null -ne $ra -and $null -ne $ra.Delta) { $delay = [TimeSpan]$ra.Delta }
            Write-Log ('HTTP 429, next try in ' + $delay)
            Set-Failure 'ratelimited' '429' $delay
        }
        else {
            Write-Log ('HTTP ' + $code + ' from usage endpoint')
            Set-Failure 'httperror' ('HTTP ' + $code)
        }
    }
    catch {
        Write-Log ('response handling failed: ' + $_.Exception.Message)
        Set-Failure 'httperror' 'parse'
    }
    finally {
        $resp.Dispose()
    }
}

function Request-Refresh {
    if ($null -ne $script:FetchTask -or $script:DemoMode) { return }
    $script:State.NextPollAt = [DateTimeOffset]::UtcNow
    $script:State.Failures = 0
    Invoke-Tick
}

#endregion

#region Tick, position, menu

function Test-CredentialChange {
    if (@('expired', 'unauthorized', 'nocreds') -notcontains $script:State.Phase) { return }
    try {
        $ft = $null
        if (Test-Path -LiteralPath $script:CredPath) { $ft = (Get-Item -LiteralPath $script:CredPath).LastWriteTimeUtc }
        if ($ft -ne $script:CredFileTime) {
            Write-Log 'credentials file changed; retrying now'
            $script:State.NextPollAt = [DateTimeOffset]::UtcNow
        }
    }
    catch { }
}

function Test-ThemeChange {
    if ((Get-EffectiveTheme) -ne $script:ThemeName) {
        Set-Theme
        Update-View
    }
}

function Test-DayRollover {
    $d = (Get-Date).Date
    if ($d -eq $script:LastPruneDate) { return }
    $script:LastPruneDate = $d
    if ($script:ReadOnly) { return }
    try {
        $keep = [DateTimeOffset]::UtcNow.AddDays(-8)
        [void](Compress-UsageHistory -Path $script:HistoryPath -KeepSince $keep)
        $script:Samples = Read-UsageHistory -Path $script:HistoryPath -Since $keep
        $script:Increments = Get-UsageIncrements -Samples $script:Samples
    }
    catch { Write-Log ('history prune failed: ' + $_.Exception.Message) }
}

function Invoke-MemoryTrim {
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        [CuwNative]::TrimWorkingSet()
    }
    catch { }
}

function Invoke-Tick {
    $script:TickCount++
    $nowUtc = [DateTimeOffset]::UtcNow
    $changed = $false
    if ($null -ne $script:FetchTask) {
        if ($script:FetchTask.IsCompleted) {
            Complete-UsageFetch
            $changed = $true
        }
        elseif (($nowUtc - $script:FetchStarted).TotalSeconds -gt 45) {
            $script:FetchTask = $null
            Write-Log 'fetch abandoned after 45 s'
            Set-Failure 'offline' 'timeout'
            $changed = $true
        }
    }
    elseif (-not $script:DemoMode -and $nowUtc -ge $script:State.NextPollAt) {
        Start-UsageFetch
        $changed = $true
    }
    if ($script:TickCount % 15 -eq 0) {
        Test-CredentialChange
        Test-ThemeChange
        Test-DayRollover
    }
    if ($changed -or $script:TickCount % 20 -eq 0) { Update-View }
    if ($script:TickCount -eq 12 -or $script:TickCount % 1800 -eq 0) { Invoke-MemoryTrim }
}

function Set-WindowPosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w = $script:Window.ActualWidth
    if ($w -le 0) { $w = $script:Window.Width }
    $h = $script:Window.ActualHeight
    $s = $script:Settings
    if ($null -eq $s.left) {
        $left = $wa.Right - $w
        $top = $wa.Bottom - $h
    }
    else {
        $left = [double]$s.left
        if ($s.anchor -eq 'top' -and $null -ne $s.top) { $top = [double]$s.top }
        elseif ($null -ne $s.bottom) { $top = [double]$s.bottom - $h }
        else { $top = $wa.Bottom - $h }
    }
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
    $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    $left = [math]::Min([math]::Max($left, $vl - 12), $vl + $vw - $w + 12)
    $top = [math]::Min([math]::Max($top, $vt - 12), $vt + $vh - $h + 12)
    $script:Window.Left = $left
    $script:Window.Top = $top
    $script:PositionReady = $true
}

function Save-WindowPosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $h = $script:Window.ActualHeight
    $s = $script:Settings
    $s.left = [math]::Round($script:Window.Left)
    if (($script:Window.Top + $h / 2) -gt ($wa.Top + $wa.Height / 2)) {
        $s.anchor = 'bottom'
        $s.bottom = [math]::Round($script:Window.Top + $h)
        $s.top = $null
    }
    else {
        $s.anchor = 'top'
        $s.top = [math]::Round($script:Window.Top)
        $s.bottom = $null
    }
    Save-Settings
}

function Switch-Compact {
    $script:Settings.compact = -not [bool]$script:Settings.compact
    Save-Settings
    Update-View
}

function Switch-Startup {
    $lnk = Get-StartupShortcutPath
    try {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Log 'autostart disabled'
        }
        else {
            New-WidgetShortcut -ShortcutPath $lnk -ScriptPath $script:ScriptPath
            Write-Log 'autostart enabled'
        }
    }
    catch { Write-Log ('autostart toggle failed: ' + $_.Exception.Message) }
}

function Add-MenuEntry {
    # ItemCollection.Add takes [object]: always pass the base object, never a PSObject wrapper.
    param($Parent, $Item)
    [void]$Parent.Items.Add($Item.psobject.BaseObject)
}

function New-MenuItem {
    param([string]$Header, [scriptblock]$OnClick, [bool]$Checkable = $false)
    $mi = [System.Windows.Controls.MenuItem]::new()
    $mi.Header = $Header
    $mi.IsCheckable = $Checkable
    if ($null -ne $OnClick) { $mi.Add_Click($OnClick) }
    return $mi
}

function Initialize-Menu {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $script:MiTopmost = New-MenuItem 'Πάντα από πάνω' {
        $script:Settings.topmost = [bool]$script:MiTopmost.IsChecked
        $script:Window.Topmost = [bool]$script:Settings.topmost
        Save-Settings
    } $true
    $script:MiCompact = New-MenuItem 'Συμπαγής προβολή' { Switch-Compact } $true
    $miTheme = New-MenuItem 'Θέμα' $null
    $script:MiThemeAuto = New-MenuItem 'Αυτόματο (όπως τα Windows)' { Set-ThemeSetting 'auto' } $true
    $script:MiThemeLight = New-MenuItem 'Φωτεινό' { Set-ThemeSetting 'light' } $true
    $script:MiThemeDark = New-MenuItem 'Σκοτεινό' { Set-ThemeSetting 'dark' } $true
    Add-MenuEntry $miTheme $script:MiThemeAuto
    Add-MenuEntry $miTheme $script:MiThemeLight
    Add-MenuEntry $miTheme $script:MiThemeDark
    $script:MiStartup = New-MenuItem 'Εκκίνηση με τα Windows' { Switch-Startup } $true

    Add-MenuEntry $menu (New-MenuItem 'Ανανέωση τώρα' { Request-Refresh })
    Add-MenuEntry $menu ([System.Windows.Controls.Separator]::new())
    Add-MenuEntry $menu $script:MiTopmost
    Add-MenuEntry $menu $script:MiCompact
    Add-MenuEntry $menu $miTheme
    Add-MenuEntry $menu $script:MiStartup
    Add-MenuEntry $menu (New-MenuItem 'Επαναφορά θέσης' {
                $script:Settings.left = $null
                $script:Settings.top = $null
                $script:Settings.bottom = $null
                $script:Settings.anchor = 'bottom'
                Save-Settings
                Set-WindowPosition
            })
    Add-MenuEntry $menu ([System.Windows.Controls.Separator]::new())
    Add-MenuEntry $menu (New-MenuItem 'Άνοιγμα claude.ai/settings/usage' { Start-Process 'https://claude.ai/settings/usage' })
    Add-MenuEntry $menu (New-MenuItem 'Άνοιγμα φακέλου δεδομένων' { Start-Process explorer.exe $script:DataDir })
    Add-MenuEntry $menu ([System.Windows.Controls.Separator]::new())
    Add-MenuEntry $menu (New-MenuItem 'Έξοδος' { $script:Window.Close() })
    $menu.Add_Opened({
            try {
                $script:MiTopmost.IsChecked = [bool]$script:Settings.topmost
                $script:MiCompact.IsChecked = [bool]$script:Settings.compact
                $t = [string]$script:Settings.theme
                $script:MiThemeAuto.IsChecked = ($t -ne 'light' -and $t -ne 'dark')
                $script:MiThemeLight.IsChecked = ($t -eq 'light')
                $script:MiThemeDark.IsChecked = ($t -eq 'dark')
                $script:MiStartup.IsChecked = (Test-Path -LiteralPath (Get-StartupShortcutPath))
            }
            catch { Write-Log ('menu open: ' + $_.Exception.Message) }
        })
    $script:Card.ContextMenu = $menu
}

#endregion

#region Data init

function Initialize-Data {
    if ($script:DemoMode) {
        $d = New-DemoState -Scenario $Demo -Now ([DateTimeOffset]::Now)
        $script:Model = $d.Model
        $script:Samples = $d.Samples
        $script:Increments = Get-UsageIncrements -Samples $script:Samples
        $script:ModelAt = [DateTimeOffset]::UtcNow
        $script:PlanLabel = 'Max 5x'
        $script:State.Phase = 'ok'
        $script:State.NextPollAt = [DateTimeOffset]::MaxValue
        if ($Demo -eq 'expired') {
            $script:State.Phase = 'expired'
            $script:ModelAt = [DateTimeOffset]::UtcNow.AddMinutes(-47)
        }
        elseif ($Demo -eq 'offline') {
            $script:State.Phase = 'offline'
            $script:State.NextPollAt = [DateTimeOffset]::UtcNow.AddMinutes(4)
            $script:ModelAt = [DateTimeOffset]::UtcNow.AddMinutes(-18)
        }
        return
    }
    $since = [DateTimeOffset]::UtcNow.AddDays(-8)
    if (-not $script:ReadOnly) {
        try { [void](Compress-UsageHistory -Path $script:HistoryPath -KeepSince $since) } catch { Write-Log ('history prune failed: ' + $_.Exception.Message) }
    }
    try { $script:Samples = Read-UsageHistory -Path $script:HistoryPath -Since $since } catch { Write-Log ('history read failed: ' + $_.Exception.Message) }
    $script:Increments = Get-UsageIncrements -Samples $script:Samples
    if (Test-Path -LiteralPath $script:LastPath) {
        try {
            $script:Model = ConvertFrom-UsageResponse -Json ([IO.File]::ReadAllText($script:LastPath, [Text.Encoding]::UTF8))
            $script:ModelAt = [DateTimeOffset](Get-Item -LiteralPath $script:LastPath).LastWriteTimeUtc
        }
        catch { Write-Log ('last.json unreadable: ' + $_.Exception.Message) }
    }
    $cred = Read-ClaudeCredential -Path $script:CredPath
    if ($cred.Ok) { $script:PlanLabel = Get-PlanLabel $cred.SubscriptionType $cred.RateLimitTier }
    $cred.AccessToken = $null
    $script:CredFileTime = $cred.FileTime
}

function Save-Snapshot {
    param([string]$Path)
    $script:Window.UpdateLayout()
    $w = [int][math]::Ceiling($script:Shell.ActualWidth * $Scale)
    $h = [int][math]::Ceiling($script:Shell.ActualHeight * $Scale)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96.0 * $Scale), (96.0 * $Scale), [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($script:Shell)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if ($dir) { [void][IO.Directory]::CreateDirectory($dir) }
    $fs = [IO.File]::Create([IO.Path]::GetFullPath($Path))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

#endregion

#region Main

Read-Settings
if ($Compact) { $script:Settings.compact = $true }
if ($Expanded) { $script:Settings.compact = $false }
if ($Chart) { $script:Settings.chart = $Chart }
Set-Theme
Initialize-Data
Initialize-Menu
$script:Window.Topmost = [bool]$script:Settings.topmost

$script:Window.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
            [CuwNative]::HideFromAltTab($hwnd)
        }
        catch { Write-Log ('tool-window style failed: ' + $_.Exception.Message) }
    })
$script:Window.Add_Loaded({
        try { if (-not $Snapshot) { Set-WindowPosition } } catch { Write-Log ('position failed: ' + $_.Exception.Message) }
    })
$script:Window.Add_SizeChanged({
        try { if ($script:PositionReady -and -not $Snapshot) { Set-WindowPosition } } catch { }
    })
$script:Card.Add_MouseLeftButtonDown({
        param($s, $e)
        try {
            if ($e.ClickCount -ge 2) { Switch-Compact; return }
            $script:Window.DragMove()
            Save-WindowPosition
        }
        catch { }
    })
$script:RefreshButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; try { Request-Refresh } catch { Write-Log ('refresh: ' + $_.Exception.Message) } })
$script:ToggleButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; try { Switch-Compact } catch { } })
foreach ($btn in @($script:RefreshButton, $script:ToggleButton)) {
    $btn.Add_MouseEnter({ param($s, $e) $s.Background = $script:Brush.Hover })
    $btn.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
}
$script:Window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        Write-Log ('unhandled UI exception: ' + $e.Exception.Message)
        $e.Handled = $true
    })
$script:Window.Add_Closed({
        try { $script:Timer.Stop() } catch { }
        try { $script:Http.Dispose() } catch { }
        try { if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
        Write-Log 'widget closed'
    })

if ($Snapshot) {
    $script:Window.Left = -30000
    $script:Window.Top = -30000
    $script:Window.Show()
    if (-not $script:DemoMode) {
        Start-UsageFetch
        if ($null -ne $script:FetchTask) {
            [void]$script:FetchTask.Wait(25000)
            if ($script:FetchTask.IsCompleted) { Complete-UsageFetch } else { $script:FetchTask = $null }
        }
    }
    Update-View
    $script:Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
    Save-Snapshot -Path $Snapshot
    $script:Window.Close()
    Write-Output ('SNAPSHOT_OK ' + [IO.Path]::GetFullPath($Snapshot) + ' phase=' + $script:State.Phase)
    return
}

Write-Log ('widget started v{0} (pid {1}, data {2})' -f $script:AppVersion, $PID, $script:DataDir)
Update-View
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(1)
$script:Timer.Add_Tick({
        try { Invoke-Tick } catch { Write-Log ('tick failed: ' + $_.Exception.Message) }
    })
$script:Timer.Start()
[void]$script:Window.ShowDialog()

#endregion
