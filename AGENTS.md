# AGENTS.md

## Purpose

This repository is an external Windows watchdog for `similaitw/chat2code-runner`.
Keep it small, reliable, and independent from the Runner.

## Hard safety boundaries

- Never modify `H:\AI_Project\Chat2Code`.
- Never add arbitrary remote shell execution.
- Never add Telegram commands such as `/exec`, `/cmd`, `/powershell`, or generic command forwarding.
- Never terminate all `python.exe`, `node.exe`, `powershell.exe`, Codex, or Gemini processes.
- Only control the Chat2Code Runner process positively identified by its command line.
- Never commit `config.json`, tokens, passwords, API keys, Telegram Bot tokens, or runtime logs.
- Preserve restart-loop protection.

## Existing Runner contract

Runner repository: `similaitw/chat2code-runner`

Expected local location:

```text
H:\AI_Project\chat2code-runner
```

Supported start entry:

```powershell
H:\AI_Project\chat2code-runner\start.ps1
```

Expected worker process contains:

```text
-m chat2code_runner run
```

The Watchdog should call the supported start script rather than duplicating Runner startup internals.

## Development order

1. Validate v0.1 auto-recovery on the real Windows host.
2. Add Telegram allow-listed status/restart/log/help commands.
3. Add read-only heartbeat/status integration.
4. Only after real-world validation, consider hung-process automatic recovery.

Prefer stability and explicit failure over clever automatic recovery.
