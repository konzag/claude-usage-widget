# CLAUDE.md — AI assistant instructions for this repo

## Project

Windows 11 floating desktop widget (Windows PowerShell 5.1 + WPF, no build step, no dependencies) that shows Claude
plan usage from `https://api.anthropic.com/api/oauth/usage`. Single user, runs locally. UI strings are Greek; code
comments are English only.

## Commands

- Tests: `powershell -NoProfile -File .\tests\run-tests.ps1` — must end with `TESTS pass=N fail=0`; run it under
  `pwsh` too.
- Visual check (writes nothing to history/settings):
  `powershell -NoProfile -STA -File .\src\ClaudeUsageWidget.ps1 -Snapshot .\out\x.png -Demo normal -Theme light`
  (scenarios: normal, high, expired, offline, empty; `-Compact`, `-Theme dark`, `-Chart days`). Open the PNG and
  look at it.
- Install locally: `.\install.ps1` (ends with `INSTALL OK`); remove: `.\uninstall.ps1 [-Purge]`.

## Constraints

- NEVER print, log, persist or commit the OAuth token, or anything from `.credentials.json` other than
  `expiresAt`, `subscriptionType` and `rateLimitTier`. The token goes only to api.anthropic.com.
- NEVER refresh, rotate or write Claude Code credentials: the widget is read-only. Rotating the refresh token
  outside Claude Code can sign Claude Code out.
- ALWAYS sign commits with GPG (key 74036EDBFE3B2891) from Windows git. Flow: feature branch -> PR -> main only
  with the owner's approval.
- Keep Windows PowerShell 5.1 compatibility: no `??`, `?:`, `&&`/`||`, `ConvertFrom-Json -AsHashtable`, `-Depth` on
  ConvertFrom-Json, or `Join-Path` with more than two parts. Read/write files with `[IO.File]` and explicit UTF-8.
- `.ps1`/`.psm1` files MUST be UTF-8 with BOM (5.1 reads BOM-less scripts as ANSI and garbles the Greek). Data files
  (`history.csv`, `settings.json`, `last.json`) are UTF-8 without BOM.
- PowerShell variable names are case-insensitive: never use `$w` and `$W` (or similar) in the same function.
  StrictMode 2.0 is on: read JSON properties with `Get-JsonProp`.
- Pure logic lives in `src/UsageCore.psm1` and gets a test in `tests/run-tests.ps1`; `src/ClaudeUsageWidget.ps1`
  holds only UI, polling and IO.
- Never block the UI thread: HTTP goes through `HttpClient.SendAsync` and is collected by the DispatcherTimer
  (1 s while a request is in flight, 5 s otherwise).
- Keep the idle cost near zero: the tick does comparisons only; redraw on data changes and once per clock minute;
  chart buckets are cached per history generation and hour; never call PowerShell providers (`Get-ItemProperty`,
  `Get-ChildItem`...) on the tick path. Measure with `-Snapshot ... -Demo normal -Benchmark`.
- Chart and colour rules (dataviz method): blue sequential ramp for meters and history, status amber/red only for
  warning/critical and always with the ⚠ icon, categorical slots 1-3 (validated light and dark) for the breakdown,
  text never in series colours, 2 px surface gaps between segments.
- New API fields: add a fixture under `tests/fixtures/` (strip anything personal) and a parsing test first.

## Architecture

- `src/UsageCore.psm1` — credentials (read-only), API parsing (`limits` array first, legacy fields as fallback),
  history CSV (append, read, prune to 8 days), increments with window-reset handling, hourly/daily buckets, Greek
  formatting, demo data, launch spec and shortcuts, widget process lookup.
- `src/ClaudeUsageWidget.ps1` — XAML window (borderless, tool window, DPI-aware via WPF), theme from the Windows
  setting, non-blocking polling with backoff, token-expiry handling (waits for Claude Code to refresh the file),
  context menu, position memory anchored to the nearer edge, `-Snapshot` / `-Demo` modes.
- `install.ps1` / `uninstall.ps1` — per-user install to `%LOCALAPPDATA%\ClaudeUsageWidget`; shortcuts launch
  `conhost.exe --headless powershell.exe ... -File` so no console window appears even when Windows Terminal is the
  default terminal.
- `tests/run-tests.ps1` + `tests/fixtures/` — dependency-free tests against real response shapes.
