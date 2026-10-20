# Security

## Credentials

- At each poll the widget reads the Claude Code OAuth access token from `%USERPROFILE%\.claude\.credentials.json`
  (or `%CLAUDE_CONFIG_DIR%`), keeps it in memory only for that request, and sends it only to
  `https://api.anthropic.com/api/oauth/usage`.
- It never logs, stores, refreshes, rotates or modifies credentials. Besides the token it reads only `expiresAt`,
  `subscriptionType` and `rateLimitTier`.
- `last.json` and `history.csv` hold usage percentages and timestamps only; `widget.log` holds events and error
  messages only.

## Scope

Local, single-user tool: no listening ports, no telemetry, no third-party services.

## Reporting

Report problems privately to the repository owner.
