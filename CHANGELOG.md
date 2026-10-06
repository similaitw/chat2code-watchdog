# Changelog

## 0.3.0 - development

- Add GitHub-backed Dashboard heartbeat without Supabase.
- Publish Runner PID, worker capacity, active running task count, heartbeat time, restart count, machine name, and Runner version to a dedicated control issue.
- Reuse the existing authenticated `gh` CLI; no extra GitHub token is stored in Watchdog config.
- Add `DASHBOARD-SETUP.bat` / `dashboard-setup.ps1`.
- Dashboard heartbeat failures are isolated from Runner recovery and Telegram.
- Local `status.ps1` shows Dashboard heartbeat status.

## 0.2.0 - 2026-10-06

- Add safe local restart.ps1 / RESTART.bat so users do not manually launch a duplicate Runner.
- Add Telegram Bot setup wizard with secure token input.
- Auto-discover the authorized Telegram user by waiting for an intentional /start message.
- Add allow-listed /status, /restart, /log, /help commands.
- Add Telegram log redaction and sanitized API error handling.
- Keep manual restart count separate from automatic restart-loop protection.
- Add Telegram state to local status output.
- Send proactive Telegram notifications when automatic Runner recovery succeeds or fails.
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
