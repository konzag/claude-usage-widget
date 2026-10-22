# Changelog

## 1.1.1 — 2026-10-22

- HTTP 429: the Retry-After delay (seconds or an absolute date) is clamped to 1–60 minutes; a huge or hostile
  value no longer parks polling (CLAUDE-USAGE-WIDGET-T1). The delay is computed by `Get-RateLimitDelay`.
- History rows must have exactly 5 columns; rows with extra columns are skipped (CLAUDE-USAGE-WIDGET-T2).

## 1.1.0 — 2026-10-20

- Minimize (–) and close (×) buttons in the header; Ελαχιστοποίηση in the context menu.
- Minimize hides the widget to the notification area: a ring icon with the higher of the session and weekly
  percentages, a tooltip with both, and a small menu; click the icon to bring the widget back.
- Starting the widget again (Start Menu) while it runs brings the running widget back instead of doing nothing.
- Nothing is drawn while minimized; the working set is trimmed every 10 minutes (was 30).

## 1.0.0 — 2026-10-20

- First version.
- Session (5 h) and weekly meters with reset countdown, even-pace tick and warning/critical states.
- Per-model weekly limits (e.g. Fable) and the weekly breakdown by surface (Claude Code / Chats / Cowork).
- Last hour / today / per-day allowance tiles; 24-hour and 7-day history charts built from local samples.
- Light and dark themes following Windows, compact view, remembered position, autostart, context menu.
- Read-only use of Claude Code's OAuth token; resumes automatically after Claude Code refreshes it.
- `-Snapshot` and `-Demo` modes; dependency-free tests for PowerShell 5.1 and 7.
