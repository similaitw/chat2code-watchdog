# Chat2Code Watchdog

A small Windows watchdog for `similaitw/chat2code-runner`.

## v0.1 goal

- Detect the real Python Runner process (`-m chat2code_runner run`).
- If the Runner disappears, restart it through the existing `start.ps1` entry point.
- Never kill all Python/PowerShell processes; only target the detected Runner PID tree.
- Keep a local state file and rotating log.
- Prevent infinite restart loops (default: 3 attempts in 15 minutes).
- Start automatically at Windows sign-in using Task Scheduler.
- Do not modify `H:\AI_Project\Chat2Code`.

## Expected layout

```text
H:\AI_Project\
├─ Chat2Code\
├─ chat2code-runner\
└─ chat2code-watchdog\
```

The existing Runner entry point is:

```powershell
H:\AI_Project\chat2code-runner\start.ps1
```

It launches:

```text
py -3 -m chat2code_runner run
```

## Install

1. Put this folder at:

```text
H:\AI_Project\chat2code-watchdog
```

2. Double-click:

```text
INSTALL.bat
```

The installer:

- creates `config.json` from the example when needed;
- performs one health check;
- starts the Runner if it is missing;
- creates `Chat2Code Watchdog` in Windows Task Scheduler;
- starts the Watchdog.

The scheduled task runs at **Windows sign-in**, under your normal Windows account. This is intentional because Chat2Code needs that account's GitHub/Codex/Gemini credentials. It does not run as SYSTEM.

## Local status

```powershell
cd H:\AI_Project\chat2code-watchdog
.\status.ps1
```

Runtime state:

```text
runtime\state.json
```

Log:

```text
logs\watchdog.log
```

## Test auto-recovery

1. Confirm `status.ps1` shows `Runner : running`.
2. Find the Runner PID shown by `status.ps1`.
3. End only that Python Runner process in Task Manager.
4. Wait up to 60 seconds.
5. Run `status.ps1` again.
6. A new Runner PID should appear and the log should contain a restart attempt.

Do **not** kill every `python.exe` process.

## Stop/remove Watchdog autostart

```powershell
.\uninstall-task.ps1
```

This removes only the Watchdog scheduled task. It does not remove or modify Chat2Code Runner or the Workspace.

## Safety boundaries

This version has no Telegram, no web server, no Vercel/Supabase, and no remote shell.
It cannot execute arbitrary commands from the network.

It never performs:

- `git reset`
- `git clean`
- arbitrary PowerShell/CMD execution
- Workspace file modification
- blanket termination of `python.exe`, `node.exe`, or `powershell.exe`

## Next milestone

v0.2 will add a Telegram control channel with a strict allow-list and only these mapped commands:

- `/status`
- `/restart`
- `/log`
- `/help`

No `/exec`, `/cmd`, `/powershell`, or arbitrary remote command feature will be added.


## Telegram control (v0.2)

After v0.2 is installed, run:

```text
TELEGRAM-SETUP.bat
```

The setup wizard:

1. asks for the Bot Token using hidden input;
2. verifies the bot with Telegram;
3. waits for you to send `/start` to that bot;
4. automatically records only that Telegram user ID in local `config.json`;
5. restarts the Watchdog scheduled task.

`config.json` is ignored by Git and must never be committed.

Supported commands:

```text
/status
/restart
/log
/help
```

There is deliberately no remote shell, `/exec`, `/cmd`, or arbitrary PowerShell execution.

Telegram polling runs inside the existing Watchdog process. The bot is checked about every 5 seconds, while Runner health checks remain at the configured interval (default 60 seconds).
