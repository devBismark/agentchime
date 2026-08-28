# Troubleshooting

## PowerShell says the script is not digitally signed

AgentChime's PowerShell files are currently unsigned. Do **not** permanently loosen your Windows execution policy just for AgentChime.

Run the installer in a one-off PowerShell process instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile
```

That `Bypass` applies only to that process. It does not change your persistent execution-policy setting.

If your organization enforces execution policy through Group Policy, follow your administrator's policy instead of bypassing it.

## Desktop works, phone does not

Run:

```powershell
.\agentchime.ps1 mobile
```

Confirm the server and topic match the subscription on your phone exactly.

Then run:

```powershell
.\agentchime.ps1 doctor
.\agentchime.ps1 test finished
```

Check:

```text
~/.agentchime/agentchime.log
```

## Phone topic typo

A single missing or incorrect character creates a different ntfy topic. This is a common setup error and is why AgentChime prints the exact topic after installation.

## Claude finishes but nothing fires

Open a **new Claude Code session** after installation.

Inside Claude Code:

```text
/hooks
```

Verify AgentChime handlers under:

- `Stop`
- `StopFailure`
- `Notification`

Also run:

```powershell
.\agentchime.ps1 doctor
```

## Doctor reports a missing hook

Re-run the installer. Installation is idempotent: AgentChime removes its existing handlers and registers exactly one current handler per supported event.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Then:

```powershell
.\agentchime.ps1 doctor
```

## Doctor reports duplicate AgentChime hooks

Re-run the installer. v0.1.0 repairs duplicates that target `~/.agentchime/notify.ps1` before registering the current handlers.

## settings.json already has other hooks

That is supported. The installer parses existing settings, removes/replaces only AgentChime handlers, and creates a timestamped backup before writing.

Backups live in:

```text
~/.agentchime/backups/
```

## Reinstall changed my mobile configuration

v0.1.0 preserves the current locale, mobile state, ntfy server, and topic unless you explicitly override them.

To disable mobile intentionally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DisableMobile
```

## Old prototype still fires

If you used the early prototype at `~/.claude/hooks/notify.ps1`, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -MigratePrototype
```

If you also want mobile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -Locale pt-BR -MigratePrototype
```

## Mobile publishing fails

Run:

```powershell
.\agentchime.ps1 doctor
```

AgentChime checks the configured ntfy server health endpoint. Notification delivery errors are also written to:

```text
~/.agentchime/agentchime.log
```

## Attention notification seems delayed

AgentChime fires when Claude Code emits the `Notification` hook. Any delay before Claude emits that event is controlled by Claude Code, not AgentChime.

For current hook semantics, see:

https://code.claude.com/docs/en/hooks
