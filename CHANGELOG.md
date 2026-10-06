# Changelog

## 0.2.0 - development

- Add Telegram Bot setup wizard with secure token input.
- Auto-discover the authorized Telegram user by waiting for an intentional /start message.
- Add allow-listed /status, /restart, /log, /help commands.
- Add Telegram log redaction and sanitized API error handling.
- Keep manual restart count separate from automatic restart-loop protection.
- Add Telegram state to local status output.
- Add Windows GitHub Actions validation for PowerShell syntax, JSON config, and remote-command safety boundaries.

## 0.1.0 - 2026-10-06

- Add independent Windows Watchdog loop.
- Detect the real `python.exe -m chat2code_runner run` process.
- Restart missing Runner through the existing `chat2code-runner\start.ps1` entry point.
- Limit restart attempts to prevent restart loops.
- Add atomic runtime state and rotating Watchdog log.
- Add single-instance mutex with abandoned-mutex recovery.
- Add one-click installer and Windows Task Scheduler registration at user sign-in.
- Add local `status.ps1` command.
- Keep `H:\AI_Project\Chat2Code` read-only / untouched by design.
