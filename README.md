# AgentChime

**Stop watching your terminal.**

AgentChime notifies you on Windows — and optionally on your phone — when an AI coding agent finishes, needs your attention, or stops because of an error.

> **v0.1.0** — Claude Code + Windows + ntfy mobile notifications.

AgentChime is an open-source **IDISTØPIC LABS** microtool: small software for real workflow friction.

```text
Claude Code
    |
    +-- finished --------> Windows + phone
    +-- needs attention -> Windows + phone
    +-- API failure ------> Windows + phone
```

## Why AgentChime exists

Agentic coding runs can take minutes or hours. Checking the terminal every few minutes wastes attention. AgentChime lets the agent call you back instead.

The first version was built from a real annoyance, tested on an actual Claude Code workflow, and then packaged as a reusable open-source tool.

## What it does

- Native Windows notification + sound
- Optional mobile push through [ntfy](https://ntfy.sh/)
- No Python, Node.js, npm package, or PowerShell module required
- Global Claude Code hooks across projects
- `finished`, `attention`, and `error` states
- Automatic backup before editing `~/.claude/settings.json`
- Idempotent reinstall: no duplicate AgentChime hooks
- Preserves existing unrelated Claude hooks
- `status`, `doctor`, and test commands
- Clean uninstall
- English and Brazilian Portuguese messages
- Mobile payloads do not include prompts, code, secrets, or Claude output

## Requirements

- Windows 10/11
- Windows PowerShell 5.1+ or PowerShell 7+
- Claude Code with hook support
- Optional: ntfy Android/iOS app for phone notifications

AgentChime uses Claude Code lifecycle hooks such as `Stop`, `StopFailure`, and `Notification`. See the official hook documentation:

https://code.claude.com/docs/en/hooks

## Quick install

AgentChime PowerShell files are currently unsigned. The commands below use `ExecutionPolicy Bypass` **only for the installer process**; they do not permanently change your Windows execution policy.

### Desktop only

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=(Invoke-RestMethod 'https://raw.githubusercontent.com/devBismark/agentchime/main/bootstrap.ps1'); & ([ScriptBlock]::Create([string]$s))"
```

### Desktop + mobile, Portuguese

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=(Invoke-RestMethod 'https://raw.githubusercontent.com/devBismark/agentchime/main/bootstrap.ps1'); & ([ScriptBlock]::Create([string]$s)) -EnableMobile -Locale pt-BR"
```

When mobile is enabled, AgentChime creates a long random ntfy topic unless you provide one. Subscribe to the **exact** topic printed by the installer in the ntfy mobile app.

> Prefer to review code before running it? Clone/download the repository and use the local install below.

## Local / reviewed install

From the repository folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Desktop + mobile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile
```

Brazilian Portuguese + mobile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -Locale pt-BR
```

### Pre-release tester migration

If you tested the pre-publication TaskChime build, migrate it explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -MigrateTaskChime
```

AgentChime reuses that build's locale, mobile state, ntfy server/topic, and project-name privacy setting, removes only hooks targeting the old notifier path, and **does not delete** `~/.taskchime`. The explicit flag prevents AgentChime from touching unrelated software that happens to use the historical TaskChime name.

### Migrate the original prototype

If you used the early prototype under `~/.claude/hooks/notify.ps1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -Locale pt-BR -MigratePrototype
```

AgentChime can reuse the prototype's ntfy topic and removes only the old prototype handlers.

### Keep a specific ntfy topic

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -NtfyTopic "your-existing-topic"
```

### Disable mobile without losing the rest of AgentChime

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DisableMobile
```

Reinstalling without mobile/locale flags preserves the existing AgentChime configuration.

## Verify the install

Run:

```powershell
.\agentchime.ps1 doctor
```

Expected result:

```text
AgentChime doctor
[OK] notify.ps1 installed
[OK] config.json readable
[OK] Claude hooks reference AgentChime exactly once (Stop, StopFailure, Notification)
[OK] ntfy server healthy
Doctor result: PASS
```

Then test all states:

```powershell
.\agentchime.ps1 test finished
.\agentchime.ps1 test attention
.\agentchime.ps1 test error
```

For the real end-to-end test, open a **new Claude Code session**, submit a short request, and leave the terminal. When Claude finishes, AgentChime should notify you automatically.

You can also inspect Claude's registered hooks with:

```text
/hooks
```

## What triggers each alert?

| AgentChime | Claude Code hook | Meaning |
|---|---|---|
| `finished` | `Stop` | Claude finished the turn |
| `error` | `StopFailure` | The turn ended because of an API/model/service failure |
| `attention` | `Notification` | Claude needs permission, background-session input, or an MCP elicitation |

AgentChime intentionally does not map `idle_prompt` to attention because `Stop` already sends completion; mapping both can create a duplicate notification later.

## Mobile with ntfy

AgentChime publishes directly to ntfy over HTTP; the ntfy CLI is not required.

1. Install the ntfy app on Android or iOS.
2. Install AgentChime with `-EnableMobile`.
3. Subscribe to the exact server/topic shown by the installer.
4. Run `agentchime.ps1 test finished`.

ntfy publishing documentation: https://docs.ntfy.sh/publish/

ntfy phone guide: https://docs.ntfy.sh/subscribe/phone/

## Privacy

With public `ntfy.sh`, AgentChime sends only minimal status context:

- completion / attention / error state
- current project folder name
- generic message
- API error type when available

It does **not** send:

- your prompt
- source code
- secrets
- Claude's response

A random ntfy topic is convenient, but it is not equivalent to authenticated access control. Use authenticated/self-hosted ntfy or disable mobile for sensitive environments.

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Installed files

```text
~/.agentchime/
├── config.json
├── notify.ps1
├── agentchime.log       # created only if an alert fails
└── backups/
    └── settings-*.json
```

Claude Code is modified only by AgentChime handler entries in:

```text
~/.claude/settings.json
```

## Commands

```powershell
.\agentchime.ps1 status
.\agentchime.ps1 doctor
.\agentchime.ps1 mobile
.\agentchime.ps1 test finished
.\agentchime.ps1 test attention
.\agentchime.ps1 test error
```

## Uninstall

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Keep configuration and backups:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepConfig
```

The uninstaller backs up Claude settings first and removes only handlers pointing to AgentChime.

## Troubleshooting

If desktop works but your phone does not, compare the ntfy topic shown by:

```powershell
.\agentchime.ps1 mobile
```

with the subscription on your phone **character by character**. One wrong character means a different ntfy topic.

More: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Roadmap

- [x] Windows desktop alerts
- [x] Claude Code completion alerts
- [x] attention alerts
- [x] API failure alerts
- [x] ntfy mobile alerts
- [x] migration + idempotent installer
- [x] diagnostics + safe uninstall
- [x] remote bootstrap installer
- [ ] elapsed task/turn duration
- [ ] richer project context
- [ ] first-class `agentchime` command on PATH
- [ ] Codex adapter
- [ ] additional coding agents
- [ ] more mobile providers
- [ ] signed/reproducible release artifacts

See [docs/ROADMAP.md](docs/ROADMAP.md).

## IDISTØPIC LABS

AgentChime is project **001** in IDISTØPIC LABS: a public lab for small, practical tools born from real AI, automation, and development friction.

**Small tools. Real problems. Open source.**

## Disclaimer

AgentChime is an independent open-source project. It is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of their respective owner.

## License

MIT — see [LICENSE](LICENSE).
